# containerized-wordpress architecture

## Scope

This base is **opinionated for production**:

- Sits behind **Traefik** (host-level, terminates TLS). `compose.example.yml`
  ships with Traefik labels and the network wiring.
- Sits behind **Cloudflare** (DNS + proxy). `cloudflare-ips.sh` keeps
  `set_real_ip_from` in sync so nginx logs and rate-limits see real
  client IPs.
- Targeted at **migrating existing WordPress sites** (DB dump + uploads
  imported into the named volume) rather than provisioning brand-new
  installs. The base entrypoint **does not** copy WordPress core from
  `/usr/src/wordpress` to `/var/www/html` on first boot — see
  "Initializing a brand-new site" below for the one-line command if
  you really do need a fresh install.
- Managed via [`wpbase-cli`](https://github.com/SimoneCerruti/wpbase-cli) (one
  base, many projects, atomic version swaps).

If your deployment doesn't match this shape, the override mechanism
covers most adjustments — but the defaults assume the above.

## Repos

### `containerized-wordpress` (this repo, published on GitHub)
The reusable, versioned base. Releases are tagged (e.g. `v1.0.0`).

```
containerized-wordpress/
├── VERSION                       # 1.0.0
├── Dockerfile.base               # builds the WP+nginx+php-fpm+cron image
├── compose.base.yml              # versioned compose snippet, included by projects
├── compose.example.yml           # reference per-project docker-compose.yml
├── .env.example                  # template for project-root .env
├── .env.wordpress.example        # template for runtime container env
├── configs/                      # default configs (nginx, php, supervisor, cron, ...)
├── scripts/                      # entrypoint, healthcheck, wp-cron, malware-scan, ...
├── overrides/.gitkeep            # empty so the base can be built standalone
├── SCRIPTS.md                    # what each bundled script does + env vars
└── CHANGELOG.md                  # versioning policy + per-release entries
```

### Per-project repo (one per site)
```
my-project/
├── .base-version            # pinned base version, e.g. 1.0.0
├── docker-compose.yml       # uses base/compose.base.yml via `include:`
├── .env                     # compose-level vars (NOT committed)
├── .env.wordpress           # runtime container vars (NOT committed)
├── base/                    # SNAPSHOT of containerized-wordpress v{X.Y.Z}
│   ├── Dockerfile.base
│   ├── compose.base.yml     # included by project's docker-compose.yml
│   ├── configs/
│   ├── scripts/
│   ├── overrides/.gitkeep   # base's empty overrides — ignored at build
│   └── .checksum            # auto-managed by wpbase, detect drift
└── overrides/               # ⭐ ALL project-specific customizations
    ├── configs/
    │   ├── nginx.d/         # nginx http {}-level snippets
    │   ├── server.d/        # nginx server {}-level snippets (add locations/directives)
    │   ├── php.ini.d/       # php.ini drop-ins
    │   ├── crontab.d/       # cron.d files (per-project cron jobs)
    │   └── supervisor.d/    # extra supervisor programs
    └── scripts/             # custom scripts (e.g. post-entrypoint.sh hook)
```

## How customization works

