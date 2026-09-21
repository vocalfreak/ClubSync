namespace :clubsync do
  desc "Run a ClubSync ingestion pass over all accounts"
  task ingest: :environment do
    IngestionRunner.call
  end
end
