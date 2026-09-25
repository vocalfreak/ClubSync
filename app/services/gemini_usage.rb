# Read-only daily/run Gemini usage from `extractions` rows. Rows are one per
# post outcome (retries collapse into their final row), so "requests" is the
# number of posts whose extraction resolved — an undercount of raw API calls,
# deliberately: the audit log records outcomes, not attempts. Tokens come from
# succeeded rows only.
class GeminiUsage
  def self.for_run(run)
    build(Extraction.where(ingestion_run_id: run.id))
  end

  def self.today
    build(Extraction.where(created_at: Time.current.beginning_of_day..Time.current))
  end

  def self.build(rows)
    input_tokens = rows.sum(:input_tokens).to_i
    output_tokens = rows.sum(:output_tokens).to_i
    {
      "requests" => rows.count,
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => input_tokens + output_tokens
    }
  end
end
