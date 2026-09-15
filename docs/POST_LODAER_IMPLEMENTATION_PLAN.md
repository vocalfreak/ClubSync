# ClubSync — `PostLoader` Service Spec (+ required coordinated changes)

*For the implementation agent. Primary scope is `PostLoader`, but this migration touches real, already-built code (`Post`, `MediaProcessor`, `PostAdapter`) and all of it ships together — see §2.*

## 0. Where this sits in the pipeline

```
raw Apify post hash
  → Adapters::Apify::PostAdapter#parse_post   (mapping + validation, no DB)
  → PostLoader.call                           (THIS SERVICE — all Post DB writes)
  → [orchestrator, based on post.stage]
      MediaProcessor.call(post, raw_payload: ...)   (built; self-guards via post.scraped?)
      Deduplicator.call(post)                       (not built yet; should self-guard the same way)
      Extractor.call(post)                          (not built yet; should self-guard the same way)
```

`PostLoader` does **not** call `MediaProcessor`/`Deduplicator`/`Extractor` itself. Illustrative only — not part of this service — and matches how `MediaProcessor` already self-guards rather than relying on the orchestrator to gatekeep:
```ruby
# app/services/post_ingestor.rb — sketch only, NOT part of this spec
loader_result = PostLoader.call(adapter_result)
if loader_result.created? || loader_result.refreshed?
  post = loader_result.post
  MediaProcessor.call(post, raw_payload: adapter_result.attributes[:raw_payload])
  # Deduplicator.call(post), Extractor.call(post) similarly self-guard on post.stage
end
```

## 1. Scope correction vs. the master plan

The master plan's Phase 1 bullet described `PostLoader` as "attempt to advance to the next stage," with outcomes `created / skipped / advanced / stalled`. Narrowed here:

- Loader only ever writes to `posts`. It never runs media processing, dedup, or extraction, and never advances `stage` — `stage` only moves forward when the corresponding stage-service succeeds.
- Loader never touches `is_event`, `last_error`, or `stage_failed_at` — those belong to the stage-services (confirmed: `MediaProcessor` already owns writing failure/success state for its own stage).
- No `stalled` outcome — Loader's own work can't meaningfully stall; a real failure here is a bug, which should raise, not be modeled as a result.
- Outcome set: **`created / refreshed / skipped / no_row`**.

**Entry point and Result shape now match `MediaProcessor`'s confirmed real pattern:** `PostLoader.call(...)` (class method delegating to an instance), and `Result` is a `Struct` with explicit predicate methods — not `#load` (a `Kernel` method name smell) and not a hand-rolled class, which is what an earlier draft of this doc had. `MediaProcessor::Result#status` is unrelated to `Post#stage` despite the shared word "status" — don't conflate the two.

## 2. Prerequisite migration & coordinated changes — ships as one PR, not a schema-only change

`status` is a live, actively-used column. `Post` declares `enum :status, {...}` today, and `MediaProcessor` reads/writes `@post.status` in three places. Dropping the column without updating its consumers breaks `MediaProcessor` immediately. Everything below lands together.

**`db/migrate/..._replace_status_with_stage_on_posts.rb`**
```ruby
class ReplaceStatusWithStageOnPosts < ActiveRecord::Migration[8.0]
  def change
    remove_column :posts, :status, :integer, default: 0, null: false

    add_column :posts, :stage, :integer, default: 0, null: false
    add_column :posts, :is_event, :boolean
    add_column :posts, :last_error, :text
    add_column :posts, :stage_failed_at, :datetime

    add_index :posts, :stage
  end
end
```
No live *data* dependency (no rows in production yet) — but there is a live *code* dependency, handled below.

**`app/models/post.rb`**
```diff
 class Post < ApplicationRecord
-  enum :status, {
-    pending:      0, # valid, mapped by the adapter, awaiting extraction
-    done:         1, # extraction confirmed
-    needs_review: 2, # extraction ran, confidence below bar (Phase 3 concern — adapter never sets this)
-    rejected:     3, # adapter found structural problems (missing/malformed required field, unsupported type)
-    failed:       4  # transient error elsewhere in the pipeline (retryable)
-  }
+  enum :stage, { scraped: 0, media_processed: 1, deduped: 2, extracted: 3 }, default: :scraped

   has_many :images, -> { order(:position) }, dependent: :destroy
 end
```

