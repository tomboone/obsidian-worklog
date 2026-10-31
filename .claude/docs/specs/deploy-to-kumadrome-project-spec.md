# Deploy to kumadrome — project spec

Linear: initiative **obsidian-worklog** (I-15), team NEU, project *Deploy to kumadrome*.
Vocabulary is in [CONTEXT.md](../../../CONTEXT.md) (Worklog, Context, Activity log, Source, Run, Vault sync).

## Purpose

The Worklog runs nowhere yet. This project puts it on kumadrome, the home server (2011 Mac mini, Ubuntu,
x86_64), the way the other outbound-only apps there run (nba-today, mlb-today): a prebuilt GHCR image,
an image-only Compose file in `deploy/`, a Watchtower scoped to the app that rolls out every merge to
`main`, and an Uptime Kuma push monitor that alerts Discord `#alerts` when Runs stop succeeding.

## Decisions

### 1. No Tailscale sidecar

Kumadrome's sidecars exist to serve an app's web UI on the tailnet (movie-email, closinglineup, Navidrome,
Uptime Kuma, argelander). The Worklog accepts no connections: `sync` (`ob sync --continuous`) and `worker`
(`scripts/loop.sh` → `src/run.mjs`) only make outbound calls to Obsidian Sync, GitHub and Linear, and the
image declares no `EXPOSE`. People read the Worklog in Obsidian on their own devices, through Vault sync.
Operating it (one-time `ob login`, logs) goes through `ssh kumadrome`. Revisit only if the Worklog grows
an HTTP interface.

### 2. One name: `obsidian-worklog`

The repo `tomboone/obsidian-headless-sync` is renamed to `tomboone/obsidian-worklog`, and that name is used
for the GHCR image (`ghcr.io/tomboone/obsidian-worklog`), the checkout on kumadrome (`~/obsidian-worklog`),
the Compose project (`name: obsidian-worklog`), the Watchtower scope, and the Kuma monitor
(`kumadrome/obsidian-worklog`). GitHub redirects the old repo URL; GHCR does not carry packages across a
rename, so the new package starts empty, is made **public** (Watchtower and kumadrome pull anonymously;
kumadrome has no `~/.docker/config.json`), and the `obsidian-headless-sync` package (published once, on
2026-10-28) is deleted. Names in code that are already `obsidian-worklog` (README title, GitHub
`User-Agent`) stay. The local clone's remote is updated with `git remote set-url`.

### 3. `image.yml` aligned with the sibling image workflows

`.github/workflows/image.yml` follows closinglineup's / argelander's shape:

- Trigger: `push` to `main` only (no `v*` tags, no `workflow_dispatch` needed beyond what siblings have).
- Tags: `latest` and `sha-<7>` (`docker/metadata-action` with `flavor: latest=false`,
  `type=raw,value=latest` and `type=sha,prefix=sha-,format=short`). No semver tags.
- `concurrency: { group: image-${{ github.ref }}, cancel-in-progress: false }`, so publishes run in push
  order and `latest` never regresses to an older commit (which Watchtower would then roll out).
- `docker/setup-buildx-action` plus a GHA build cache (`cache-from`/`cache-to: type=gha,mode=max`).
- Current action majors, matching closinglineup (`actions/checkout@v7`, `docker/login-action@v4`,
  `docker/metadata-action@v6`, `docker/build-push-action@v7`, `docker/setup-buildx-action@v4`).
- `platforms: linux/amd64` stays (kumadrome is x86_64).
- A `ci` job calls `.github/workflows/ci.yml` and `publish` has `needs: ci`, so tests gate every publish
  (Decision 5, NEU-2015). The siblings don't gate theirs.
- Image is `ghcr.io/tomboone/obsidian-worklog` (written out, not `${{ github.repository }}`, matching
  siblings).

### 4. `deploy/` like nba-today

`deploy/docker-compose.yml` is the only Compose file; the root `compose.yaml` is deleted. Kumadrome
sparse-clones just `deploy/` into `~/obsidian-worklog`
(`git clone --filter=blob:none --sparse … && git sparse-checkout set deploy`).

