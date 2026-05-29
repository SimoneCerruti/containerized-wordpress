#!/bin/bash
# Runs due WordPress cron events via WP-CLI.
# CLI SAPI = no HTTP/FPM timeout; flock guarantees a single concurrent run.
set -uo pipefail

readonly log_file="/var/log/wp_app/wp-cron.log"
readonly lock_file="/tmp/wp-cron.lock"

exec 9>"$lock_file"
if ! flock -n 9; then
    echo "[$(date -Iseconds)] previous run still active, skipping" >> "$log_file"
    exit 0
fi

wp --path=/var/www/html cron event run --due-now 2>&1 \
  | { grep -vaE '^(PHP )?(Deprecated|Notice):' || true; } >> "$log_file"