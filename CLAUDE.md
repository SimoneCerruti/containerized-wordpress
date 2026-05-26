# CLAUDE.md — containerized-wordpress

This file gives Claude Code the context to work on the `containerized-wordpress` repository.

## Repository purpose

`containerized-wordpress` is a **reusable, versioned Docker base** for WordPress sites.
It encodes a hardened WordPress + Nginx + PHP-FPM + cron + supervisor stack,
tuned for production deployments behind Traefik on Hetzner VPS hosts.

The base is consumed by multiple per-project repositories (one per WordPress site).
Each project pins a specific base version and adds its own customizations through
a strict override mechanism — **the base/ directory in projects is never edited by
hand**, only swapped wholesale when the version is bumped.

## Architecture (3 components)

### 1. This repo (`containerized-wordpress`)
The reusable base, published on GitHub. Each release is a Git tag (`vX.Y.Z`)
which GitHub auto-generates as a downloadable tarball. The `release.yml`
workflow creates the GitHub Release on tag push.

```
containerized-wordpress/
├── VERSION                       # single line, MUST match the git tag (without 'v')
├── Dockerfile.base               # builds the image, uses BUILD_ROOT arg
├── compose.base.yml              # versioned compose snippet — projects `include:` it
├── compose.example.yml           # reference per-project docker-compose.yml (NOT shipped to base/)
├── .env.example                  # template for compose-level vars
├── .env.wordpress.example        # template for runtime container env
├── configs/                      # default configs baked into the image
│   ├── nginx.conf                # full server block
│   ├── php.ini                   # production php.ini
│   ├── php-fpm-www.conf
│   ├── supervisord.conf
│   ├── crontab                   # system + cloudflare only (no per-project jobs)
│   ├── *-supervisor.conf         # supervisor programs for nginx/php-fpm/cron
│   ├── logrotate
│   └── wp-malware-scan-excludes.txt
├── scripts/
│   ├── entrypoint.sh             # generates wp-config + applies overrides + supervisord
│   ├── apply-overrides.sh        # ⭐ core mechanism — copies overrides into drop-in dirs
│   ├── healthcheck.sh
│   ├── cloudflare-ips.sh
│   ├── wp-cron.sh
│   └── wp-malware-scan.sh
├── overrides/
│   └── .gitkeep                  # empty: needed so standalone builds COPY succeeds
├── .dockerignore                 # keeps standalone build context minimal; excludes docs + wpbase handoff files
├── .githooks/pre-push            # local guard: VERSION must match pushed vX.Y.Z tag (opt-in via core.hooksPath)
├── .github/workflows/release.yml
├── SCRIPTS.md                    # what each script does + env vars it consumes
├── CHANGELOG.md                  # versioning policy + per-release entries
└── README.md
```

> **Local-only handoff docs (gitignored, NOT committed/published):**
> `REPO-MAP.md` (tarball layout + `base/` extraction contract) and
> `WPBASE-CLI-CHANGES.md` (brief on what the wpbase-cli repo must update) are
> generated in the working tree to hand off to whoever maintains `wpbase-cli`.
> They are listed in `.gitignore`, so they never enter the repo or the release
> tarball — don't add committed links to them.

### 2. Per-project repos (one per site, NOT in this repo)
A project consumes the base by extracting a tarball into its `base/` subdir:

```
my-project/
├── .base-version            # pinned base version
├── docker-compose.yml       # uses base/Dockerfile.base with BUILD_ROOT=base
├── .env / .env.wordpress    # secrets, not committed
├── base/                    # ⭐ snapshot of containerized-wordpress @ pinned version
│   ├── Dockerfile.base      # copied verbatim from the release tarball
│   ├── compose.base.yml     # versioned compose snippet, `include:`d by docker-compose.yml
│   ├── configs/
│   ├── scripts/
│   ├── overrides/.gitkeep
│   ├── VERSION
│   └── .checksum            # wpbase-managed, for drift detection
└── overrides/               # ⭐ ALL per-project customization lives here
    ├── configs/
    │   ├── nginx.d/         # *.conf → /etc/nginx/conf.d/ (http {} level)
    │   ├── server.d/        # *.conf → /etc/nginx/server.d/ (server {} level)
    │   ├── php.ini.d/       # *.ini → /usr/local/etc/php/conf.d/
    │   ├── crontab.d/       # * → /etc/cron.d/
    │   └── supervisor.d/    # *.conf → /etc/supervisor/conf.d/
    └── scripts/
        ├── *.sh             # → /usr/local/bin/
        └── post-entrypoint.sh   # optional boot hook
```

