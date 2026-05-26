# Changelog

## [1.0.0] - Initial release

- WordPress 7 / PHP 8.5-fpm base image
- Nginx + supervisor + cron + logrotate
- Cloudflare real IP refresh (weekly cron + boot)
- WP malware scan (nightly)
- Drop-in override mechanism for per-project customization:
  - `overrides/configs/nginx.d/*.conf` → http-level nginx snippets
  - `overrides/configs/php.ini.d/*.ini` → php.ini drop-ins
  - `overrides/configs/crontab.d/*` → cron jobs
  - `overrides/configs/supervisor.d/*.conf` → extra supervisor programs
  - `overrides/scripts/*.sh` → custom scripts
  - `overrides/scripts/post-entrypoint.sh` → optional boot hook
