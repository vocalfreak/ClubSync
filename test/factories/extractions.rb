FactoryBot.define do
  factory :extraction do
    post
    status { "succeeded" }
    model { "gemini-3.8-flash" }
    prompt_version { "v0" }
    category { "event" }
    category_confidence { 0.9 }
    raw_response { {} }
    input_tokens { Faker::Number.between(from: 500, to: 3000) }
    output_tokens { Faker::Number.between(from: 100, to: 1500) }
    duration_ms { Faker::Number.between(from: 200, to: 10_000) }
    image_count { 1 }

    trait :failed do
      status { "failed" }
      error_kind { "this_post" }
      error { Faker::Lorem.sentence(word_count: 6) }
      category { nil }
      category_confidence { nil }
    end
  end
end
