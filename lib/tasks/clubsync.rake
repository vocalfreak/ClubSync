namespace :clubsync do
  desc "Run a ClubSync ingestion pass over all accounts"
  task ingest: :environment do
    IngestionRunner.call
  end

  desc "Run extraction on a single post by shortcode (manual debugging)"
  task :extract_one, [ :shortcode ] => :environment do |_task, args|
    shortcode = args[:shortcode].to_s.strip
    abort "usage: rails clubsync:extract_one[shortcode]" if shortcode.blank?

    post = Post.find_by(shortcode: shortcode)
    abort "no post with shortcode #{shortcode}" unless post

    result = Extractor.call(post)
    puts "status: #{result.status}#{result.error_kind ? " (#{result.error_kind})" : ''}"
    puts "error: #{result.error}" if result.error

    post.reload
    puts "stage: #{post.stage}, category: #{post.category.inspect}, is_event: #{post.is_event.inspect}"
    puts "last_error: #{post.last_error.inspect}" if post.last_error
    puts "extractions: #{post.extractions.count} (last: #{post.extractions.order(:id).last&.status})"
  end

  desc "Measure the serialized Gemini request for a synthetic 10-image carousel (no network call)"
  task measure_payload: :environment do
    images = Image.order(byte_size: :desc).limit(10).to_a
    abort "no images in the pool — run media processing first" if images.empty?

    object_store = ObjectStore.new
    caption = Post.order(Arel.sql("char_length(caption) DESC")).first&.caption.to_s
    contents = GeminiPayload.build(
      caption: caption,
      posted_at: Time.current,
      timezone: ExtractionPrompt::TIMEZONE,
      images: images.map { |image| { bytes: object_store.get(image.b2_key), content_type: image.content_type } }
    )
    serialized = GeminiClient.request_body(
      contents: contents,
      system_instruction: ExtractionPrompt.system_instruction,
      generation_config: ExtractionPrompt.generation_config
    )

    bytes = serialized.bytesize
    puts "images: #{images.size} (pool has #{Image.count})"
    puts "caption: #{caption.length} chars"
    puts "serialized body: #{bytes} bytes (#{(bytes / 1024.0).round(1)} KiB)"
    puts "soft limit (#{GeminiClient::SOFT_LIMIT} bytes): #{bytes >= GeminiClient::SOFT_LIMIT ? 'EXCEEDED — would log a warning' : 'ok'}"
    puts "hard limit (#{GeminiClient::HARD_LIMIT} bytes): #{bytes >= GeminiClient::HARD_LIMIT ? 'EXCEEDED — would hard-fail' : 'ok'}"
  end

  desc "Run extraction over already-scraped media_processed posts with a specific model; prints a skim-able table and rolls back (pool stays pristine for the §4 comparison)"
  task :extract_pool, [ :model, :limit ] => :environment do |_task, args|
    model = args[:model].to_s.strip
    abort "usage: rails clubsync:extract_pool[model,limit]" if model.empty?

    limit = args[:limit].to_s.match?(/\A\d+\z/) ? args[:limit].to_i : 12
    posts = Post.where(stage: :media_processed).order(:id).limit(limit).to_a
    abort "no media_processed posts to extract" if posts.empty?

    puts "shortcode | status | category | is_event | notes"
    posts.each do |post|
      started = Time.current
      Post.transaction do
        result = Extractor.call(post, model: model)
        post.reload
        notes = if result.error_kind
                  "#{result.error_kind}: #{result.error.to_s[0, 80]}"
        else
                  "#{(Time.current - started).round(1)}s"
        end
        puts [ post.shortcode, result.status, post.category.inspect, post.is_event.inspect, notes ].join(" | ")
        raise ActiveRecord::Rollback
      end
    end
    puts "\n#{posts.size} posts skimmed with #{model} (all rolled back — pool unchanged)"
  end

  desc "Re-tag stored CSRW posts to the csrw category (no Gemini call); pass DRY_RUN=true to preview"
  task retag_csrw: :environment do
    dry_run = ENV["DRY_RUN"] == "true"
    result = CsrwRetagger.call(dry_run: dry_run)

    result.retagged.each do |post|
      puts format("  csrw  %-22s %-12s (%s)", post.account, post.shortcode, post.category)
    end
    puts result.summary
  end

  desc "Dump the dev database for recovery (content backup; image bytes already persist in B2)"
  task snapshot: :environment do
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    require "fileutils"
    dir = Rails.root.join("backups")
    FileUtils.mkdir_p(dir)
    stamp = Time.current.strftime("%Y-%m-%d_%H%M%S")
    path = dir.join("dev-#{stamp}.sql")

    cmd = [ "pg_dump", "--no-owner", "--no-privileges", "--dbname=#{config[:database]}" ]
    cmd << "--host=#{config[:host]}" if config[:host]
    cmd << "--port=#{config[:port]}" if config[:port]
    cmd << "--username=#{config[:username]}" if config[:username]

    env = {}
    env["PGPASSWORD"] = config[:password].to_s if config[:password].present?

    ok = system(env, *cmd, out: path.to_s, err: "/dev/null")
    abort "pg_dump failed — restore unavailable; nothing written to #{path}" unless ok

    bytes = File.size(path)
    puts "snapshot written: #{path} (#{(bytes / 1024.0).round(1)} KiB)"
    puts "restore with: psql -d #{config[:database]} -f #{path}"
  end
end
