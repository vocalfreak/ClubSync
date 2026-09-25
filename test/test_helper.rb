ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers. Default single-process: this
    # box's multi-fork runs race Rails' DRb parallel harness (a worker can
    # unlink the shared socket before siblings connect, hanging the run).
    # Raise with PARALLEL_WORKERS on nodes where forking is reliable.
    parallelize(workers: ENV.fetch("PARALLEL_WORKERS", 1).to_i.clamp(1, Etc.nprocessors))

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include FactoryBot::Syntax::Methods

    # A dhash string with `n` set bits in the low positions (hamming to all-zeros is n).
    def dhash_with_bits(n)
      ("1" * n).ljust(64, "0").to_i(2).to_s(16).rjust(16, "0")
    end

    def build_event_post(account:, posted_at:, caption:, starts_on:, dhash: nil, images: 1, stage: :extracted, shortcode: nil)
      shortcode ||= Faker::Alphanumeric.unique.alphanumeric(number: 11)
      post = Post.create!(
        shortcode: shortcode,
        account: account,
        post_type: "Image",
        caption: caption,
        source_url: "https://www.instagram.com/p/#{shortcode}/",
        posted_at: posted_at,
        raw_payload: { "type" => "Image" },
        stage: stage,
        is_event: true
      )
      Event.create!(post: post, title: "some event", starts_on: starts_on)
      images.times do |i|
        Image.create!(post: post, position: i, b2_key: "b2-#{shortcode}-#{i}", content_type: "image/webp", dhash: dhash)
      end
      post
    end

    # Add more helper methods to be used by tests here...
  end
end
