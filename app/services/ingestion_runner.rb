class IngestionRunner
  def self.call
    run = IngestionRun.create!(started_at: Time.current, status: :running)
    HealthPing.start
    breaker = GeminiBreaker.new

    begin
      Account.all.each do |account|
        result = AccountPipeline.call(account, ingestion_run_id: run.id, breaker: breaker)

        if result.success?
          run.accounts_processed += 1
          run.posts_scraped += result.posts_scraped
        else
          run.accounts_failed += 1
          run.failed_accounts << { "account" => account.handle, "reason" => result.errors.join("; ") }
        end

        merge_stage_results!(run, result.stage_results)
        run.unexpected_errors += result.unexpected_errors
        run.save!
      end

      run.status = :finished

    rescue => e
      run.status = :crashed
      run.notes = "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
      HealthPing.fail

    ensure
      run.finished_at = Time.current
      run.save!
      DiscordNotifier.post_run_summary(run)
      DiscordNotifier.post_breaker_open if breaker.just_opened?
      HealthPing.finish(run.status) unless run.status == "crashed"
    end
  end

  # Sums one account's per-stage outcome hash into the run's cumulatively.
  def self.merge_stage_results!(run, stage_results)
    stage_results.each do |stage, outcomes|
      run.stage_results[stage] ||= {}
      outcomes.each do |outcome, count|
        run.stage_results[stage][outcome] = run.stage_results[stage].fetch(outcome, 0) + count
      end
    end
  end
end
