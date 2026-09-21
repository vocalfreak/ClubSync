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
end