The project's `docker-compose.yml` builds with:
```yaml
build:
  context: .
  dockerfile: base/Dockerfile.base
  args:
    BUILD_ROOT: base
```

### 3. `wpbase` CLI (host-side, not in this repo)
A pure-bash script installed on each Hetzner VPS at `/usr/local/bin/wpbase`.
It downloads release tarballs from GitHub via `curl` (no git on host!),
extracts them into project `base/` dirs, and optionally rebuilds containers.

Configuration on the host:
- `/etc/wpbase/repo` — single line, GitHub URL of this repo
- `/etc/wpbase/projects.list` — one project absolute path per line

Commands:
```bash
wpbase list                       # show all registered projects + their versions
wpbase versions                   # available base versions from GitHub
wpbase install <ver> <path>       # bootstrap base into a new project
wpbase update <path> --build      # update one project, rebuild, restart
wpbase update-all                 # dry-run by default; --yes --build to apply
wpbase diff <path>                # show drift if project base/ was edited manually
```

## The override mechanism — how customization actually works

When the project image is built, the project's `overrides/` directory is COPIED
into `/opt/overrides/` inside the image (handled by the last COPY in
`Dockerfile.base`).

At container boot, `entrypoint.sh` calls `apply-overrides.sh`, which copies
files from `/opt/overrides/` into the appropriate **drop-in directories**:

| Source under `/opt/overrides/`     | Destination                       | Reload mechanism                   |
| ---------------------------------- | --------------------------------- | ---------------------------------- |
| `configs/nginx.d/*.conf`           | `/etc/nginx/conf.d/`              | included by nginx.conf at http {}  |
| `configs/server.d/*.conf`          | `/etc/nginx/server.d/`           | included at END of the server {} block |
| `configs/php.ini.d/*.ini`          | `/usr/local/etc/php/conf.d/`      | auto-loaded by php-fpm at startup  |
| `configs/crontab.d/*`              | `/etc/cron.d/` (chmod 0644)       | cron scans the dir continuously    |
| `configs/supervisor.d/*.conf`      | `/etc/supervisor/conf.d/`         | included by supervisord.conf       |
| `scripts/*.sh`                     | `/usr/local/bin/` (chmod +x)      | available to cron and entrypoint   |
| `scripts/post-entrypoint.sh`       | runs at end of `apply-overrides`  | project-specific boot hook         |

**Key design point: no custom merging logic.** Each subsystem natively supports
drop-in directories, so override is just file copy. This is intentional —
keeps the mechanism dead simple and easy to debug.

## Known limitations / gotchas

