# dockerized-wordpress architecture

## Repos

### `dockerized-wordpress` (this repo, published on GitHub)
The reusable, versioned base. Releases are tagged (e.g. `v1.0.0`).

```
dockerized-wordpress/
├── VERSION                  # 1.0.0
├── Dockerfile.base          # builds the WP+nginx+php-fpm+cron image
├── configs/                 # default configs (nginx, php, supervisor, cron, ...)
├── scripts/                 # entrypoint, healthcheck, wp-cron, malware-scan, ...
└── overrides/.gitkeep       # empty so the base can be built standalone
```

### Per-project repo (one per site)
```
my-project/
├── .base-version            # pinned base version, e.g. 1.0.0
├── docker-compose.yml       # uses base/Dockerfile.base as Dockerfile
├── .env                     # secrets (NOT committed)
├── .env.wordpress           # secrets (NOT committed)
├── base/                    # SNAPSHOT of dockerized-wordpress v{X.Y.Z}
│   ├── Dockerfile.base
│   ├── configs/
│   ├── scripts/
│   ├── overrides/.gitkeep   # base's empty overrides — ignored at build
│   └── .checksum            # auto-managed by wpbase, detect drift
└── overrides/               # ⭐ ALL project-specific customizations
    ├── configs/
    │   ├── nginx.d/         # nginx http-level snippets
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
| `overrides/configs/nginx.d/*.conf`      | `/etc/nginx/conf.d/`               |
| `overrides/configs/php.ini.d/*.ini`     | `/usr/local/etc/php/conf.d/`       |
| `overrides/configs/crontab.d/*`         | `/etc/cron.d/`                     |
| `overrides/configs/supervisor.d/*.conf` | `/etc/supervisor/conf.d/`          |
| `overrides/scripts/*.sh`                | `/usr/local/bin/`                  |
| `overrides/scripts/post-entrypoint.sh`  | Executed after overrides applied   |

This means **no merging logic is needed**: each subsystem natively supports
drop-in directories.

## Updating a project

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
`configs/`, `scripts/`, `Dockerfile.base`, `VERSION` into the project's
`base/` directory (atomically swapped), updates `.base-version`, and records
a checksum to detect future manual drift.
