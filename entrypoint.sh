#!/bin/bash
set -e

# Clear a stale PID file from an unclean shutdown
rm -f /app/tmp/pids/server.pid

# Idempotent: creates the DB if missing, runs pending migrations otherwise.
# Safe to run on every container start.
bundle exec rails db:prepare

exec "$@"
