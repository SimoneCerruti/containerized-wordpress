# Changelog

## Versioning policy

This repo follows [Semantic Versioning](https://semver.org/):
`MAJOR.MINOR.PATCH`. Each release is a git tag (`vX.Y.Z`) on `main`
matching the contents of [VERSION](VERSION).

### What constitutes a change

- **MAJOR (X.0.0)** — breaking change to the consumer contract.
  Consumers must update their project alongside the base bump.
  Examples:
  - A drop-in directory is renamed or removed
    (e.g. `overrides/configs/nginx.d/` → `overrides/configs/http.d/`).
  - An environment variable previously consumed by a base script is
    removed or its meaning changes.
  - A bundled script's CLI or expected inputs change.
  - `compose.base.yml` changes service name, removes a volume mount, or
    changes an `include:`-facing path in a way that breaks existing
    project compose files.
  - Required base image bump that changes PHP/WP major version.

- **MINOR (1.X.0)** — additive, backward-compatible.
  Examples:
  - New drop-in directory added to `apply-overrides.sh`.
  - New optional env var with a safe default.
  - New script bundled in `scripts/`.
  - New default security header in `configs/nginx.conf` that doesn't
    break existing sites.

- **PATCH (1.0.X)** — bug fix or internal cleanup.
  Examples:
  - Fix a typo or regex bug in `wp-malware-scan.sh`.
  - Tighten file permissions on a drop-in destination.
  - Update Cloudflare IP fetch URL.

### Upgrade procedure

For each registered project on a host:

1. **Stage first.** Bump one project (ideally a staging clone) before
   rolling out broadly:
   ```bash
   wpbase update /srv/projects/staging-site --version 1.X.Y --build
   ```
2. **Verify health.** Confirm the container reports healthy and the
   site responds:
   ```bash
   docker compose -f /srv/projects/staging-site/docker-compose.yml ps
   curl -sf https://staging.example.com/robots.txt
   ```
3. **Check logs for regressions.**
   ```bash
   docker compose -f /srv/projects/staging-site/docker-compose.yml \
     exec wp tail -n 200 /var/log/wp_app/{nginx.error,php-fpm,apply-overrides}.log
   ```
4. **Roll out.** Once staging is clean:
   ```bash
   wpbase update-all --version 1.X.Y --yes --build
   ```
5. **Read the entry for this version below** before bumping a MAJOR —
   it lists every breaking change and the migration step required.

### Entry format

Each released version has a section like:

```markdown
## [1.1.0] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Fixed
- ...

### Breaking (MAJOR only)
- <change> — migration: <what consumers must do>
```

Unreleased work goes under an `## [Unreleased]` header at the top.
Move entries to a versioned section when cutting the release.

---

## [Unreleased]

### Changed
- `.env.wordpress.example`: add an explicit `WORDPRESS_DEBUG=0` (the image's
  master switch for `WP_DEBUG`) and correct the surrounding comment — the
  existing `WP_DEBUG_LOG` / `WP_DEBUG_DISPLAY` lines only take effect when
  `WORDPRESS_DEBUG=1`. No runtime change (debug was already off by default);
  flip to `1` for silent error logging to `wp-content/debug.log`. Template-only.
- `wp-malware-scan.sh`: the scan report email is now **English** (was Italian).
  Project convention is now English everywhere, including user-facing output
  (CLAUDE.md updated). Affects the baked-in script, so it ships in the image.

## [1.0.1] - 2026-05-26

Template-only changes (PATCH). These touch the starter files scaffolded into
the project root on `wpbase install` — `base/` and the image are unchanged.
Existing projects keep their own `docker-compose.yml`/`.env*`; only **new**
installs pick these up.

### Changed
- `compose.example.yml`: default `certresolver` → `cloudflare`; added a
  `www → non-www` redirect router + middleware (with a commented
  `non-www → www` alternative); publish the `db` port on the host loopback
  (`127.0.0.1:${DB_FORWARD_PORT}:3306`); explicit `.service` on the redirect
  router; explicit `driver: bridge` on the `default` network.
- `.env.example`: renamed `DB_PORT` → `DB_FORWARD_PORT` with a comment — it is
  the host-side published port only (loopback), unrelated to the in-container
  `db:3306` connection; vary it when one host runs several MariaDB containers.
- `.env.wordpress.example`: `WORDPRESS_DB_HOST` hardcoded to `db:3306`,
  decoupling the WP→db connection from the host-forward port.

## [1.0.0] - Initial release

### Image & stack
- WordPress 7 / PHP 8.5-fpm base image.
- Nginx + supervisor + cron + logrotate under a single supervisord PID.
- Cloudflare real IP refresh (weekly cron + boot).
- WP malware scan (nightly). All scan-specific env vars are prefixed
  `MALWARE_SCAN_` (`MALWARE_SCAN_NOTIFY_EMAIL`, `MALWARE_SCAN_PATH_EXCLUDES`,
  `MALWARE_SCAN_WHITELIST`, `MALWARE_SCAN_STATE_DIR`, `MALWARE_SCAN_ADMIN_DAYS`,
  `MALWARE_SCAN_LOG_FILE`).

### Override mechanism (per-project customization)
- `overrides/configs/nginx.d/*.conf` → nginx `http {}`-level snippets.
- `overrides/configs/server.d/*.conf` → nginx `server {}`-level snippets,
  included at the **end** of the server block. For **adding** `location`
  blocks and server-level directives; cannot redefine directives/locations
  already set in the base (see CLAUDE.md gotcha #1).
- `overrides/configs/php.ini.d/*.ini` → php.ini drop-ins.
- `overrides/configs/crontab.d/*` → cron jobs.
- `overrides/configs/supervisor.d/*.conf` → extra supervisor programs.
- `overrides/scripts/*.sh` → custom scripts.
- `overrides/scripts/post-entrypoint.sh` → optional boot hook.

### Compose & config delivery
- `compose.base.yml` — versioned `wp` service shape (build args, healthcheck,
  named volumes, `env_file`), `include:`d by the project's
  `docker-compose.yml`. Requires Docker Compose v2.24+ (`project_directory:`).
- `compose.example.yml`, `.env.example`, `.env.wordpress.example` — starter
  templates copied into the project root on first setup (never into `base/`).

### Tooling & release plumbing
- `release.yml` verifies `VERSION` == pushed tag and publishes the GitHub
  Release. `.githooks/pre-push` enforces the same check locally (opt-in via
  `git config core.hooksPath .githooks`).
- `.dockerignore` keeps the standalone build context minimal.
- `base/` extraction contract for `wpbase-cli`: it must extract
  `compose.base.yml` in addition to `Dockerfile.base`, `VERSION`, `configs/`,
  and `scripts/`. (The full layout + change brief are maintained as
  gitignored, local-only handoff docs for the wpbase-cli maintainer.)
