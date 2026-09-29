source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.2"
# ActiveSupport::JSON.encode passes quirks_mode: to JSON.generate, which
# json 3.x (bundled with Ruby 3.4) removed — pin to 2.x so jsonb columns work.
gem "json", "~> 2.12"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
gem "tailwindcss-rails", "~> 4.3"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use for object/image storage
gem "aws-sdk-s3"
gem "ruby-vips"

# All runtime config comes from the UNIX environment
# but we use dotenv to store that in files for
# development and testing
gem "dotenv-rails", groups: [ :development, :test ]

# solid_cache, solid_queue and solid_cable are intentionally NOT dependencies.
# All three engines eagerly load their Record classes on boot, and each one calls
# connects_to for its own database, so with only a single `production` connection
# in database.yml the app raised AdapterNotSpecified and could not start at all.
# Nothing here fragment-caches, enqueues an ActiveJob, or opens an ActionCable
# subscription, so Rails' built-in defaults are correct for this single-container
# setup. Add a gem back together with the database.yml connection and the process
# that serves it -- a database-backed queue also needs a supervisor to run jobs.
# See docs/DEPLOYMENT_IMPLEMENTATION_PLAN.MD section 2.2.

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# bundler-audit enables bundle audit which analyzes our
# dependencies for known vulnerabilities
gem "bundler-audit"

# lograge changes Rails' logging to a more
# traditional one-line-per-event format
gem "lograge"

# Cron job scheduling
gem "whenever", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "factory_bot_rails"
  gem "faker"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end
