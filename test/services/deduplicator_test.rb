require "test_helper"

class DeduplicatorTest < ActiveSupport::TestCase
  def setup
    @z = "0" * 16
  end

  def two_posts_with(account: "club-test", posted: 18.days, starts_on: [ Date.new(2026, 10, 1) ] * 2,
                     captions: [ "same caption here", "same caption here" ], images: 1, dhash: nil, stage: :extracted)
    dhash ||= @z
    a = build_event_post(account: account, posted_at: Time.utc(2026, 8, 1), caption: captions[0],
                         starts_on: starts_on[0], dhash: dhash, images: images)
    b = build_event_post(account: account, posted_at: Time.utc(2026, 8, 1) + posted, caption: captions[1],
                         starts_on: starts_on[1], dhash: dhash, images: images, stage: stage)
    [ a, b ]
  end

  class FakeEmbedClient
    attr_reader :embed_calls

    def initialize(vectors = {})
      @vectors = vectors
      @embed_calls = []
    end

    def embed(text:)
      @embed_calls << text
      raise GeminiClient::TimeoutError, "embed timed out" unless @vectors.key?(text)

      Struct.new(:values).new(@vectors.fetch(text))
    end
  end

  def run_dedup(client: FakeEmbedClient.new)
    run = create(:ingestion_run)
    [ run, Deduplicator.call(ingestion_run_id: run.id, client: client) ]
  end

  test "same-account pair two weeks apart with matched caption, visual, and date merges" do
    a, b = two_posts_with(posted: 14.days, captions: [ "Riddim night at Memory", "Riddim night at Memory" ])
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert result.stage_results["deduped"]["merged"] == 1, result.stage_results.inspect
    assert_equal 0, client.embed_calls.length, "a clearly-mergeable pair never pays the embedding gate"

    deduplication = Deduplication.where(post_a_id: a.id, post_b_id: b.id).or(
      Deduplication.where(post_a_id: b.id, post_b_id: a.id)
    ).first
    assert_equal "merged", deduplication.outcome
    assert_equal 0, deduplication.hash_distance
    assert_equal 0, deduplication.date_distance_days
    assert_in_delta 1.0, deduplication.caption_jaccard, 1e-9
    assert_in_delta 1.0, deduplication.weighted_score, 1e-9
    assert_nil deduplication.embedding_cosine

    assert a.reload.deduped?
    assert b.reload.deduped?
    shared = a.event.reload.event_group_id
    assert shared.present?, "a merge puts both posts under one event_group"
    assert_equal shared, b.event.reload.event_group_id
  end

  test "a same-moment grid burst merges via the series rule with unscored rows (LUNGS-like)" do
    t = Time.utc(2026, 8, 26)
    a = build_event_post(account: "tamucyb", posted_at: t, caption: "LUNGS theatre trip sign up now",
                         starts_on: Date.new(2026, 8, 30), dhash: @z)
    b = build_event_post(account: "tamucyb", posted_at: t, caption: "LUNGS theatre trip sign up now",
                         starts_on: Date.new(2026, 8, 30), dhash: @z)
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["merged"], result.stage_results.inspect
    deduplication = Deduplication.first
    assert_equal "merged", deduplication.outcome
    assert_equal true, deduplication.series, "published at the same moment: the series rule, not a score"
    assert_nil deduplication.hash_distance, "a series merge skips signal scoring"
    assert_nil deduplication.caption_jaccard
    assert_nil deduplication.date_distance_days
    assert_nil deduplication.weighted_score
    assert_equal 0, client.embed_calls.length, "series merges never pay the embedding gate"
    shared = a.event.reload.event_group_id
    assert_equal shared, b.event.reload.event_group_id
    assert_equal 1, EventGroup.count
  end

  test "same-moment different events with conflicting dates stay separate (Misi Bekal-like)" do
    t = Time.utc(2026, 5, 3)
    a = build_event_post(account: "misi", posted_at: t, caption: "Donation drive tonight",
                         starts_on: Date.new(2026, 5, 4), dhash: @z)
    b = build_event_post(account: "misi", posted_at: t, caption: "Volunteer booth needs you",
                         starts_on: Date.new(2026, 5, 5), dhash: dhash_with_bits(45))
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"]
    assert_nil result.stage_results["deduped"]["merged"]
    deduplication = Deduplication.first
    assert_nil deduplication.series, "the known conflicting dates keep the same-moment pair out of the series rule"
    assert_equal "separate", deduplication.outcome
    assert_in_delta 0.0, deduplication.caption_jaccard, 1e-9
    refute_equal a.event.reload.event_group_id, b.event.reload.event_group_id
    assert_equal 0, client.embed_calls.length, "a corroborated caption+art veto never pays the embedding gate"
  end

  test "same-day triple with matching signals coalesces into one group of three (Studio-like)" do
    t = Time.utc(2026, 5, 3)
    posts = [ 0, 30, 60 ].map.with_index do |mins, _i|
      build_event_post(account: "rentakmmu", posted_at: t + mins.minutes,
                       caption: "Studio sessions hip hop exactly the same words",
                       starts_on: Date.new(2026, 5, 6), dhash: @z)
    end

    _run, result = run_dedup

    assert_equal({ "deduped" => { "succeeded" => 3, "merged" => 3 } }, result.stage_results)
    assert_equal 1, EventGroup.count
    group = EventGroup.first
    assert_equal posts.map { |p| p.reload.event.event_group_id }.uniq, [ group.id ]
    posts.each { |p| assert p.reload.deduped? }
    assert_equal 3, EventGroup.first.events.count
  end

  test "complete-link downgrades a triple whose memberships disagree" do
    t0 = Time.utc(2026, 8, 1)
    a = build_event_post(account: "dice", posted_at: t0, caption: "stats night",
                         starts_on: Date.new(2026, 9, 1), dhash: @z)
    b = build_event_post(account: "dice", posted_at: t0 + 18.days, caption: "stats night reg 6pm 1pm",
                         starts_on: Date.new(2026, 9, 1), dhash: @z)
    c = build_event_post(account: "dice", posted_at: t0 + 18.days, caption: "stats night signup link form",
                         starts_on: Date.new(2026, 9, 1), dhash: dhash_with_bits(40))

    _run, result = run_dedup

    assert_equal({ "deduped" => { "succeeded" => 3 } }, result.stage_results,
                 "every pair is disposed separate, no partial membership survives")
    deduplication = Deduplication.where(post_a_id: b.id, post_b_id: c.id).first ||
               Deduplication.where(post_a_id: c.id, post_b_id: b.id).first
    assert_equal "separate", deduplication.outcome
    assert_equal 3, EventGroup.count
    assert_equal 3, Event.where(event_group_id: EventGroup.pluck(:id).uniq).count
    refute_equal a.event.reload.event_group_id, b.event.reload.event_group_id
    refute_equal b.event.reload.event_group_id, c.event.reload.event_group_id
  end

  test "identical art with a different caption is no caption veto — the pair earns the embedding gate (iem_mmu class)" do
    a, b = two_posts_with(captions: [ "Riddim night at Memory", "Gallery opening downtown" ])
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"]
    assert_nil result.stage_results["deduped"]["merged"]
    deduplication = Deduplication.where(post_a_id: [ a.id, b.id ].min, post_b_id: [ a.id, b.id ].max).first
    assert_equal "separate", deduplication.outcome
    assert_in_delta 0.0, deduplication.caption_jaccard, 1e-9
    refute_empty client.embed_calls, "identical art + rewritten caption sat in the ambiguity band (0.65), so the gate fires"
    assert_in_delta 0.65, deduplication.weighted_score, 1e-9, "no vectors: the cheap separate (0.65) stands"

    refute_equal a.event.reload.event_group_id, b.event.reload.event_group_id
    assert a.reload.deduped?
    assert b.reload.deduped?
  end

  test "identical-art pair whose embedding cosine disagrees stays separate after the rescore (iem_mmu class)" do
    a = build_event_post(account: "iem", posted_at: Time.utc(2026, 8, 1), caption: "recap of last night",
                         starts_on: Date.new(2026, 8, 3), dhash: @z)
    b = build_event_post(account: "iem", posted_at: Time.utc(2026, 8, 19), caption: "next round sign up here",
                         starts_on: Date.new(2026, 8, 3), dhash: @z)
    client = FakeEmbedClient.new("recap of last night" => [ 1.0, 0.0 ], "next round sign up here" => [ -1.0, 0.0 ])

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"]
    deduplication = Deduplication.first
    assert_equal "separate", deduplication.outcome
    assert_in_delta(-1.0, deduplication.embedding_cosine, 1e-9, "the arbitrating cosine is still audited")
    assert_in_delta 0.30, deduplication.weighted_score, 1e-9, "caption -1.0 + visual 1.0 + date 1.0"
    assert_equal 2, client.embed_calls.length
  end

  test "identical caption with barely-distinct art is no visual veto — the blend merges it (Paw Fest class)" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "Riddim night at Memory",
                         starts_on: Date.new(2026, 9, 1), dhash: dhash_with_bits(50))
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "Riddim night at Memory",
                         starts_on: Date.new(2026, 9, 1), dhash: dhash_with_bits(50))
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["merged"], result.stage_results.inspect
    assert_equal 0, client.embed_calls.length, "blend 0.77 clears the merge threshold outright"
    deduplication = Deduplication.first
    assert_equal "merged", deduplication.outcome
    assert_nil deduplication.series, "18 days apart is scored, not the series rule"
  end

  test "a near-simultaneous promo burst merges outright with no signal scoring (MIMOS-like)" do
    t = Time.utc(2026, 8, 26)
    posts = [ 0, 1, 2 ].map.with_index do |mins, i|
      build_event_post(account: "ieeemmusb", posted_at: t + mins.minutes,
                       caption: [ "Booth promo one", "Booth promo two", "Booth promo three" ][i],
                       starts_on: nil, dhash: dhash_with_bits(21 + mins * 6))
    end

    _run, result = run_dedup

    assert_equal({ "deduped" => { "succeeded" => 3, "merged" => 3 } }, result.stage_results)
    assert_equal 3, Deduplication.count
    Deduplication.all.each do |deduplication|
      assert_equal "merged", deduplication.outcome
      assert_equal true, deduplication.series
      assert_nil deduplication.hash_distance, "a series merge skips signal scoring"
      assert_nil deduplication.caption_jaccard
      assert_nil deduplication.date_distance_days
      assert_nil deduplication.weighted_score
    end
    assert_includes result.note, "series"
    group = EventGroup.first
    assert_equal posts.map { |p| p.reload.event.event_group_id }.uniq, [ group.id ]
    assert_equal 3, EventGroup.first.events.count
  end

  test "a near-simultaneous pair with conflicting known dates is not a series — dates still separate it" do
    t = Time.utc(2026, 8, 26)
    a = build_event_post(account: "club-test", posted_at: t, caption: "Night market fun",
                         starts_on: Date.new(2026, 8, 28), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: t + 5.minutes, caption: "Film screening",
                         starts_on: Date.new(2026, 9, 2), dhash: dhash_with_bits(50))
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    deduplication = Deduplication.first
    refute deduplication.series, "5 minutes apart is not enough when both known dates differ"
    assert_equal "separate", deduplication.outcome
    assert_equal 5, deduplication.date_distance_days
    assert_equal 0, client.embed_calls.length, "a corroborated caption+art veto keeps it out of the band"
  end

  test "the series window is exactly thirty minutes: 30 in, 31 out" do
    t = Time.utc(2026, 8, 26)
    in_a = build_event_post(account: "club-in", posted_at: t, caption: "same promo",
                            starts_on: Date.new(2026, 8, 30), dhash: @z)
    in_b = build_event_post(account: "club-in", posted_at: t + 30.minutes, caption: "same promo",
                            starts_on: Date.new(2026, 8, 30), dhash: @z)
    out_a = build_event_post(account: "club-out", posted_at: t, caption: "same promo",
                             starts_on: Date.new(2026, 8, 30), dhash: @z)
    out_b = build_event_post(account: "club-out", posted_at: t + 31.minutes, caption: "same promo",
                             starts_on: Date.new(2026, 8, 30), dhash: @z)

    _run, result = run_dedup

    in_deduplication = Deduplication.where(post_a_id: [ in_a.id, in_b.id ].min, post_b_id: [ in_a.id, in_b.id ].max).first
    out_deduplication = Deduplication.where(post_a_id: [ out_a.id, out_b.id ].min, post_b_id: [ out_a.id, out_b.id ].max).first
    assert_equal true, in_deduplication.series
    assert_nil out_deduplication.series, "31 minutes falls back to scoring (blend 1.0 merges)"
    assert_equal 2, result.stage_results["deduped"]["merged"], result.stage_results.inspect
  end

  test "an image-less pair is never caption-vetoed — nil hash voids the corroboration and no visual credit is earned" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "red boat",
                         starts_on: Date.new(2026, 10, 1), images: 0)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "green car",
                         starts_on: Date.new(2026, 10, 1), images: 0)
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"]
    deduplication = Deduplication.first
    assert_equal "separate", deduplication.outcome
    assert_nil deduplication.hash_distance
    assert_in_delta 0.0, deduplication.caption_jaccard, 1e-9
    assert_equal 0, deduplication.date_distance_days
    assert_in_delta 0.50, deduplication.weighted_score, 1e-9, "caption 0 + date 1.0 renormalized over their weights only"
    assert_empty client.embed_calls, "cheap 0.50 sits below the ambiguity band"
  end

  test "both-null-dated pair merges on identical caption and visual — undefined date never vetoes" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "Same flyer, no date",
                         starts_on: nil, dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "Same flyer, no date",
                         starts_on: nil, dhash: @z)
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["merged"]
    deduplication = Deduplication.first
    assert_equal "merged", deduplication.outcome
    assert_nil deduplication.date_distance_days, "an unknown date logs as nil, never 0"
    assert_nil deduplication.embedding_cosine, "the cheap score was decisive, no embed"
    assert_equal 0, client.embed_calls.length
  end

  test "an ambiguity-band pair earns the embedding tiebreaker, which flips it to merge" do
    caption_a = "red blue green"
    caption_b = "red blue yellow"
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: caption_a,
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: caption_b,
                         starts_on: Date.new(2026, 10, 4), dhash: dhash_with_bits(13))
    client = FakeEmbedClient.new(caption_a => [ 1.0, 0.0 ], caption_b => [ 0.9, Math.sqrt(1 - 0.9**2) ])

    _run, result = run_dedup(client: client)

    assert_in_delta 0.35 * 0.5 + 0.30 * (1 - 13.0 / 64) + 0.35 * (1 - 3.0 / 14), 0.6, 0.2
    assert_equal 1, result.stage_results["deduped"]["merged"], result.stage_results.inspect
    deduplication = Deduplication.first
    assert_equal "merged", deduplication.outcome
    assert_in_delta 0.9, deduplication.embedding_cosine, 1e-9, "the full cosine was recorded"
    assert_in_delta 0.35 * 0.9 + 0.30 * (1 - 13.0 / 64) + 0.35 * (1 - 3.0 / 14), deduplication.weighted_score, 1e-9
    assert_includes client.embed_calls, caption_a
    assert_includes client.embed_calls, caption_b
  end

  test "an ambiguity-band pair whose embedding cosine falls below the floor stays separate" do
    caption_a = "red blue green"
    caption_b = "red blue yellow"
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: caption_a,
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: caption_b,
                         starts_on: Date.new(2026, 10, 4), dhash: dhash_with_bits(13))
    client = FakeEmbedClient.new(caption_a => [ 1.0, 0.0 ], caption_b => [ -1.0, 0.0 ])

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"]
    assert_nil result.stage_results["deduped"]["merged"]
    deduplication = Deduplication.first
    assert_equal "separate", deduplication.outcome
    assert_in_delta(-1.0, deduplication.embedding_cosine, 1e-9, "the arbitrating cosine is still audited")
  end

  test "a clearly-separate pair never calls the embed endpoint" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "red blue green",
                         starts_on: Date.new(2026, 10, 1), dhash: dhash_with_bits(30))
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "red blue yellow",
                         starts_on: Date.new(2026, 10, 20), dhash: dhash_with_bits(30))
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"]
    assert_nil result.stage_results["deduped"]["merged"]
    assert_empty client.embed_calls
  end

  test "an embed hiccup in the ambiguity band is getter-only: the cheap score decides, pair is not failed" do
    caption_a = "red blue green"
    caption_b = "red blue yellow"
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: caption_a,
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: caption_b,
                         starts_on: Date.new(2026, 10, 4), dhash: dhash_with_bits(13))
    client = FakeEmbedClient.new({})

    _run, result = run_dedup(client: client)

    assert_equal 1, result.stage_results["deduped"]["succeeded"], result.stage_results.inspect
    assert_nil result.stage_results["deduped"]["failed"]
    deduplication = Deduplication.first
    assert_nil deduplication.embedding_cosine
    assert_equal "separate", deduplication.outcome, "the cheap score (0.689) could not clear 0.72"
    assert_nil a.reload.last_error, "the embed getter is never a pair failure"
    assert a.reload.deduped?
    assert_includes result.note, "embed failed"
  end

  test "embeddings are cached on posts so re-evaluation reuse pays no second embed round-trip" do
    caption_a = "red blue green"
    caption_b = "red blue yellow"
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: caption_a,
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: caption_b,
                         starts_on: Date.new(2026, 10, 4), dhash: dhash_with_bits(13))
    client = FakeEmbedClient.new(caption_a => [ 1.0, 0.0 ], caption_b => [ 1.0, 0.0 ])
    run = create(:ingestion_run)

    result = Deduplicator.call(ingestion_run_id: run.id, client: client)
    assert_equal 1, result.stage_results["deduped"]["merged"]
    assert_equal 2, client.embed_calls.length, "first ambiguity hit embeds both posts once"

    second = FakeEmbedClient.new(caption_a => [ 1.0, 0.0 ], caption_b => [ 1.0, 0.0 ])
    Deduplicator.call(ingestion_run_id: run.id, client: second)

    assert_empty second.embed_calls, "re-evaluation reuses the stored embeddings"
    assert_equal [ 1.0, 0.0 ], a.reload.embedding
    assert_equal [ 1.0, 0.0 ], b.reload.embedding
  end

  test "pairs posted more than 21 days apart are not candidates — no deduplication, no merge" do
    a, b = two_posts_with(posted: 25.days)
    client = FakeEmbedClient.new

    _run, result = run_dedup(client: client)

    assert_equal({}, result.stage_results, "no candidate pair to dispose")
    assert_equal 0, Deduplication.count
    refute_equal a.event.reload.event_group_id, b.event.reload.event_group_id
    assert a.reload.deduped?, "lone eligible posts still reach the terminal stage"
  end

  test "a pair whose post dates disagree implausibly is dropped before scoring, never logged" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "identical caption",
                         starts_on: Date.new(2026, 11, 20), dhash: @z)

    result = Deduplicator.call(ingestion_run_id: create(:ingestion_run).id, client: FakeEmbedClient.new).stage_results

    assert_equal({}, result, "the 50-day date disagreement kills the candidate pair")
    assert_equal 0, Deduplication.count
  end

  test "cross-account posts are never candidates even with identical signals" do
    a, b = two_posts_with(account: "club-a", posted: 15.days)
    c, d = two_posts_with(account: "club-b", posted: 15.days)
    _run, result = run_dedup

    assert_equal({ "deduped" => { "succeeded" => 2, "merged" => 2 } }, result.stage_results,
               "each account's identical-signal pair merges; succeeded counts disposed pairs")
    assert_equal 2, Deduplication.count
    refute_equal a.event.reload.event_group_id, c.event.reload.event_group_id
  end

  test "non-event posts are never scored against event posts" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b.update!(is_event: false)

    result = Deduplicator.call(ingestion_run_id: create(:ingestion_run).id, client: FakeEmbedClient.new).stage_results

    assert_equal({}, result, b.inspect)
    assert_equal 0, Deduplication.count
  end

  test "a already-deduped post stays a candidate for newly arrived same-account posts" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z, stage: :deduped)
    old_group = EventGroup.create!
    a.event.update!(event_group_id: old_group.id)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)

    _run, result = run_dedup

    assert_equal 1, result.stage_results["deduped"]["merged"]
    assert_equal 1, Deduplication.count
    shared = a.event.reload.event_group_id
    assert_equal shared, b.event.reload.event_group_id
    assert_equal 1, EventGroup.count, "the stale group-of-one shell is retired"
    assert_equal [ a.id, b.id ].min, Deduplication.first.post_a_id
  end

  test "every events row ends up with an event_group_id, including lone posts and separate pairs" do
    lone = build_event_post(account: "club-alone", posted_at: Time.utc(2026, 8, 1), caption: "solo",
                            starts_on: Date.new(2026, 10, 1), dhash: @z)
    a, b = two_posts_with(captions: [ "Riddim night", "Gallery opening" ])
    other_lone = build_event_post(account: "club-alone", posted_at: Time.utc(2026, 8, 8), caption: "solo2",
                                  starts_on: Date.new(2026, 11, 1), dhash: @z)
    # the two club-alone posts are 7 days apart so they are not a candidate pair either

    _run, result = run_dedup

    assert_equal 0, result.unexpected_errors
    Post.where(is_event: true).each do |post|
      assert post.event.reload.event_group_id.present?, "post #{post.shortcode} lacks an event_group"
      assert post.reload.deduped?
    end
    assert_equal 1, lone.event.reload.event_group_id.present? ? 1 : 0
    assert_equal 4, EventGroup.count, "lone and other_lone are 7 days apart: two group-of-ones + a/b separate pair"
  end

  test "deduplications row is upserted on a later run: one row per pair, latest evaluation wins" do
    a, b = two_posts_with(captions: [ "Riddim night", "Gallery opening" ])
    run1, result1 = run_dedup
    deduplication = Deduplication.where(post_a_id: [ a.id, b.id ].min, post_b_id: [ a.id, b.id ].max).first
    assert_equal run1.id, deduplication.ingestion_run_id

    run2, result2 = run_dedup

    assert_equal 0, result2.unexpected_errors
    assert_equal 1, Deduplication.count, "re-evaluation upserts, never multiplies rows"
    assert_equal run2.id, deduplication.reload.ingestion_run_id
    assert_operator deduplication.reload.decided_at, :>=, deduplication.decided_at
    assert_equal 1, result1.stage_results["deduped"]["succeeded"]
    assert_equal 1, result2.stage_results["deduped"]["succeeded"]
  end

  test "a pair whose disposition transaction errors marks both posts and tallies as failed" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)

    original = EventGroup.method(:create!)
    EventGroup.define_singleton_method(:create!) { |*_args| raise "event_group write failed" }
    begin
      result = Deduplicator.call(ingestion_run_id: create(:ingestion_run).id, client: FakeEmbedClient.new)
    ensure
      EventGroup.define_singleton_method(:create!, original)
    end

    assert_equal 1, result.stage_results["deduped"]["failed"]
    assert_equal 0, Deduplication.count, "the failed pair wrote nothing"
    [ a, b ].each do |post|
      assert post.reload.extracted?, "the failed pair stays at extracted, never advanced"
      assert_match(/^deduped: /, post.last_error)
      refute_nil post.stage_failed_at
    end
  end

  test "the whole pass is hermetic: an unexpected raise becomes unexpected_errors, never propagates" do
    a = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 1), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    b = build_event_post(account: "club-test", posted_at: Time.utc(2026, 8, 19), caption: "identical caption",
                         starts_on: Date.new(2026, 10, 1), dhash: @z)
    client = FakeEmbedClient.new

    original = Post.method(:where)
    Post.define_singleton_method(:where) { |*_args| raise "boom in the candidate query" }
    begin
      result = Deduplicator.call(ingestion_run_id: create(:ingestion_run).id, client: client)
    ensure
      Post.define_singleton_method(:where, original)
    end

    assert_equal result.stage_results, {}
    assert_equal 1, result.unexpected_errors
    assert_match(/Deduplicator pass failed/, result.note)
  end

  test "stage_results only carries the deduped key when there is work to report" do
    _run, result = run_dedup

    assert_equal({}, result.stage_results)
  end
end
