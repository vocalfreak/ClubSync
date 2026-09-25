class IngestionRunner
  def self.call
    run = IngestionRun.create!(started_at: Time.current, status: :running)
    HealthPing.start
    outage = GeminiOutage.new

    begin
      Account.all.each do |account|
        result = AccountPipeline.call(account, ingestion_run_id: run.id, outage: outage)

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

      dedup = Deduplicator.call(ingestion_run_id: run.id)
      merge_stage_results!(run, dedup.stage_results)
      run.unexpected_errors += dedup.unexpected_errors
      if dedup.note.present?
        run.notes = [ run.notes, "* Deduplicator: #{dedup.note}" ].compact.join("\n")
      end
      run.save!

      run.status = :finished

    rescue => e
      run.status = :crashed
      run.notes = "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
      HealthPing.fail

    ensure
      run.finished_at = Time.current
      record_token_usage(run)
      run.save!
      DiscordNotifier.post_run_summary(run)
      DiscordNotifier.post_gemini_outage if outage.just_started?
      GeminiQuotaAlert.call
      HealthPing.finish(run.status) unless run.status == "crashed"
    end
  end

  # Best-effort, never run-fatal: the token line is reporting, and a usage read
  # failing must not abort the notifier chain.
  def self.record_token_usage(run)
    run.token_usage = GeminiUsage.for_run(run)
  rescue StandardError => e
    Rails.logger.error("IngestionRunner: failed to record token usage: #{e.class}: #{e.message}")
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
