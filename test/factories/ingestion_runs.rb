FactoryBot.define do
  factory :ingestion_run do
    started_at { Time.current }
    status { :running }

    trait :finished do
      status { :finished }
      finished_at { Time.current }
      accounts_processed { 5 }
      posts_scraped { 15 }
    end

    trait :crashed do
      status { :crashed }
      finished_at { Time.current }
      notes { "RuntimeError: something went wrong" }
    end
  end
end