**`app/services/media_processor.rb`** — three changes, and each one fixes a real latent bug, not just a rename:

`SKIP_STATUSES = %w[done needs_review rejected]` doesn't include `pending`. But `MediaProcessor` sets `@post.status = :pending` on *success*, meaning "media done, waiting on extraction" — the same value the model already used for "not yet processed" (`pending: 0, # ... awaiting extraction`). Because `pending` means both things, an orchestrator re-invoking `MediaProcessor.call` on an already-successful `pending` post would not skip — it would destroy and re-fetch already-good images, likely against an expired `displayUrl` by then, and spuriously fail a post that had already succeeded. The `stage` model fixes this directly: `scraped` and `media_processed` become genuinely distinct, so the skip check can never misfire this way.

```diff
-  SKIP_STATUSES = %w[done needs_review rejected].freeze
```
```diff
   def skipped?
-    SKIP_STATUSES.include?(@post.status)
+    !@post.scraped?
   end
```
```diff
       @post.images.destroy_all
       image_urls.each_with_index do |url, position|
         process_and_persist_image(url, position)
       end
-      @post.status = :pending
       @post.raw_payload = @raw_payload
+      @post.stage = :media_processed
+      @post.last_error = nil
+      @post.stage_failed_at = nil
       @post.save!
```
```diff
   def fail!(error)
     @post.images.reset
-    @post.update(status: :failed, raw_payload: @raw_payload)
+    @post.update(last_error: error.message, stage_failed_at: Time.current, raw_payload: @raw_payload)
     Result.new(status: :failed, error: error)
   rescue StandardError
     Result.new(status: :failed, error: error)
   end
```

**`app/services/adapters/apify/post_adapter.rb`** — one-line comment fix:
```diff
     # never touches the database and never raises on malformed input.
-    # Never decides Post#status — that's PostLoader's job.
+    # Never decides Post#stage/is_event — that's PostLoader's job.
     class PostAdapter
```

**Action item:** find and update `MediaProcessor`'s own test suite (not shown here) — it almost certainly asserts against `:pending`/`:done`/`:needs_review`/`:rejected`/`:failed` and `SKIP_STATUSES` directly, and every such assertion needs to move to `stage`/`last_error`/`stage_failed_at` in this same PR, or the suite won't load.

No new `Post` model validations required for `PostLoader`'s correctness — blank/duplicate shortcodes never reach `Post.create!` (filtered by the adapter's fatal check and Loader's `find_by`, respectively).

## 3. Behavior

| Situation | Action | Outcome |
|---|---|---|
| Adapter result is `fatal?` (no usable shortcode) | Nothing. No row touched. | `no_row` |
| Shortcode not found in `posts` | `Post.create!` with the adapter's attributes + `stage: :scraped` | `created` |
| Shortcode found, `post.extracted?` | Nothing. Row is left completely untouched — not even `raw_payload`. | `skipped` |
| Shortcode found, not yet `extracted?` | `post.update!` — `raw_payload` unconditionally; every other mapped field only if the new value is present (nil never overwrites) | `refreshed` |

`raw_payload` always overwrites on refresh (freshness matters — e.g. a re-issued `displayUrl` for a stalled `MediaProcessor` retry). Every other mapped field (`account`, `post_type`, `caption`, `source_url`, `posted_at`) only overwrites when the fresh scrape actually has a value — a transient scraper hiccup can never blank out data already captured. A genuine caption edit still flows through, since a real edit produces a new non-nil value.

`Post.create!`/`update!` deliberately, not `create`/`save` — a failure here should raise loudly (a real bug), not be swallowed as a pipeline-retryable condition.

## 4. Service code

