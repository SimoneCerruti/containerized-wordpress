#!/bin/bash
set -euo pipefail

OUTPUT=/etc/nginx/conf.d/cloudflare-ips.conf
TMP=$(mktemp)

{
  echo "# Auto-generated $(date -Iseconds) - DO NOT EDIT"
  curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 | awk '{print "set_real_ip_from " $1 ";"}'
  curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 | awk '{print "set_real_ip_from " $1 ";"}'
  echo "# Docker internal networks"
  echo "set_real_ip_from 172.16.0.0/12;"
  echo "set_real_ip_from 10.0.0.0/8;"
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > "$TMP"

# Validate before swap
if [ ! -s "$TMP" ]; then
  echo "ERROR: generated file is empty, aborting" >&2
  rm -f "$TMP"
  exit 1
fi

mv "$TMP" "$OUTPUT"

# Test config, reload only if valid
if nginx -t 2>/dev/null; then
  nginx -s reload
  echo "Cloudflare IPs updated and nginx reloaded"
else
  echo "ERROR: nginx config test failed after update" >&2
  exit 1
fi