At container boot, `entrypoint.sh` calls `apply-overrides.sh` which copies
`/opt/overrides/configs/*` (baked at build time from the project's `overrides/`)
into the appropriate drop-in directories:

| Project file                            | Goes to                            |
| --------------------------------------- | ---------------------------------- |
| `overrides/configs/nginx.d/*.conf`      | `/etc/nginx/conf.d/` (http scope)  |
| `overrides/configs/server.d/*.conf`     | `/etc/nginx/server.d/` (server scope) |
| `overrides/configs/php.ini.d/*.ini`     | `/usr/local/etc/php/conf.d/`       |
| `overrides/configs/crontab.d/*`         | `/etc/cron.d/`                     |
| `overrides/configs/supervisor.d/*.conf` | `/etc/supervisor/conf.d/`          |
| `overrides/scripts/*.sh`                | `/usr/local/bin/`                  |
| `overrides/scripts/post-entrypoint.sh`  | Executed after overrides applied   |

This means **no merging logic is needed**: each subsystem natively supports
drop-in directories.

## Bootstrapping a new project

On first setup, a project needs:

1. `base/` populated by `wpbase install <version> <path>`.
2. A `docker-compose.yml` at the project root. Start from
   [compose.example.yml](compose.example.yml) — it `include:`s
   `base/compose.base.yml` so the WP service shape (build, healthcheck,
   named volumes) stays pinned to the base version.
3. `.env` and `.env.wordpress` at the project root. Start from
   [.env.example](.env.example) and
   [.env.wordpress.example](.env.wordpress.example) and fill in the
   secrets. Add both to the project's `.gitignore`.

The MySQL credentials live ONLY in `.env`. Compose interpolates
`${MYSQL_*}` references inside `.env.wordpress` before handing it to
the container, so WP and the db service always agree.

Requires **Docker Compose v5.1+**: the project's `docker-compose.yml`
`include:`s `base/compose.base.yml` and redefines the `wp` service to add
labels/networks — Compose only merges an overridden imported service from
v5.1+ (v2.x errors with `services.wp conflicts with imported resource`).
Install it on the host with `apt-get install docker-compose-plugin`.

For details on what each bundled script does and the env vars it
consumes, see [SCRIPTS.md](SCRIPTS.md).

## Migrating a WordPress site into the container

Typical workflow (assumes you already have the SQL dump and
`wp-content/` from the source site):

```bash
# 1. Boot the stack — db comes up empty, WP volume is empty.
docker compose up -d

# 2. Import the SQL dump into the db container.
docker compose exec -T db \
    mariadb -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" \
    < /path/on/host/dump.sql

# 3. Drop the site files into the wp_html volume.
docker compose cp /path/on/host/wp-content wp:/var/www/html/
docker compose exec wp chown -R www-data:www-data /var/www/html

# 4. (Optional) Search-replace the old domain in the DB.
docker compose exec wp wp --allow-root \
    search-replace 'https://old.example.com' 'https://new.example.com'

# 5. Flush caches.
docker compose exec wp wp --allow-root cache flush
```

## Initializing a brand-new site

The base does NOT auto-install WP core (the upstream entrypoint that
copies `/usr/src/wordpress/*` to `/var/www/html` is replaced by our own
that only generates `wp-config.php`). For a fresh install:

```bash
# 1. Bring the stack up.
docker compose up -d

# 2. Populate /var/www/html from the WordPress files baked into the image.
docker compose exec wp bash -c \
    'cp -a /usr/src/wordpress/. /var/www/html/ && chown -R www-data:www-data /var/www/html'

# 3. Run the WP installer via wp-cli.
docker compose exec wp wp --allow-root core install \
    --url="https://${WP_DOMAIN}" \
    --title="My Site" \
    --admin_user="admin" \
    --admin_password="change_me" \
    --admin_email="you@example.com"
```

## Updating a project

Project lifecycle (install, update, drift detection) is managed via
[`wpbase-cli`](https://github.com/SimoneCerruti/wpbase-cli), a host-side bash
tool that downloads release tarballs from this repo and swaps them into each
project's `base/` directory.

On the host (no git installed there):

```bash
# Install the base into a new project
wpbase install 1.0.0 /srv/projects/my-project

# Show what would change across all projects
wpbase update-all                                # dry-run by default

# Apply: confirm each, do not rebuild
wpbase update-all --version 1.1.0

# Apply: rebuild + restart all
wpbase update-all --version 1.1.0 --yes --build

# Single project
wpbase update /srv/projects/my-project --version 1.1.0 --build

# See if a project has manual edits to base/
wpbase diff /srv/projects/my-project
```

`wpbase` downloads the auto-generated GitHub tarball for the tag, extracts
the versioned files (`Dockerfile.base`, `compose.base.yml`, `configs/`,
`scripts/`, `VERSION`) into the project's `base/` directory (atomically
swapped), updates `.base-version`, and records a checksum to detect future
manual drift.