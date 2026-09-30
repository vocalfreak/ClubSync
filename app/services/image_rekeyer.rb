# One-off repair for images uploaded before ObjectStore#put derived the key's
# extension from content_type (deployment plan, C0). Those rows hold a bare
# <sha256> b2_key, and Cloudflare picks edge-cache eligibility by file
# extension, so a URL built from one is permanently uncacheable — no Transform
# Rule can rescue it, since eligibility is decided before any rule runs.
#
# Per row: copy the object to "<old key><ext>", confirm the copy landed with a
# head_object, and only then repoint images.b2_key. Repointing after the head is
# the whole safety property — a row never names an object we haven't seen.
#
# Deliberately does NOT delete the old object. Dev shares this bucket (the box's
# .env was copied from dev) and dev's own rows still reference the old keys, so
# deleting here breaks the other database. Clean up in a second pass, once the
# row count proves nothing still points at them.
#
# Idempotent, so an interrupted run is just re-run: rows already carrying an
# extension are skipped, and copying identical bytes over the same key is a
# no-op. That is also the answer to B2's daily transaction caps — run out of
# Class C (copies) or Class B (heads) and the next day picks up where this left
# off.
class ImageRekeyer
  EXTENSION_SUFFIX = /\.[a-z0-9]+\z/i

  # Progress is reported per row, not per batch: the pool is small enough that a
  # partial run's log is the only thing telling you where it stopped.
  PROGRESS_EVERY = 50
  ANNOUNCE_SAMPLE = 10

  def self.call(dry_run: false, object_store: nil, logger: nil)
    new(dry_run: dry_run, object_store: object_store, logger: logger).call
  end

  def initialize(dry_run: false, object_store: nil, logger: nil)
    @dry_run = dry_run
    @object_store = object_store || ObjectStore.new
    @logger = logger || ->(line) { Rails.logger.info("ImageRekeyer: #{line}") }
  end

  def call
    planned, already_keyed, failures = plan
    announce(planned)
    rekeyed = []

    planned.each_with_index do |(image, new_key), index|
      unless @dry_run
        outcome = rekey(image, new_key)
        outcome == :ok ? rekeyed << new_key : failures << outcome
      end
      report(index + 1, planned.size, failures.size) if ((index + 1) % PROGRESS_EVERY).zero?
    end

    Result.new(
      planned: planned,
      rekeyed: rekeyed,
      failures: failures,
      already_keyed: already_keyed,
      dry_run: @dry_run
    )
  end

  private

  # Enough of the plan to recognise it — a wrong bucket or a stale key shape is
  # obvious from ten rows, and a few hundred lines of hex helps nobody.
  def announce(planned)
    sample = planned.first(ANNOUNCE_SAMPLE)
    @logger.call("#{planned.size} row#{"s" unless planned.size == 1} to rekey#{' (dry run)' if @dry_run}")
    sample.each do |image, new_key|
      @logger.call("  #{format('%<id>-5d %<type>-11s %<old>s -> %<new>s', id: image.id, type: image.content_type, old: image.b2_key, new: new_key)}")
    end
    @logger.call("  ...and #{planned.size - sample.size} more") if planned.size > sample.size
  end

  # Deliberately mirrors ObjectStore#put's map rather than hardcoding ".webp", so
  # a rekeyed key is byte-identical to what uploading those same bytes today
  # would produce. An unrecognised content_type is reported instead of guessed
  # at: writing ObjectStore's ".bin" fallback would contradict the row's own
  # recorded type, and writing ".webp" would invent one.
  def extension_for(content_type)
    ObjectStore::EXTENSIONS[content_type]
  end

  def keyed?(b2_key)
    b2_key.to_s.match?(EXTENSION_SUFFIX)
  end

  # Returns [ [image, new_key], ... ], a count of rows a rerun skips, and the
  # rows we refuse to touch.
  def plan
    planned = []
    failures = []
    already_keyed = 0

    Image.order(:id).find_each do |image|
      extension = extension_for(image.content_type)
      if extension.nil?
        failures << Failure.new(image: image, new_key: image.b2_key,
                                error: "unrecognised content_type #{image.content_type.inspect} — left alone")
        next
      end
      if keyed?(image.b2_key)
        already_keyed += 1
        next
      end

      planned << [ image, "#{image.b2_key}#{extension}" ]
    end

    [ planned, already_keyed, failures ]
  end

  def rekey(image, new_key)
    @object_store.copy(image.b2_key, new_key)
    unless @object_store.exists?(new_key)
      return Failure.new(image: image, new_key: new_key, error: "copy reported success but head_object found nothing")
    end

    Image.where(id: image.id).update_all(b2_key: new_key)
    :ok
  rescue StandardError => e
    Failure.new(image: image, new_key: new_key, error: "#{e.class}: #{e.message}")
  end

  def report(done, total, failed)
    @logger.call("processed #{done}/#{total} · #{failed} failed")
  end

  Failure = Struct.new(:image, :new_key, :error, keyword_init: true) do
    def to_s
      "image #{image.id} #{image.b2_key} -> #{new_key}: #{error}"
    end
  end

  Result = Struct.new(:planned, :rekeyed, :failures, :already_keyed, :dry_run, keyword_init: true) do
    def summary
      parts = [ "#{planned.size} row#{"s" unless planned.size == 1} to rekey" ]
      parts << "rekeyed #{rekeyed.size}"
      parts << "#{already_keyed} already keyed (rerun)" if already_keyed.positive?
      parts << "#{failures.size} failed" if failures.any?
      parts << "dry run — nothing written" if dry_run
      parts.join(" · ")
    end
  end
end
