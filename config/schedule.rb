# clubSync's cron schedule, managed by the whenever gem.
# Installation: `bundle exec whenever --update-crontab clubsync`
#
# The app runs in a Docker container on the E5440, so the host-level crontab
# delegates into the container rather than running a scheduler inside it.
# Every 2 days, matching the healthchecks.io period (see docs/HEALTH_MONITORING_PLAN.md §5).

every 2.days do
  command "docker compose exec app bin/rails clubsync:ingest"
end
