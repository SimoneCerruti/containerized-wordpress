#!/bin/bash
# Triggers WordPress cron via HTTP loopback through php-fpm
# Logs invocation and curl exit code for diagnostics

set -uo pipefail

LOG=/var/log/wp_app/wp-cron.log

curl -fsS -m 55 -o /dev/null "http://127.0.0.1/wp-cron.php?doing_wp_cron=1"
EXIT=$?

if [ $EXIT -ne 0 ]; then
    echo "[$(date -Iseconds)] curl failed with exit $EXIT" >> "$LOG"
fi

exit $EXIT