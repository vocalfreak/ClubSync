require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  # public_file_server.enabled is deliberately left at its Rails default of true.
  # A generated production.rb normally turns it off on the assumption that nginx
  # or thruster serves /public, but here cloudflared forwards straight to Puma with
  # nothing in between -- disabling it would 404 every stylesheet and script.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # ActiveStorage is unused (images live in B2 via ObjectStore) and `:local` would
  # silently write into the container's untracked layer, so the service is left unset.

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Solid Cache / Queue / Cable are deliberately not configured. Nothing in the app
  # performs fragment caching, enqueues an ActiveJob, or opens an ActionCable
  # subscription, and database.yml defines no `queue`/`cache`/`cable` connections --
  # leaving solid_queue.connects_to in place made the app fail to boot outright in
  # production. Rails' built-in defaults are correct for this single-container setup.
  # See docs/DEPLOYMENT_IMPLEMENTATION_PLAN.MD section 2.2.

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Mailers are unused (ApplicationMailer is never subclassed), so there is no
  # default_url_options host to set and no SMTP to configure.

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS rebinding protection. The Cloudflare Tunnel terminates TLS at the edge and
  # forwards to localhost:3010, so the only Host header Rails ever sees in production
  # is the public apex. Image requests are served by Cloudflare straight from B2
  # (files.cyberjayahappenings.me) and never reach this app.
  config.hosts = [ "cyberjayahappenings.me" ]

  # Skip DNS rebinding protection for the default health check endpoint, so an
  # external uptime monitor can probe /up by IP or hostname without a Host allowlist
  # entry. Uncommented together with config.hosts above; the ssl_options sibling below
  # stays commented, which is why /up answers a plain-HTTP probe with an HTTPS redirect.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