**`app/services/post_loader.rb`**
```ruby
# Upserts a Post row from one adapter Result (e.g.
# Adapters::Apify::PostAdapter::Result — any adapter's Result works,
# duck-typed on #fatal? and #attributes). Owns every write to `posts`
# during ingestion. Never advances `stage` past `scraped`, and never
# touches `is_event`/`last_error`/`stage_failed_at` — those belong to
# the stage-services (MediaProcessor/Deduplicator/Extractor).
#
# Invariant: adapter_result.attributes must never contain a :stage key.
# (It doesn't today, and even if it did, .merge(stage: :scraped) below
# always wins on `create` -- Hash#merge's argument takes precedence.)
class PostLoader
  Result = Struct.new(:outcome, :post, :adapter_result, keyword_init: true) do
    def created?
      outcome == :created
    end

    def refreshed?
      outcome == :refreshed
    end

    def skipped?
      outcome == :skipped
    end

    def no_row?
      outcome == :no_row
    end
  end

  def self.call(adapter_result)
    new.call(adapter_result)
  end

  def call(adapter_result)
    return Result.new(outcome: :no_row, adapter_result: adapter_result) if adapter_result.fatal?

    post = Post.find_by(shortcode: adapter_result.attributes[:shortcode])

    if post.nil?
      post = Post.create!(adapter_result.attributes.merge(stage: :scraped))
      return Result.new(outcome: :created, adapter_result: adapter_result, post: post)
    end

    return Result.new(outcome: :skipped, adapter_result: adapter_result, post: post) if post.extracted?

    # raw_payload always overwrites -- freshness is the whole point of a
    # refresh. Every other mapped field only overwrites when the new
    # scrape actually has a value, so a transient scraper hiccup (or an
    # adapter validation miss) can never blank out data already captured.
    refreshable = adapter_result.attributes.except(:raw_payload).compact
    post.update!(refreshable.merge(raw_payload: adapter_result.attributes[:raw_payload]))
    Result.new(outcome: :refreshed, adapter_result: adapter_result, post: post)
  end
end
```

No explicit DB transaction — a single `create!`/`update!` call is already atomic. (Contrast with `MediaProcessor`, which wraps multiple `images` inserts per post in one.)

`adapter_result` is exposed on `Result` even for `created`/`refreshed`/`skipped`, so the caller can still see and log non-fatal validation errors (e.g. an unsupported `post_type` that created a row anyway) without `PostLoader` needing to duplicate that error data itself.

## 5. Test factory

**`test/factories/posts.rb`** (new — first real AR-backed factory in the app; `FactoryBot.lint` earns its keep here, unlike the Hash-only Apify factories)
```ruby
FactoryBot.define do
  factory :post do
    shortcode { Faker::Alphanumeric.unique.alphanumeric(number: 11) }
    account { Faker::Internet.username }
    post_type { "Image" }
    caption { Faker::Lorem.sentence(word_count: 12) }
    source_url { "https://www.instagram.com/p/#{shortcode}/" }
    posted_at { Faker::Time.backward(days: 30) }
    raw_payload { { "shortCode" => shortcode, "ownerUsername" => account, "type" => post_type } }
    stage { :scraped }

    trait :media_processed do
      stage { :media_processed }
    end

    trait :deduped do
      stage { :deduped }
    end

    trait :extracted do
      stage { :extracted }
      is_event { true }
    end

    trait :stalled do
      last_error { "connection reset while fetching displayUrl" }
      stage_failed_at { 1.hour.ago }
    end
  end
end
```

**Action item — verify, don't assume:** `test_helper.rb` has `fixtures :all`. Check whether `test/fixtures/posts.yml` exists with real rows before relying on this factory in the same suite.

Add (or extend) the lint test:
```ruby
# test/lint_factories_test.rb
require "test_helper"

class LintFactoriesTest < ActiveSupport::TestCase
  test "all factories can be created" do
    FactoryBot.lint traits: true
  end
end
```

## 6. Tests

