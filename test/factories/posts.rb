FactoryBot.define do
  factory :post do
    shortcode { Faker::Alphanumeric.unique.alphanumeric(number: 11) }
    account { Faker::Internet.username }
    post_type { "Image" }
    caption { Faker::Lorem.sentence(word_count: 12) }
    source_url { "https://www.instagram.com/p/#{shortcode}/" }
    posted_at { Faker::Time.backward(days: 30) }
    raw_payload { { "shortCode" => shortcode, "ownerUsername" => account, "type" => post_type } }
    stage { :scraped }

    trait :media_processed do
      stage { :media_processed }
    end

    trait :deduped do
      stage { :deduped }
    end

    trait :extracted do
      stage { :extracted }
      is_event { true }
    end

    trait :stalled do
      last_error { "connection reset while fetching displayUrl" }
      stage_failed_at { 1.hour.ago }
    end
  end
end
