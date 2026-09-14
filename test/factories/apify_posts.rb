FactoryBot.define do
  factory :apify_image_post, class: Hash do
    skip_create

    short_code { Faker::Alphanumeric.unique.alphanumeric(number: 11) }
    owner_username { Faker::Internet.username }
    type { "Image" }
    caption { Faker::Lorem.sentence(word_count: 12) }
    url { "https://www.instagram.com/p/#{short_code}/" }
    display_url { "#{Faker::Internet.url(host: 'scontent.cdninstagram.com')}.jpg" }
    timestamp { Faker::Time.backward(days: 30).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") }
    like_count { Faker::Number.within(range: 0..5000) }
    comments_count { Faker::Number.within(range: 0..200) }

    trait :missing_owner do
      owner_username { nil }
    end

    trait :unsupported_type do
      type { "Video" }
    end

    trait :missing_type do
      type { nil }
    end

    trait :bad_timestamp do
      timestamp { "not a date at all" }
    end

    trait :missing_timestamp do
      timestamp { nil }
    end

    trait :missing_shortcode do
      short_code { nil }
    end

    trait :blank_shortcode do
      short_code { "   " }
    end

    initialize_with do
      {
        "shortCode" => short_code,
        "ownerUsername" => owner_username,
        "type" => type,
        "caption" => caption,
        "url" => url,
        "displayUrl" => display_url,
        "timestamp" => timestamp,
        "likeCount" => like_count,
        "commentsCount" => comments_count
      }.compact
    end
  end

  factory :apify_sidecar_post, class: Hash do
    skip_create

    short_code { Faker::Alphanumeric.unique.alphanumeric(number: 11) }
    owner_username { Faker::Internet.username }
    type { "Sidecar" }
    caption { Faker::Lorem.sentence(word_count: 12) }
    url { "https://www.instagram.com/p/#{short_code}/" }
    display_url { "#{Faker::Internet.url(host: 'scontent.cdninstagram.com')}.jpg" }
    timestamp { Faker::Time.backward(days: 30).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") }
    like_count { Faker::Number.within(range: 0..5000) }
    comments_count { Faker::Number.within(range: 0..200) }
    child_posts do
      Array.new(3) do
        { "type" => "Image", "displayUrl" => "#{Faker::Internet.url(host: 'scontent.cdninstagram.com')}.jpg" }
      end
    end

    initialize_with do
      {
        "shortCode" => short_code,
        "ownerUsername" => owner_username,
        "type" => type,
        "caption" => caption,
        "url" => url,
        "displayUrl" => display_url,
        "timestamp" => timestamp,
        "childPosts" => child_posts,
        "likeCount" => like_count,
        "commentsCount" => comments_count
      }
    end
  end
end
