#!/bin/bash
# Runs due WordPress cron events via WP-CLI.
# CLI SAPI = no HTTP/FPM timeout; flock guarantees a single concurrent run.
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
[ -r /etc/cron.d/container-env ] && . /etc/cron.d/container-env

readonly log_file="/var/log/wp_app/wp-cron.log"
readonly lock_file="/tmp/wp-cron.lock"
readonly wp_path="${WP_PATH:-/var/www/html}"
readonly debug_log="${wp_path}/wp-content/debug.log"

exec 9>"$lock_file"
if ! flock -n 9; then
    echo "[$(date -Iseconds)] previous run still active, skipping" >> "$log_file"
    exit 0
fi

# Merge both streams into one awk that splits three ways:
#   PHP Deprecated/Notice -> debug.log (raw, WP prefixes its own timestamp)
#   everything else       -> cron log, timestamped
wp --path="$wp_path" cron event run --due-now 2>&1 \
  | awk -v cron="$log_file" -v dbg="$debug_log" '
      /(PHP )?(Deprecated|Notice):/ { print >> dbg; fflush(dbg); next }
      { printf "[%s] %s\n", strftime("%Y-%m-%dT%H:%M:%S%z"), $0 >> cron; fflush(cron) }
    '