**`test/services/post_loader_test.rb`**
```ruby
require "test_helper"

class PostLoaderTest < ActiveSupport::TestCase
  test "creates a new Post with every mapped attribute, when shortcode is not found" do
    apify_post = build(:apify_image_post)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.created?
    post = loader_result.post
    assert_equal apify_post["shortCode"], post.shortcode
    assert_equal apify_post["ownerUsername"], post.account
    assert_equal apify_post["type"], post.post_type
    assert_equal apify_post["caption"], post.caption
    assert_equal apify_post["url"], post.source_url
    assert_equal Time.iso8601(apify_post["timestamp"]), post.posted_at
    assert post.scraped?
    assert_nil post.is_event
    assert_nil post.last_error
  end

  test "skips entirely when the existing post is already extracted" do
    existing = create(:post, :extracted, shortcode: "ABC12345678")
    apify_post = build(:apify_image_post, short_code: "ABC12345678", caption: "totally different caption now")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    loader_result = PostLoader.call(result)

    assert loader_result.skipped?
    existing.reload
    refute_equal "totally different caption now", existing.caption
  end

  test "refreshes every mapped attribute (including raw_payload) when the post exists but isn't extracted yet" do
    existing = create(:post, :media_processed, shortcode: "ABC12345678", caption: "old caption")
    apify_post = build(:apify_image_post, short_code: "ABC12345678", caption: "updated caption")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    loader_result = PostLoader.call(result)

    assert loader_result.refreshed?
    existing.reload
    assert_equal apify_post["ownerUsername"], existing.account
    assert_equal apify_post["type"], existing.post_type
    assert_equal "updated caption", existing.caption
    assert_equal apify_post["url"], existing.source_url
    assert_equal Time.iso8601(apify_post["timestamp"]), existing.posted_at
    assert_equal apify_post, existing.raw_payload
    assert existing.media_processed?, "stage should be untouched by Loader"
  end

  test "a refresh never blanks out a previously-populated field when the new scrape has a nil for it" do
    existing = create(:post, :media_processed, shortcode: "ABC12345678", account: "clubhyphasia")
    apify_post = build(:apify_image_post, :missing_owner, short_code: "ABC12345678")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    PostLoader.call(result)

    existing.reload
    assert_equal "clubhyphasia", existing.account, "a nil in the new scrape should not overwrite existing data"
  end

  test "refreshing a stalled post does not clear last_error or stage_failed_at" do
    existing = create(:post, :media_processed, :stalled, shortcode: "ABC12345678")
    apify_post = build(:apify_image_post, short_code: "ABC12345678")

    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)
    PostLoader.call(result)

    existing.reload
    refute_nil existing.last_error
    refute_nil existing.stage_failed_at
  end

  test "creates a row for a structurally-invalid but non-fatal post, stage stays scraped" do
    apify_post = build(:apify_image_post, :unsupported_type)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.created?
    assert_equal "Video", loader_result.post.post_type
    assert loader_result.post.scraped?
  end

  test "does not create a row when the adapter result is fatal" do
    apify_post = build(:apify_image_post, :missing_shortcode)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert loader_result.no_row?
    assert_nil loader_result.post
    assert_equal 0, Post.count
  end

  test "exposes the adapter result so callers can still access error detail" do
    apify_post = build(:apify_image_post, :missing_owner)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    loader_result = PostLoader.call(result)

    assert_equal result, loader_result.adapter_result
    refute_empty loader_result.adapter_result.errors
  end

  test "propagates an unexpected error from Post.create! instead of swallowing it" do
    apify_post = build(:apify_image_post)
    result = Adapters::Apify::PostAdapter.new.parse_post(apify_post)

    Post.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid.new(Post.new) }) do
      assert_raises(ActiveRecord::RecordInvalid) do
        PostLoader.call(result)
      end
    end
  end
end
```

## 7. Explicitly out of scope for this service

- Calling `MediaProcessor`/`Deduplicator`/`Extractor` — orchestrator's job.
- Setting `is_event`, `last_error`, `stage_failed_at` — stage-services' job.
- Retry/backoff logic — a stalled post just gets re-scraped and passed through `PostLoader.call` again on the account's next cron cycle, keeping `raw_payload` fresh for the next attempt.
- Concurrent-write protection — not handled, not needed given sequential, staggered ingestion.
- Anything involving the `events` table — still open (see the master plan's flag); Loader only writes to `posts`.