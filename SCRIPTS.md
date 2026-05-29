# Scripts reference

Every script lives under `scripts/` in this repo and is baked into the
image by [Dockerfile.base](Dockerfile.base). This file documents what each
one does, when it runs, and which environment variables it consumes.

## entrypoint.sh

**Where**: `/entrypoint.sh` inside the container — the image `CMD`.

**Runs**: once at container start.

**Does**:
1. Generates `wp-config.php` from `wp-config-docker.php` if missing,
   substituting unique salts (mirrors the upstream WordPress image
   behavior).
2. Invokes [apply-overrides.sh](scripts/apply-overrides.sh) to lay down
   per-project drop-in files.
3. Refreshes Cloudflare IP ranges (best-effort, ignores failures).
4. Snapshots a curated set of env vars to `/etc/cron.d/container-env` so
   cron jobs inherit them (cron strips the parent env by default).
5. Hands off to `supervisord -n` which then runs nginx, php-fpm, and
   cron under one PID.

**Reads env**:
- Any `WORDPRESS_*` — used to generate `wp-config.php`.
- `WP_PATH`, every `MALWARE_SCAN_*`, and every `WORDPRESS_*` — snapshotted
  to cron via `/etc/cron.d/container-env` (grep `^(WP_PATH|MALWARE_SCAN_|WORDPRESS_)`).

## apply-overrides.sh

**Where**: `/usr/local/bin/apply-overrides.sh`.

**Runs**: once at container start, from `entrypoint.sh`.