- `name: obsidian-worklog`.
- `sync` and `worker` share an anchor: `image: ghcr.io/tomboone/obsidian-worklog:latest` (no `build:`),
  `restart: unless-stopped`, `user: "${PUID:-1000}:${PGID:-1000}"` (kumadrome's `tom` is 1000:1000),
  `TZ: ${TZ:-America/New_York}`, `XDG_CONFIG_HOME: /config`, `VAULT_PATH: /vault`, and the Watchtower
  labels `com.centurylinklabs.watchtower.enable=true` and `com.centurylinklabs.watchtower.scope=obsidian-worklog`.
- `sync`: `command: ["ob", "sync", "--path", "/vault", "--continuous"]`, volumes `./data/vault:/vault` and
  `./data/config:/config`.
- `worker`: `env_file: .env`, volumes `./data/vault:/vault` and `./config.json:/app/config.json:ro`,
  `command: ["sh", "/app/scripts/loop.sh"]`, `depends_on: [sync]`, and joins the external `kuma-push`
  network (so `KUMA_PUSH_URL=http://uptime-kuma:3001/api/push/<token>` resolves with nothing published).
  Because joining a named network drops the implicit default, list `default` too.
- `watchtower`: `image: nickfedor/watchtower:1.23.2`,
  `command: ["--label-enable", "--scope", "obsidian-worklog", "--interval", "300", "--cleanup"]`,
  `/var/run/docker.sock` mounted, `restart: unless-stopped`, and the scope label itself (Watchtower's
  multiple-instance rule; argelander, closinglineup, mlb-today and nba-today each run their own scoped
  instance on kumadrome).
- `networks: kuma-push: external: true`.
- `deploy/.env.example` (moved from the root `.env.example`) defaults `TZ=America/New_York` and adds
  `KUMA_PUSH_URL=` with a comment. `deploy/config.example.json` moves from the root too. `.gitignore`
  ignores `deploy/.env`, `deploy/config.json` and `deploy/data/`. `.dockerignore` keeps excluding them.
- Rollback is nba-today's: pin `image:` to `sha-<7>`, `docker compose up -d`, `git restore` before the next
  `git pull`.

The root `README.md` keeps describing the app (Contexts, Daily note template, Behaviour, Notes) and points to
`deploy/README.md` for running it; its Setup section moves into the runbook. A local dry run without kumadrome
is `docker build -t obsidian-worklog:local . && docker run --rm --env-file deploy/.env -e DRY_RUN=1 -v
"$PWD/deploy/config.json:/app/config.json:ro" obsidian-worklog:local node /app/src/run.mjs`.

### 5. Kuma push after each Run

The worker reports each Run's outcome to an Uptime Kuma push monitor, `kumadrome/obsidian-worklog`
(type Push, **heartbeat interval 3 h**, retries 0, notification `Discord #alerts`), following ops'
`uptime-kuma-monitors.md` kumadrome section (containers push to `http://uptime-kuma:3001` over the
`kuma-push` network).

- `KUMA_PUSH_URL` is the push URL without query string (`http://uptime-kuma:3001/api/push/<token>`).
  Unset or empty → no push. `DRY_RUN=1` → no push.
- After a Run where every Source succeeded for every day: `GET <url>?status=up&msg=OK`.
- After a Run where any day was skipped because a Source failed: `GET <url>?status=down&msg=<text>`,
  `<text>` being the first failure, e.g. `2026-10-28: GitHub "personal account": HTTP 401 {"message":"Bad credentials",…}`,
  URL-encoded and truncated to 200 characters.
- A Run that crashes before finishing (bad `config.json`, unhandled error) pushes nothing; the 3 h
  interval catches it as a missed heartbeat.
- The push uses a 10 s timeout. A failed push (network, non-2xx) is logged to stderr and never changes the
  Run's outcome or exit code.
- `run.mjs` exits non-zero when any day was skipped, so `loop.sh`'s existing "run failed; will retry" line
  also fires for Source failures (today it exits 0).
- The push lives in `run.mjs` (it knows the failure text), in a small `src/push.mjs` (`pushStatus(url,
  status, msg)`) so it can be tested with a mocked `fetch`.
- With hourly Runs and a 3 h interval, two missed Runs in a row are tolerated; a third alerts. A
  `status=down` alerts at once.
- **Tests** use Node's built-in `node:test` and `node:assert`, as `*.test.mjs` under `src/`, run with
  `node --test 'src/**/*.test.mjs'` (quoted, so Node expands the glob). No `package.json`, no
  dependencies. `.github/workflows/ci.yml` runs them with a syntax check on every PR, and `image.yml` calls it
  before publishing, so a failing `main` ships no image (NEU-2015). CI builds the image and runs every check
  inside it, so the Node version lives only in the Dockerfile's `FROM` and is the one that ships
  (NEU-2016). `fetch` is mocked by replacing `globalThis.fetch` in the test. Cover: up with `msg=OK`;
  down with the encoded, truncated message; no call when the URL is unset or empty; a rejected or non-2xx `fetch` logs and
  resolves without throwing.

Vault sync is **not** monitored: `ob` has no health command, and a stalled sync shows as missing files on
the person's devices.

### 6. Timezone

Activity log days are cut at midnight in the container's `TZ` (`src/dates.mjs`). The default becomes
`America/New_York` (kumadrome's own zone and every other kumadrome schedule) in `deploy/docker-compose.yml`
and `deploy/.env.example`. Node's bundled ICU handles `TZ` without `tzdata` in the slim image.

### 7. Sources on kumadrome

`~/obsidian-worklog/deploy/config.json` on kumadrome (not in git):

- `contexts`: `["work", "hobby", "personal"]`. `personal` is kept although no Source feeds it, so a
  `YYYY-MM-DD personal.md` saying "_Nothing logged._" is written every day. Deliberate: a slot for later
  Sources.
- GitHub, one entry, `tokenEnv: GITHUB_TOKEN_PERSONAL` (a **classic** PAT with `repo`, `read:org`,
  `read:user`; a fine-grained PAT is scoped to one owner and cannot cover the orgs), `context: hobby`,
  `owners: { "ingest-ai": "work", "CCALI": "work", "neuroticsasquat-ch": "hobby" }`. If `ingest-ai`
  enforces SAML SSO, the token is authorised for it.
- Linear, two entries: the ingest workspace (`tokenEnv: LINEAR_API_KEY_WORK`, `context: work`) and the
  personal workspace (`tokenEnv: LINEAR_API_KEY_PERSONAL`, `context: hobby`), each with `teams: {}`.

### 8. No backfill

Logs start on deploy day. `DAYS_BACK=1` and `INTERVAL_SECONDS=3600` stay.

### 9. Deployment is a runbook you run

`deploy/README.md` is the runbook, in nba-today's style (each step says where it runs and what output to
expect). Claude does not run the deployment: `ob login` needs the Obsidian password and 2FA, and `.env`
holds secrets. Steps:

1. Check the image is public: `docker pull ghcr.io/tomboone/obsidian-worklog:latest` on kumadrome.
2. Sparse clone into `~/obsidian-worklog`, `cd deploy`, `mkdir -p data/vault data/config` (owned by `tom`,
   1000:1000, which the containers run as).
3. `.env` from `.env.example` (`chmod 600`): `GITHUB_TOKEN_PERSONAL`, `LINEAR_API_KEY_WORK`,
   `LINEAR_API_KEY_PERSONAL`; `KUMA_PUSH_URL` left blank for now. `config.json` per Decision 7.
4. Obsidian: `docker compose run --rm sync ob login`, `ob sync-list-remote`, `ob sync-setup --vault
   "<vault>" --path /vault --device-name kumadrome`, `ob sync-config --path /vault --configs ""
   --file-types ""`.
5. Dry run: `docker compose run --rm -e DRY_RUN=1 worker node /app/src/run.mjs`; expect two days × three
   Contexts printed, no errors.
6. Kuma: create the push monitor (Decision 5) in the ops Kuma (`https://kuma.tail1afe5a.ts.net`), put its
   URL in `.env` as `KUMA_PUSH_URL=http://uptime-kuma:3001/api/push/<token>`.
7. `docker compose config -q && docker compose up -d && docker compose ps`; three services `Up`.
   `docker compose logs worker` shows `updated log/…` lines; the monitor turns green after the first Run.
8. On another device, the day's Activity logs appear in the vault.
9. Add the monitor's row to ops `docs/runbooks/uptime-kuma-monitors.md` (kumadrome table; count 3 → 4)
   per that file's rule ("A monitor that is not in this file does not exist"). Not tracked by a ticket.

Plus day-to-day: logs, a manual Run (`docker compose exec worker node /app/src/run.mjs`), how updates
arrive (Watchtower, 5 min), rollback, and re-login if Obsidian's session expires.

## Not in scope

- A Tailscale sidecar or any published port (Decision 1).
- Monitoring Vault sync.
- Backups of `data/`: Obsidian Sync already holds the vault on other devices; `data/config` is
  recreated by `ob login`.
- Backfilling Activity logs before deploy day.
- Changes to how Sources are queried or rendered.
- A ticket in the ops repo (the monitor row is a runbook step).

## Order

Rename + image workflow first (every later piece names the image). The deploy Compose and the Kuma push
can then go in parallel; the runbook comes last, since it documents both and its manual steps are the
deployment.
