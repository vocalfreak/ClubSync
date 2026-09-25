require "set"

# The Phase 2 dedup stage service (dedup plan §2–§8). Run-level, end of run:
# `Deduplicator.call(ingestion_run_id:)` evaluates every candidate pair per
# account (deterministic prefilter, then two-tier scoring with the embedding
# tiebreaker gate), applies complete-link clustering, writes `event_groups` /
# `deduplications`, and advances posts to the terminal `deduped` stage.
#
# Hermetic by contract (§10.1): the whole pass is rescued so a dedup failure is
# never a run failure — no propagation into IngestionRunner, no /fail on
# healthchecks.io, no alert. Pair-level dispositions are one transaction each;
# an errored pair marks both posts and is silently re-evaluated next run.
class Deduplicator
  Result = Struct.new(:stage_results, :unexpected_errors, :note, keyword_init: true)

  Decision = Struct.new(:post_a, :post_b, :signals, :score, :cosine, :outcome, :series, keyword_init: true) do
    def separate?
      outcome == :separate
    end

    def merge?
      outcome == :merge
    end
  end

  # 0–21 days: admits both the same-day profile-grid series (several posts,
  # one event, published together) and the spaced announcement→reminder pattern.
  # The veto floors + MAX_DATE_GAP carry same-day-different-events separation.
  WINDOW_MIN_DAYS = 0
  WINDOW_MAX_DAYS = 21
  MAX_DATE_GAP_DAYS = 30

  WEIGHTS = { caption: 0.35, visual: 0.30, date: 0.35 }.freeze
  VETO_FLOORS = { caption: 0.30, visual: 0.30, date: 0.30 }.freeze

  CAPTION_VETO_THRESHOLD = VETO_FLOORS[:caption]
  # Hamming distance above this = "visually different art". The caption veto
  # (2026-09-24, corroborated veto) only fires when the captions ALSO differ;
  # a single changed channel alone never declares a pair different.
  DHASH_STRONG_MATCH_THRESHOLD = 16
  # Near-simultaneous series (§4.1): same-account promo bursts published this
  # close together merge outright, bypassing scoring and vetoes. Real bursts
  # are 1–2 min apart, so this is deliberate headroom.
  SERIES_WINDOW_MINUTES = 30

  MERGE_THRESHOLD = 0.72
  AMBIGUITY_MIN = 0.55
  DATE_SIM_HALF_LIFE = 14

  def self.call(ingestion_run_id:, client: nil)
    new(ingestion_run_id: ingestion_run_id, client: client).call
  end

  def initialize(ingestion_run_id:, client: nil)
    @ingestion_run_id = ingestion_run_id
    @client = client || GeminiClient
    @unexpected_errors = 0
    @notes = []
    @decisions = []
    @succeeded = 0
    @merged = 0
    @series = 0
    @failed = 0
  end

  def call
    run_pass
  rescue StandardError => e
    record_unexpected("Deduplicator pass failed: #{e.class}: #{e.message}", e)
    Result.new(stage_results: stage_results, unexpected_errors: @unexpected_errors, note: note)
  end

  private

  def run_pass
    posts_by_account = eligible_posts.group_by(&:account)
    @eligible_posts = posts_by_account.values.flatten

    posts_by_account.each do |_account, posts|
      candidates_for(posts).each do |a, b|
        decide_pair(a, b)
      end
    end

    finalize_clusters!
    apply_dispositions

    if @series.positive?
      @notes << "merged #{@series} near-simultaneous series pair#{"s" unless @series == 1}"
    end

    Result.new(stage_results: stage_results, unexpected_errors: @unexpected_errors, note: note)
  end

  def eligible_posts
    Post.where(is_event: true, stage: [ Post.stages[:extracted], Post.stages[:deduped] ])
        .includes(:event, :images)
        .to_a
  end

  # Deterministic prefilter (§2): same account (implied by grouping), both
  # extracted-and-event posts, posted 0–21 days apart, and — when both event
  # dates are known — not implausibly far apart.
  def candidates_for(posts)
    posts.sort_by { |p| p.posted_at || Time.at(0) }.combination(2).filter_map do |a, b|
      next if a.posted_at.nil? || b.posted_at.nil?

      separation_days = (b.posted_at - a.posted_at) / 1.day
      next unless separation_days.between?(WINDOW_MIN_DAYS, WINDOW_MAX_DAYS)
      next if date_distance_days(a, b)&.> (MAX_DATE_GAP_DAYS)

      [ a, b ]
    end
  end

  def decide_pair(a, b)
    @decisions << evaluate_pair(a, b)
  rescue StandardError => e
    record_unexpected("Deduplicator: pair (#{a.shortcode}, #{b.shortcode}) evaluation failed: #{e.class}: #{e.message}", e)
  end

  def evaluate_pair(a, b)
    return series_decision(a, b) if series_pair?(a, b)

    signals = compute_signals(a, b)
    defined = defined_channels(signals)
    cheap = blend_score(defined)

    if vetoed?(defined, signals)
      return Decision.new(post_a: a, post_b: b, signals: signals, score: cheap, cosine: nil, outcome: :separate, series: false)
    end

    if disappointingly_in_band?(cheap) && caption_defined?(defined)
      cosine = embedding_cosine(a, b)
      if cosine
        rescored_channels = defined.merge(caption: cosine)
        if !vetoed?(rescored_channels, signals)
          rescored = blend_score(rescored_channels)
          return Decision.new(post_a: a, post_b: b, signals: signals, score: rescored, cosine: cosine,
                              outcome: rescored >= MERGE_THRESHOLD ? :merge : :separate, series: false)
        end

        return Decision.new(post_a: a, post_b: b, signals: signals, score: cheap, cosine: cosine,
                            outcome: :separate, series: false)
      end
    end

    Decision.new(post_a: a, post_b: b, signals: signals, score: cheap, cosine: nil,
                 outcome: cheap >= MERGE_THRESHOLD ? :merge : :separate, series: false)
  end

  # Near-simultaneous series (§4.1): same-account posts published within the
  # window with no known-date conflict are the same promo burst — merge without
  # signal scoring or vetoes. Both `posted_at` are guaranteed present by the
  # prefilter. Date-conflict (both `starts_on` known AND different) keeps a
  # genuinely different same-hour event separate; unknown dates still merge.
  def series_pair?(a, b)
    (b.posted_at - a.posted_at).abs <= SERIES_WINDOW_MINUTES.minutes && !date_conflicting?(a, b)
  end

  def date_conflicting?(a, b)
    distance = date_distance_days(a, b)
    !distance.nil? && !distance.zero?
  end

  def series_decision(a, b)
    @series += 1
    Decision.new(post_a: a, post_b: b, signals: {}, score: nil, cosine: nil, outcome: :merge,
                 series: true)
  end

  # The embedding tiebreaker is only ever earned: cheap score in [0.55, 0.72).
  def disappointingly_in_band?(cheap)
    cheap >= AMBIGUITY_MIN && cheap < MERGE_THRESHOLD
  end

  def compute_signals(a, b)
    caption = CaptionJaccard.similarity(a.caption, b.caption)
    hash_distance = min_hash_distance(a, b)
    date_distance = date_distance_days(a, b)

    {
      caption: caption,
      visual: hash_distance && (1.0 - hash_distance / DHashService::BITS.to_f),
      date: date_distance && [ 0.0, 1.0 - date_distance / DATE_SIM_HALF_LIFE.to_f ].max,
      hash_distance: hash_distance,
      date_distance_days: date_distance
    }
  end

  # Only present channels count: a missing channel contributes no credit, no
  # penalty, and (here) no blocking power. Two undated posts can still
  # merge on strong caption+visual.
  def defined_channels(signals)
    signals.select { |key, value| %i[caption visual date].include?(key) && value.is_a?(Float) }
  end

  def caption_defined?(defined)
    defined.key?(:caption)
  end

  # Corroborated veto (2026-09-24, A/B-review fix): no sub-floor channel
  # vetoes on its own. Caption and visual must BOTH say "different" — identical
  # art with a rewritten caption (or vice versa) is a strong pair, not a veto.
  # Date stays lone: the posts' own event dates disagreeing is structural.
  def caption_vetoes?(caption_jaccard, hash_distance)
    caption_jaccard < CAPTION_VETO_THRESHOLD &&
      hash_distance && hash_distance > DHASH_STRONG_MATCH_THRESHOLD
  end

  def vetoed?(channels, signals)
    return true if signals[:caption].present? && caption_vetoes?(signals[:caption], signals[:hash_distance])

    channels[:date].present? && channels[:date] < VETO_FLOORS[:date]
  end

  # Renormalized over the weights of whatever channels are present: an
  # image-less post drops visual's 0.30 share into the others.
  def blend_score(channels)
    denom = 0.0
    numer = 0.0
    channels.each do |key, value|
      denom += WEIGHTS[key]
      numer += WEIGHTS[key] * value
    end
    return 0.0 if denom.zero?

    numer / denom
  end

  def min_hash_distance(a, b)
    dh_a = a.images.map(&:dhash).compact
    dh_b = b.images.map(&:dhash).compact
    return nil if dh_a.empty? || dh_b.empty?

    dh_a.product(dh_b).map { |x, y| DHashService.hamming(x, y) }.min
  end

  def date_distance_days(a, b)
    sa = a.event&.starts_on
    sb = b.event&.starts_on
    return nil if sa.nil? || sb.nil?

    (sa - sb).abs.to_i
  end

  # Lazy per-post embedding (§3.1): computed once on the first ambiguity-band
  # hit, stored on `posts.embedding`, reused by every later pair. A hiccup is
  # getter-only — logged, never a pair failure, and the cheap score decides.
  def embedding_cosine(a, b)
    vec_a = embedding_for(a)
    vec_b = embedding_for(b)
    return nil if vec_a.nil? || vec_b.nil?

    CosineSimilarity.cosine(vec_a, vec_b)
  end

  def embedding_for(post)
    return post.embedding if post.embedding.present?

    response = @client.embed(text: post.caption)
    post.update!(embedding: response.values)
    post.embedding
  rescue StandardError => e
    @notes << "embed failed for #{post.shortcode}: #{e.class}: #{e.message} — decided on the cheap score"
    Rails.logger.error("Deduplicator: embed failed for post #{post.shortcode}: #{e.class}: #{e.message}")
    nil
  end

  # Complete-link (§6): a group is only a group when every member pair
  # individually produced a merge decision. Merge-decided pairs that lose the
  # clustering check are downgraded to final separate. With the 0–21 day window
  # a same-day series can form real size-3+ components (e.g. a Studio-style
  # triple), so the union-find + all-pairs check is the actual rule, not a
  # degenerate case.
  def finalize_clusters!
    merge_decision_ids = {}
    parent = {}
    @decisions.select(&:merge?).each do |d|
      a_id, b_id = d.post_a.id, d.post_b.id
      merge_decision_ids[[ a_id, b_id ].sort] = d
      union!(parent, a_id, b_id)
    end

    components = parent.keys.group_by { |id| find_root(parent, id) }.values
    valid_member_ids = components.select do |members|
      members.size > 1 && members.combination(2).all? { |x, y| merge_decision_ids[[ x, y ].sort].present? }
    end.flatten.to_set

    @decisions.each do |d|
      both_valid = valid_member_ids.include?(d.post_a.id) && valid_member_ids.include?(d.post_b.id)
      d.outcome = :separate unless d.merge? && both_valid
    end
  end

  def find_root(parent, id)
    parent[id] == id ? id : parent[id] = find_root(parent, parent[id])
  end

  def union!(parent, a, b)
    parent[a] ||= a
    parent[b] ||= b
    root_a = find_root(parent, a)
    root_b = find_root(parent, b)
    parent[root_b] = root_a if root_a != root_b
  end

  # Every pair gets a disposition (the plan's automatic two bands), and every
  # eligible post not in a pair gets a group-of-one — so every `events` row
  # always carries an `event_group_id` (§7).
  def apply_dispositions
    @decisions.select(&:merge?).each { |d| dispose_merged!(d) }
    @decisions.select(&:separate?).each { |d| dispose_separate!(d) }

    @eligible_posts.each do |post|
      next if @decisions.any? { |d| includes_pair?(d, post) }

      dispose_lone!(post)
    end
  end

  def includes_pair?(decision, post)
    decision.post_a.id == post.id || decision.post_b.id == post.id
  end

  # §10.1 pair atomicity: group coalescing + decision upsert + stage advance in
  # one transaction. A merge unifies the two posts into one group row and
  # retires the emptied shells; re-affirming an already-merged pair reuses its
  # existing group instead of churning a new id.
  def dispose_merged!(decision)
    a = decision.post_a
    b = decision.post_b
    Post.transaction do
      group = merge_group_for(a, b)
      rebind_event!(a, group)
      rebind_event!(b, group)
      upsert_decision!(decision, outcome: "merged", score: decision.score, cosine: decision.cosine,
                       series: decision.series)
      advance!(a)
      advance!(b)
    end
    @merged += 1
    @succeeded += 1
  rescue StandardError => e
    fail_pair!(a, b, e)
  end

  def dispose_separate!(decision)
    a = decision.post_a
    b = decision.post_b
    Post.transaction do
      ensure_group_of_one!(a)
      ensure_group_of_one!(b)
      upsert_decision!(decision, outcome: "separate", score: decision.score, cosine: decision.cosine,
                       series: decision.series)
      advance!(a)
      advance!(b)
    end
    @succeeded += 1
  rescue StandardError => e
    fail_pair!(a, b, e)
  end

  def dispose_lone!(post)
    Post.transaction do
      ensure_group_of_one!(post)
      advance!(post)
    end
  rescue StandardError => e
    record_unexpected("Deduplicator: lone post #{post.shortcode} disposition failed: #{e.class}: #{e.message}", e)
  end

  def merge_group_for(a, b)
    groups = [ a.event&.event_group_id, b.event&.event_group_id ].compact.uniq
    return EventGroup.find(groups.first) if groups.size == 1

    EventGroup.create!
  end

  def rebind_event!(post, group)
    event = post.event
    return if event.nil? || event.event_group_id == group.id

    existing = event.event_group_id
    if existing
      Event.where(event_group_id: existing).update_all(event_group_id: group.id)
      EventGroup.where(id: existing).delete_all
    else
      event.update!(event_group_id: group.id)
    end
  end

  def ensure_group_of_one!(post)
    event = post.event
    return if event.nil? || event.event_group_id.present?

    group = EventGroup.create!
    event.update!(event_group_id: group.id)
  end

  def advance!(post)
    return if post.deduped?

    post.update!(stage: :deduped, last_error: nil, stage_failed_at: nil)
  end

  def upsert_decision!(decision, outcome:, score:, cosine:, series: false)
    a_id, b_id = [ decision.post_a.id, decision.post_b.id ].sort
    now = Time.current
    Deduplication.upsert(
      {
        post_a_id: a_id,
        post_b_id: b_id,
        account: decision.post_a.account,
        ingestion_run_id: @ingestion_run_id,
        hash_distance: decision.signals[:hash_distance],
        date_distance_days: decision.signals[:date_distance_days],
        caption_jaccard: decision.signals[:caption],
        embedding_cosine: cosine,
        weighted_score: score,
        outcome: outcome,
        series: series ? true : nil,
        decided_at: now,
        created_at: now,
        updated_at: now
      },
      unique_by: :index_deduplications_on_post_a_and_post_b
    )
  end

  # §10.1 attribution: the pair's posts are marked (stage stays `extracted` so
  # the stalled-post view can point at dedup) and the pair tallies as failed.
  def fail_pair!(a, b, error)
    @failed += 1
    message = "deduped: #{error.class}: #{error.message}"
    [ a, b ].each do |post|
      post.update(last_error: message, stage_failed_at: Time.current)
    rescue StandardError => e
      Rails.logger.error("Deduplicator: failed to record pair failure for #{post.shortcode}: #{e.class}: #{e.message}")
    end
    Rails.logger.error("Deduplicator: pair (#{a.shortcode}, #{b.shortcode}) failed: #{error.class}: #{error.message}")
  end

  def record_unexpected(message, error)
    @unexpected_errors += 1
    @notes << message
    Rails.logger.error("#{message}\n#{error&.backtrace&.first(10)&.join("\n")}")
  end

  def stage_results
    tally = {}
    tally["succeeded"] = @succeeded if @succeeded.positive?
    tally["merged"] = @merged if @merged.positive?
    tally["failed"] = @failed if @failed.positive?
    return {} if tally.empty?

    { "deduped" => tally }
  end

  def note
    text = @notes.join("\n")
    text.presence
  end
end
