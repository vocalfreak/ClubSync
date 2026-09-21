class IngestionRunner
  def self.call
    run = IngestionRun.create!(started_at: Time.current, status: :running)
    HealthPing.start

    begin
      Account.all.each do |account|
        result = AccountPipeline.call(account, ingestion_run_id: run.id)

        if result.success?
          run.accounts_processed += 1
          run.posts_scraped += result.posts_scraped
        else
          run.accounts_failed += 1
          run.failed_accounts << { "account" => account.handle, "reason" => result.errors.join("; ") }
        end
        run.save!
      end

      run.stage_failure_counts = Post.where(last_ingestion_run_id: run.id).group(:stage).count
      run.status = :finished

    rescue => e
      run.status = :crashed
      run.notes = "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
      HealthPing.fail

    ensure
      run.finished_at = Time.current
      run.save!
      DiscordNotifier.post_run_summary(run)
      HealthPing.finish(run.status) unless run.status == "crashed"
    end
  end
end
