class Post < ApplicationRecord
  enum :status, {
    pending:      0, # valid, mapped by the adapter, awaiting extraction
    done:         1, # extraction confirmed
    needs_review: 2, # extraction ran, confidence below bar (Phase 3 concern — adapter never sets this)
    rejected:     3, # adapter found structural problems (missing/malformed required field, unsupported type)
    failed:       4  # transient error elsewhere in the pipeline (retryable)
  }
end
