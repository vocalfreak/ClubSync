# Keep in sync with .ruby-version. 3.3 built and ran, but it meant the image
# shipped a different Ruby than the one dev and test actually exercise.
FROM ruby:3.4-slim

# build-essential + libpq-dev: native gem compilation (pg, etc.)
# libvips-dev: required at runtime by ruby-vips for image reisze and dHash
# git/curl: bundler sometimes needs these for git-sourced gems / healthchecks
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    libvips-dev \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Separate layer so `bundle install` only reruns when the Gemfile actually changes
COPY Gemfile Gemfile.lock ./
# dev/test groups are not needed at runtime, so the production image skips
# dotenv, brakeman, web-console and the test tooling. Deliberately NOT setting
# BUNDLE_DEPLOYMENT: it implies path=vendor/bundle, which would install gems into
# the app layer and defeat the bundle_cache volume mounted at /usr/local/bundle.
#
# RAILS_ENV must be set globally, not just on the precompile line. Rails falls back
# to the *development* environment when it is unset, which would mean both
# entrypoint.sh's `db:prepare` and the `rails server` CMD booted development.rb --
# no config.hosts, no force_ssl, no eager_load, and full source snippets in error
# pages served to anyone on the internet.
ENV BUNDLE_WITHOUT="development:test" \
    RAILS_ENV=production
RUN bundle install --jobs 4 --retry 3

COPY . .

# tailwindcss-rails enhances assets:precompile with tailwindcss:build, so this
# single command also produces app/assets/builds/tailwind.css. It must happen in
# the image because .dockerignore excludes /app/assets/builds and there is no
# .:/app bind mount to supply it at runtime. SECRET_KEY_BASE_DUMMY lets this boot
# without a real secret -- the build must never need the production one.
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["entrypoint.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
