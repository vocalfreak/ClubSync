module Adapters
  module Apify
    # Maps one raw post hash from Apify's Instagram Post Scraper into a
    # canonical Post-shaped attribute hash. Pure mapping + shape validation;
    # never touches the database and never raises on malformed input.
    # Never decides Post#stage/is_event, that's PostLoader's job.
    class PostAdapter
      class Result
        attr_reader :attributes, :errors

        def initialize(attributes:, errors:, fatal:)
          @attributes = attributes
          @errors = errors
          @fatal = fatal
        end

        def valid?
          !fatal? && errors.empty?
        end

        def fatal?
          @fatal
        end
      end

      VALID_POST_TYPES = %w[Image Sidecar].freeze

      SHORTCODE_REQUIRED = "shortcode is required".freeze
      ACCOUNT_INVALID = "account (ownerUsername) must be a non-blank string".freeze
      POST_TYPE_MISSING = "post_type (type) is missing or invalid".freeze
      SOURCE_URL_INVALID = "source_url (url) must be an http(s) URL".freeze
      POSTED_AT_INVALID = "posted_at (timestamp) must be a parseable ISO8601 string".freeze

      def parse_post(raw_hash)
        @raw = raw_hash.is_a?(Hash) ? raw_hash : {}
        @attributes = {}
        @errors = []

        shortcode = @raw["shortCode"]
        unless shortcode.is_a?(String) && !shortcode.strip.empty?
          return Result.new(attributes: nil, errors: [ SHORTCODE_REQUIRED ], fatal: true)
        end

        @attributes[:shortcode] = shortcode

        map_account
        map_post_type
        @attributes[:caption] = @raw["caption"]
        map_source_url
        map_posted_at

        @attributes[:raw_payload] = @raw

        Result.new(attributes: @attributes, errors: @errors, fatal: false)
      end

      private

      def map_account
        account = @raw["ownerUsername"]
        if account.is_a?(String) && !account.strip.empty?
          @attributes[:account] = account
        else
          @errors << ACCOUNT_INVALID
          @attributes[:account] = nil
        end
      end

      def map_post_type
        type = @raw["type"]
        if type.nil?
          @errors << POST_TYPE_MISSING
          @attributes[:post_type] = nil
        elsif VALID_POST_TYPES.include?(type)
          @attributes[:post_type] = type
        else
          @errors << "post_type (type) is not supported: #{type.inspect} (valid: #{VALID_POST_TYPES.join(', ')})"
          @attributes[:post_type] = type.to_s
        end
      end

      def map_source_url
        url = @raw["url"]
        if url.is_a?(String) && url.match?(/\Ahttps?:\/\//)
          @attributes[:source_url] = url
        else
          @errors << SOURCE_URL_INVALID
          @attributes[:source_url] = nil
        end
      end

      def map_posted_at
        value = @raw["timestamp"]
        unless value.is_a?(String)
          @errors << POSTED_AT_INVALID
          @attributes[:posted_at] = nil
          return
        end

        @attributes[:posted_at] = Time.iso8601(value)
      rescue ArgumentError, TypeError, NoMethodError
        @errors << POSTED_AT_INVALID
        @attributes[:posted_at] = nil
      end
    end
  end
end
