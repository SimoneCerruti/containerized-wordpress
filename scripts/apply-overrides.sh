#!/bin/bash
# Applies per-project overrides into the appropriate drop-in directories.
# Called from entrypoint.sh at container boot.
#
# Project overrides are mounted/copied at /opt/overrides/ by the project's
# Dockerfile (or via volume in dev mode).
#
# Layout:
#   /opt/overrides/configs/nginx.d/*.conf      -> /etc/nginx/conf.d/
#   /opt/overrides/configs/php.ini.d/*.ini     -> /usr/local/etc/php/conf.d/
#   /opt/overrides/configs/crontab.d/*         -> /etc/cron.d/
#   /opt/overrides/configs/supervisor.d/*.conf -> /etc/supervisor/conf.d/
#   /opt/overrides/scripts/*.sh                -> /usr/local/bin/ (made executable)

set -uo pipefail

OVR=/opt/overrides
LOG=/var/log/wp_app/apply-overrides.log
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

if [[ ! -d "$OVR" ]]; then
    log "No overrides dir at $OVR, skipping"
    exit 0
fi

copy_dropin() {
    local src="$1" dst="$2" pattern="$3"
    [[ ! -d "$src" ]] && return 0
    shopt -s nullglob
    local files=("$src"/$pattern)
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
        return 0
    fi
    mkdir -p "$dst"
    for f in "${files[@]}"; do
        cp -f "$f" "$dst/"
        log "Applied override: $f -> $dst/$(basename "$f")"
    done
}

# nginx snippets - included via /etc/nginx/conf.d/*.conf
# NOTE: site-specific server-level rules must use a different mechanism;
# these conf.d files are loaded at http {} level.
copy_dropin "$OVR/configs/nginx.d"     "/etc/nginx/conf.d"            "*.conf"

# php.ini drop-ins (highest number wins, processed alphabetically)
copy_dropin "$OVR/configs/php.ini.d"   "/usr/local/etc/php/conf.d"    "*.ini"

# cron jobs
copy_dropin "$OVR/configs/crontab.d"   "/etc/cron.d"                  "*"
# cron requires strict permissions on /etc/cron.d files
if compgen -G "/etc/cron.d/*" > /dev/null; then
    chmod 0644 /etc/cron.d/* 2>/dev/null || true
    chown root:root /etc/cron.d/* 2>/dev/null || true
fi

# supervisor extras
copy_dropin "$OVR/configs/supervisor.d" "/etc/supervisor/conf.d"      "*.conf"

# custom scripts
if [[ -d "$OVR/scripts" ]]; then
    shopt -s nullglob
    for s in "$OVR/scripts"/*.sh; do
        cp -f "$s" "/usr/local/bin/$(basename "$s")"
        chmod +x "/usr/local/bin/$(basename "$s")"
        log "Applied script: $(basename "$s")"
    done
    shopt -u nullglob
fi

# Run post-entrypoint hook if provided by the project
if [[ -x /usr/local/bin/post-entrypoint.sh ]]; then
    log "Running post-entrypoint.sh hook"
    /usr/local/bin/post-entrypoint.sh || log "WARN: post-entrypoint.sh exited non-zero"
fi

log "Overrides applied successfully"