1. **Nginx scopes: two slots, with a residual limit.** `nginx.d/*.conf` lives
   at `http {}` scope; `server.d/*.conf` is included at the **end of the
   `server {}` block** (in `configs/nginx.conf`). `server.d` is for **adding**
   new `location` blocks and server-level directives. It **cannot**:
   - redefine a directive already set once in the base server block — nginx
     errors on duplicates (e.g. `client_max_body_size`);
   - redefine an existing `location`; or
   - pre-empt a base regex `location` (server.d is loaded last, so base regex
     rules win for overlapping matches — by design, so base security rules
     can't be shadowed).
   To change a base server-level directive you still need a full `nginx.conf`
   replacement (a different mechanism — not yet implemented).

2. **`crontab` in base is system-only.** Per-project jobs (wp-cron loopback,
   wp-malware-scan) live in `overrides/configs/crontab.d/` because they're
   project-specific in scope. The base only has Debian periodic + Cloudflare
   refresh + heartbeat.

3. **`docker-compose.yml` is per-project; `compose.base.yml` is versioned.**
   The project's `docker-compose.yml` lives at the project root and is
   NOT managed by `wpbase`. It uses `include:` to pull in
   `base/compose.base.yml` (shipped via the release tarball), which
   defines the standard wp service shape (build args, healthcheck,
   named volumes, env_file). Per-project bits (container name, Traefik
   labels, networks, db service) live in the project's compose.
   `compose.example.yml` at this repo root is a starter template that
   users copy on first setup. Requires Compose v2.24+ for the
   `project_directory:` parameter in `include:`.

4. **GitHub anonymous API rate limit: 60 req/h.** `wpbase` uses curl against
   `api.github.com`. Fine for normal use. For high-volume update orchestration,
   we'd add token support via `/etc/wpbase/github-token`.

5. **`.checksum` drift detection is warn-only**, not blocking. Manual edits to
   `base/` in a project are detected and warned about, but `wpbase update`
   will still overwrite them.

6. **BUILD_ROOT mechanism.** `Dockerfile.base` uses an ARG `BUILD_ROOT` (default
   `.`) so it works in two modes:
   - **Standalone** (from this repo): `docker build -f Dockerfile.base .` →
     reads from `./configs`, `./scripts`. The empty `overrides/.gitkeep` makes
     the final `COPY overrides /opt/overrides` succeed.
   - **From a project**: `docker build -f base/Dockerfile.base --build-arg BUILD_ROOT=base .` →
     reads from `./base/configs`, `./base/scripts`. The final
     `COPY overrides /opt/overrides` picks up the PROJECT's `overrides/`
     because the build context is the project root.

## Release workflow

To cut a new version:

```bash
# 1. Update VERSION
echo "1.1.0" > VERSION

# 2. Update CHANGELOG.md with changes

# 3. Commit and tag
git add VERSION CHANGELOG.md
git commit -m "Release v1.1.0"
git tag v1.1.0
git push origin main --tags
```

GitHub Actions (`.github/workflows/release.yml`) will:
1. Verify `VERSION` matches the tag
2. Create a GitHub Release with auto-generated notes
3. The release page exposes the auto-generated tarball at
   `https://github.com/<owner>/<repo>/archive/refs/tags/v1.1.0.tar.gz`

`wpbase` on host downloads from that exact URL.

## Coding conventions (project-wide)

- **Bash scripts**: `set -uo pipefail` at top (or `-Eeuo pipefail` where strict
  needed). Log to `/var/log/wp_app/*.log` from within containers. Use
  `[$(date -Iseconds)]` prefix on log lines.
- **English everywhere — no exceptions.** Code, comments, identifiers, commit
  messages, docs, AND all runtime/user-facing output (log lines, the malware
  scan report email, any admin-facing strings). The malware scan report was
  previously Italian; it is now English like everything else.
- **No new dependencies on the host.** The whole `wpbase` CLI is bash + curl
  + tar. Do not add Python, jq, or anything else without explicit approval.
- **Drop-in dirs over file overwrites.** When adding customization points,
  always prefer adding a new drop-in directory and a new mapping in
  `apply-overrides.sh` over allowing files to overwrite base configs.

## Testing locally

To build the base image standalone (smoke test):
```bash
docker build -f Dockerfile.base -t wp-base:test .
docker run --rm wp-base:test cat /opt/overrides/.gitkeep
```

To test from a project layout:
```bash
mkdir /tmp/test-project && cd /tmp/test-project
mkdir -p base overrides/configs/php.ini.d
cp -r ~/containerized-wordpress/{configs,scripts,Dockerfile.base,compose.base.yml,VERSION,overrides} base/
echo "memory_limit = 1G" > overrides/configs/php.ini.d/10-test.ini
docker build -f base/Dockerfile.base --build-arg BUILD_ROOT=base -t wp-test .
docker run --rm wp-test ls /opt/overrides/configs/php.ini.d/
# Should show: 10-test.ini
```

## Roadmap / open items

- [x] nginx server-level override mechanism — `overrides/configs/server.d/`
      included at the end of the `server {}` block (see gotcha #1 for the
      residual limit on redefining existing directives)
- [x] `compose.base.yml` + per-project `include:` (Compose v2.24+)
- [x] `.env.example` and `.env.wordpress.example` templates
- [x] Per-script documentation in `SCRIPTS.md`
- [x] CHANGELOG versioning policy and upgrade procedure
- [x] `wpbase` extraction list must learn about `compose.base.yml`
      — brief delivered in the local-only `WPBASE-CLI-CHANGES.md` (R1) with the
      tarball-layout reference in the local-only `REPO-MAP.md` (both gitignored,
      see the handoff-docs note above). The actual code change lives in the
      wpbase-cli repo (external).
- [ ] Optional: GitHub token support in `wpbase` for rate-limit safety
      (documented as O4 in the local-only `WPBASE-CLI-CHANGES.md`; external,
      not yet done)
- [x] pre-receive hook or CI check to enforce VERSION == tag locally
      — `.githooks/pre-push` (opt-in via `git config core.hooksPath .githooks`);
      CI already enforces it in `release.yml`
- [x] Rename malware scan specific env vars to be all prefixed with `MALWARE_SCAN_`

## Files NOT in this repo (but related)

These live in separate repos but are part of the system:
- `wpbase` CLI script — host-side tool (see the dedicated bundle)
- Project templates and per-site repos — each site has its own repo

When working on `wpbase` or projects, this CLAUDE.md is the source of truth
for how the three pieces interact.

# CLAUDE.md (wpbase-cli)
You can access the repo via the additionalDirectories setting.
Write context that must be shared in @../wpbase_cli/SHARED_CONTEXT.md