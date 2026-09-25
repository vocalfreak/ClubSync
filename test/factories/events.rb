FactoryBot.define do
  factory :event do
    post
    title { Faker::Lorem.sentence(word_count: 3) }
    starts_on { Faker::Date.forward(days: 30) }
    starts_time { Faker::Time.between(from: Time.zone.local(2026, 1, 1, 9, 0), to: Time.zone.local(2026, 1, 1, 18, 0)) }
    venue { Faker::Address.street_address }
    details { {} }
    tags { [] }
    title_confidence { 0.9 }
    starts_at_confidence { 0.9 }
    venue_confidence { 0.9 }
  end
end
