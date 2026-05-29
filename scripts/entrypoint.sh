#!/bin/bash
set -Eeuo pipefail

# ---- GENERATE wp-config.php (extracted from docker-entrypoint.sh) ----
cd /var/www/html

wpEnvs=( "${!WORDPRESS_@}" )
if [ ! -s wp-config.php ] && [ "${#wpEnvs[@]}" -gt 0 ]; then
    for wpConfigDocker in \
        wp-config-docker.php \
        /usr/src/wordpress/wp-config-docker.php \
    ; do
        if [ -s "$wpConfigDocker" ]; then
            echo >&2 "No 'wp-config.php' found, generating from WORDPRESS_* variables..."
            awk '
                /put your unique phrase here/ {
                    cmd = "head -c1m /dev/urandom | sha1sum | cut -d\\  -f1"
                    cmd | getline str
                    close(cmd)
                    gsub("put your unique phrase here", str)
                }
                { print }
            ' "$wpConfigDocker" > wp-config.php
            chown www-data:www-data wp-config.php || true
            echo >&2 "wp-config.php generated successfully."
            break
        fi
    done
fi

# ---- Apply project-specific overrides ----
/usr/local/bin/apply-overrides.sh || echo "WARN: apply-overrides.sh failed (continuing)"

# ---- Refresh Cloudflare IPs at startup (best effort) ----
/usr/local/bin/cloudflare-ips.sh || echo "Could not refresh Cloudflare IPs at startup"

# ---- Export env vars for cron ----
# Snapshot a curated set of env vars to a file the cron jobs source (cron runs
# jobs with a stripped environment). Each value is emitted with `printf %q`, so
# the line is always safe to `source` under bash even when the value contains
# spaces, $, quotes, backticks or other shell metacharacters — a raw `KEY=VAL`
# dump would break sourcing (or worse, allow injection). `export` so the values
# propagate to the scripts those cron jobs invoke.
{
    for name in $(compgen -v); do
        case "$name" in
            WORDPRESS_CONFIG_EXTRA) continue ;;
            WP_PATH|MALWARE_SCAN_*|WORDPRESS_*)
                printf 'export %s=%q\n' "$name" "${!name}"
                ;;
        esac
    done
} > /etc/cron.d/container-env
chmod 640 /etc/cron.d/container-env
chown root:www-data /etc/cron.d/container-env

exec supervisord -c /etc/supervisor/supervisord.conf -n
