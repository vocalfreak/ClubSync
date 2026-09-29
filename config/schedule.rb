# clubSync's cron schedule, managed by the whenever gem.
#
# The app runs in a Docker container on the E5440, so the host-level crontab
# delegates into the container rather than running a scheduler inside it.
# Every 2 days, matching the healthchecks.io period (see docs/HEALTH_MONITORING_PLAN.md §5).
#
# Installation — run this on the HOST, from the checkout root, NOT in a container:
#
#   gem install whenever
#   whenever --update-crontab
#
# `whenever --update-crontab` inside the container would write a crontab into the
# container's own filesystem, which is discarded on the next rebuild.

# Absolute path to the checkout on the E5440. Needed because cron runs with $HOME
# as its working directory, so a bare `docker compose` would not find the compose
# file. EDIT THIS to match where the repo actually lives on the box.
APP_ROOT = "/srv/clubsync"

# cron runs with a minimal PATH (typically /usr/bin:/bin), so docker is called by
# absolute path. Verify with `which docker` on the box -- if it is not
# /usr/bin/docker, change this.
DOCKER = "/usr/bin/docker"

every 2.days, at: "3:00 am" do
  # -T: cron has no TTY, and `docker compose exec` refuses to allocate one without it.
  # Redirect: cron mails stdout to nobody, so without this the run's output is lost.
  command "cd #{APP_ROOT} && #{DOCKER} compose exec -T app bin/rails clubsync:ingest >> #{APP_ROOT}/log/cron.log 2>&1"
end
