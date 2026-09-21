FactoryBot.define do
  factory :account do
    sequence(:handle) { |n| "clubaccount#{n}" }
  end
end
