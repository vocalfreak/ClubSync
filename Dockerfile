FROM ruby:3.3-slim

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
RUN bundle install --jobs 4 --retry 3

COPY . .

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["entrypoint.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
