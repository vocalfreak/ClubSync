FactoryBot.define do
  # A Gemini response for a post, in the exact schema shape (§7.1) with the
  # keys Gemini emits. A plain hash factory (skip_create) mirroring the Apify
  # pattern. Defaults to a valid event; category traits per §3.
  factory :gemini_payload, class: Hash do
    skip_create

    checks do
      {
        "has_date" => true,
        "has_time" => true,
        "has_venue" => true,
        "asks_signup" => false,
        "asks_donation" => false,
        "qr_code_seen" => false
      }
    end
    category { "event" }
    category_confidence { Faker::Number.between(from: 0.5, to: 1.0) }
    title { Faker::Lorem.sentence(word_count: 4) }
    starts_date { Faker::Date.forward(days: 20).strftime("%Y-%m-%d") }
    starts_time { "20:15" }
    ends_date { nil }
    ends_time { "22:00" }
    venue { Faker::Address.street_address }
    registration_url { Faker::Internet.url }
    registration_via { "link" }
    members_only { false }
    online_only { false }
    confidence do
      {
        "title" => Faker::Number.between(from: 0.7, to: 1.0),
        "starts_at" => Faker::Number.between(from: 0.7, to: 1.0),
        "venue" => Faker::Number.between(from: 0.7, to: 1.0)
      }
    end
    notes { nil }
    tags { [] }

    trait :event do
    end

    # A post with no attendable time or place: the topic category applies.
    trait :reminder do
      category { "reminder" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      registration_url { nil }
      registration_via { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :fundraising do
      category { "fundraising" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => true, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :recruitment do
      category { "recruitment" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :recap do
      category { "recap" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :merch_or_sales do
      category { "merch_or_sales" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
    end

    trait :deadline do
      category { "deadline" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :teaser do
      category { "teaser" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :general_announcement do
      category { "general_announcement" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :other do
      category { "other" }
      checks { { "has_date" => false, "has_time" => false, "has_venue" => false, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => false } }
      title { nil }
      starts_date { nil }
      starts_time { nil }
      ends_date { nil }
      ends_time { nil }
      venue { nil }
      confidence { { "title" => 0.0, "starts_at" => 0.0, "venue" => 0.0 } }
    end

    trait :club_and_society_registration_week do
      category { "club_and_society_registration_week" }
      checks { { "has_date" => true, "has_time" => true, "has_venue" => true, "asks_signup" => false, "asks_donation" => false, "qr_code_seen" => true } }
      title { "CSRW booth" }
      starts_date { "2026-09-02" }
      starts_time { "10:00" }
      ends_date { "2026-09-03" }
      ends_time { "17:00" }
      venue { "CLC" }
      confidence { { "title" => 0.9, "starts_at" => 0.9, "venue" => 0.9 } }
    end

    # Failure traits — structurally plausible but invalid.
    trait :bad_category do
      category { "mystery_category" }
    end

    trait :impossible_date do
      starts_date { "2026-02-30" }
    end

    trait :bad_time do
      starts_time { "25:99" }
    end

    trait :bad_confidence do
      confidence { { "title" => "high", "starts_at" => "yes", "venue" => "probably" } }
    end

    initialize_with do
      {
        "checks" => checks,
        "category" => category,
        "category_confidence" => category_confidence,
        "title" => title,
        "starts_date" => starts_date,
        "starts_time" => starts_time,
        "ends_date" => ends_date,
        "ends_time" => ends_time,
        "venue" => venue,
        "registration_url" => registration_url,
        "registration_via" => registration_via,
        "members_only" => members_only,
        "online_only" => online_only,
        "confidence" => confidence,
        "notes" => notes,
        "tags" => tags
      }
    end
  end
end