**Does**: copies the project's customization files from `/opt/overrides/`
(baked into the image by the project's `Dockerfile.base` COPY) into the
native drop-in directories that nginx, php, cron, and supervisor watch:

| Source under `/opt/overrides/`     | Destination                       |
| ---------------------------------- | --------------------------------- |
| `configs/nginx.d/*.conf`           | `/etc/nginx/conf.d/` (http scope) |
| `configs/server.d/*.conf`          | `/etc/nginx/server.d/` (server scope) |
| `configs/php.ini.d/*.ini`          | `/usr/local/etc/php/conf.d/`      |
| `configs/crontab.d/*`              | `/etc/cron.d/` (chmod 0644)       |
| `configs/supervisor.d/*.conf`      | `/etc/supervisor/conf.d/`         |
| `scripts/*.sh`                     | `/usr/local/bin/` (chmod +x)      |
| `scripts/post-entrypoint.sh`       | invoked after the copies above    |

**No merging logic**: each subsystem natively supports drop-in
directories, so this is just `cp -f`.

**Logs to**: `/var/log/wp_app/apply-overrides.log`.

## healthcheck.sh

**Where**: `/healthcheck.sh`.

**Runs**: as the container `HEALTHCHECK` (configured in
[compose.base.yml](compose.base.yml), every 30s with a 60s grace period).

**Checks** (any failure → exit 1):
1. `supervisorctl status` responds.
2. PHP-FPM `/ping` answers `pong` over fastcgi (via `cgi-fcgi`).
3. Nginx responds to `GET /robots.txt` or `GET /` on `127.0.0.1`.

## cloudflare-ips.sh

**Where**: `/usr/local/bin/cloudflare-ips.sh`.

**Runs**:
- Once at image build (best-effort bootstrap).
- Once at container start (refresh).
- Weekly via cron (Sunday 4 AM, see `configs/crontab`).

**Does**: fetches `https://www.cloudflare.com/ips-v4` and
`/ips-v6`, writes `set_real_ip_from ...;` directives to
`/etc/nginx/conf.d/cloudflare-ips.conf`, validates the config with
`nginx -t`, and reloads nginx. Aborts the swap if validation fails.

**Why**: lets nginx see the real client IP via the `CF-Connecting-IP`
header instead of Cloudflare's edge IP — required for accurate logs,
rate limiting, and WordPress IP-based security plugins.

**Logs to**: `/var/log/wp_app/cloudflare-ips.log` (weekly cron run only).

## wp-cron.sh

**Where**: `/usr/local/bin/wp-cron.sh`.

**Runs**: scheduled by the base `configs/crontab` every 5 minutes
(`*/5 * * * * www-data`). Projects no longer need a `crontab.d/` entry
for the loopback trigger.

**Does**: runs all due WordPress cron events via WP-CLI
(`wp cron event run --due-now`) against `/var/www/html`. CLI SAPI means
no HTTP / php-fpm timeout, so long-running events (e.g. WooCommerce
action scheduler batches) finish without being cut off. `flock -n` on
`/tmp/wp-cron.lock` guarantees a single concurrent run — if the previous
tick is still active, this run is skipped and noted in the log.

Trade-off vs. an HTTP loopback: CLI SAPI has no HTTP request context
(no `$_SERVER['HTTP_HOST']`, no nginx-set headers). Most plugins are
fine — but anything that strictly needs an HTTP context will misbehave.

**Reads env**: none directly. The script hardcodes `--path=/var/www/html`
(the WP install location in this base image).

**Logs to**: `/var/log/wp_app/wp-cron.log` — all WP-CLI output, with
`PHP Deprecated:` / `PHP Notice:` lines filtered out.

## wp-malware-scan.sh

**Where**: `/usr/local/bin/wp-malware-scan.sh`.

**Runs**: scheduled by the base `configs/crontab` nightly at 03:17
(`17 3 * * * www-data`). The job sources `/etc/cron.d/container-env`
first so the scan sees `WP_PATH` + `MALWARE_SCAN_*`. If
`MALWARE_SCAN_NOTIFY_EMAIL` is unset on a given site, the script logs
an error and exits 0 — effectively a no-op until configured. Projects
no longer need a `crontab.d/` entry for the scan.

**Does**: a layered scan of the WordPress install, designed to be quiet
when clean and email an Italian-language report when anything looks off.
Layers:
1. `wp core verify-checksums` and `wp plugin verify-checksums --all`.
2. Any `.php` (or PHP-bearing image) inside `wp-content/uploads/` —
   treated as critical.
3. High-signal regex patterns (eval+$_GET, known shell signatures, etc.) —
   critical.
4. Weak regex indicators (`eval`, `base64_decode`, `gzinflate`, ...)
   scored across files; threshold ≥ 3 → suspect.
5. Every file in `wp-content/mu-plugins/` listed for manual review
   (auto-loaded code is high-risk by definition).
6. WP cron hooks: flagged if name matches malicious patterns or if the
   hook is an orphan (registered but no `.php` references it).
7. Administrator accounts created within the last `MALWARE_SCAN_ADMIN_DAYS`.

Suppression channels (both consulted before email):
- `MALWARE_SCAN_PATH_EXCLUDES` — glob patterns for vendored libraries, one
  per line. Defaults to `/etc/wp-malware-scan/path-excludes.txt` (the base
  ships a starter list).
- `MALWARE_SCAN_WHITELIST` — SHA-256 hashes of known-good files, one per line.
  Append with `sha256sum /path/to/file >> $MALWARE_SCAN_WHITELIST`.

If anything survives filtering, sends an email via `wp_mail()` (so
configured SMTP plugins like wp-mail-smtp are honored). Always
exits 0 to avoid cron mail spam — errors land in the log file.

**Reads env** (all scan-specific vars are prefixed `MALWARE_SCAN_`):
- `WP_PATH` (required), `MALWARE_SCAN_NOTIFY_EMAIL` (required).
- `WP_CLI`, `MALWARE_SCAN_WHITELIST`, `MALWARE_SCAN_PATH_EXCLUDES`,
  `MALWARE_SCAN_STATE_DIR`, `MALWARE_SCAN_ADMIN_DAYS`, `MALWARE_SCAN_LOG_FILE`
  (all optional, with sensible defaults).

**Logs to**: `/var/log/wp_app/wp-malware-scan.log`.

**State dir**: `/var/lib/wp-malware-scan/` — preserved via the
`wp_malware_state` named volume from compose.base.yml so whitelist
hashes survive container restarts.

## post-entrypoint.sh (optional, project-supplied)

**Where**: `/usr/local/bin/post-entrypoint.sh` — only present if the
project ships `overrides/scripts/post-entrypoint.sh`.

**Runs**: at the end of `apply-overrides.sh`, before supervisord takes
over.

**Use for**: project-specific boot-time setup that can't be expressed
as a drop-in file — e.g. seeding a flag file, warming a cache, running
a one-shot wp-cli migration.
