# Deploying obsidian-worklog on kumadrome

The Worklog runs on kumadrome as two containers sharing one vault directory, with its own Watchtower beside them
pulling new images from GHCR:

- **sync** runs `ob sync --continuous`, keeping `data/vault` in step with your other devices through Obsidian Sync.
- **worker** runs a Run every hour and writes the Activity logs into `data/vault/log/`.
- **watchtower** rolls out each new `latest` image within 5 minutes.

Everything is outbound (Obsidian Sync, GitHub, Linear, Uptime Kuma), so there is no Tailscale sidecar and no
published port. Docker and the Compose plugin are already installed on kumadrome, and the `kuma-push` network
already exists there ([ops `kumadrome-apps.md`](https://github.com/neuroticsasquat-ch/ops/blob/main/docs/runbooks/kumadrome-apps.md)).
Besides this repository, the outside accounts involved are Obsidian Sync, GitHub, the two Linear workspaces, and
the ops Uptime Kuma.

Images are published by the `publish` job in `.github/workflows/ci.yml` on every push to `main`, once `ci` has
passed on that commit:

| Tag | Use |
|---|---|
| `latest` | what kumadrome runs |
| `sha-<7>` | pinning or rolling back to one commit |

Each step says where it runs. **kumadrome** means a shell opened with `ssh kumadrome`; **laptop** means your own
machine.

## 1. Make sure kumadrome can pull the image

Watchtower pulls anonymously and kumadrome has no registry login, so the `ghcr.io/tomboone/obsidian-worklog`
package must be public.

**Laptop:** your GitHub profile → Packages → `obsidian-worklog` → Package settings → Change visibility → Public
(skip if it already says Public).

**kumadrome:**

```sh
docker pull ghcr.io/tomboone/obsidian-worklog:latest
```

Expect `Status: Downloaded newer image for ghcr.io/tomboone/obsidian-worklog:latest` (or `Image is up to date`).
`unauthorized` or `denied` means the package is still private.

## 2. Fetch the deploy files

**kumadrome.** Only `deploy/` is needed. A sparse clone fetches that directory (plus the handful of top-level files
git always includes) without the source tree:

```sh
git clone --filter=blob:none --sparse --branch main https://github.com/tomboone/obsidian-worklog.git ~/obsidian-worklog
cd ~/obsidian-worklog
git sparse-checkout set deploy
cd deploy
mkdir -p data/vault data/config
```

Every command from here on runs in `~/obsidian-worklog/deploy/`. `git pull` picks up later changes to these files.

The containers run as `tom` (UID/GID 1000, from `PUID`/`PGID`), so the data directories must be owned by `tom`.
Creating them yourself, before any `docker compose` command, does that; left to Docker they would be created
root-owned and the containers could not write. Check:

```sh
ls -ldn data/vault data/config
```

Expect both lines to show `1000 1000`.

## 3. Configure `.env` and `config.json`

**Laptop: create the tokens.**

- **GitHub:** Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token,
  with scopes `repo`, `read:org` and `read:user`. It must be classic: a fine-grained token is scoped to one owner and
  cannot cover the orgs below. Then, on the token's row, **Configure SSO** → **Authorize** next to `ingest-ai` (only
  shown if the org enforces SAML SSO). Without that, GitHub silently leaves `ingest-ai` activity out of the work log.
- **Linear:** in each workspace (ingest, and personal), Settings → Security & access → Personal API keys → New key.

**kumadrome: write the files.**

```sh
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set `GITHUB_TOKEN_PERSONAL`, `LINEAR_API_KEY_WORK` (ingest) and `LINEAR_API_KEY_PERSONAL`. Leave
`KUMA_PUSH_URL` blank for now (step 6), and leave the other defaults (`TZ=America/New_York`, `PUID`/`PGID` 1000,
`INTERVAL_SECONDS=3600`, `DAYS_BACK=1`) alone.

Create `config.json`:

```json
{
  "logFolder": "log",
  "contexts": ["work", "hobby", "personal"],

  "github": [
    {
      "name": "personal account",
      "tokenEnv": "GITHUB_TOKEN_PERSONAL",
      "context": "hobby",
      "owners": { "ingest-ai": "work", "CCALI": "work", "neuroticsasquat-ch": "hobby" }
    }
  ],

  "linear": [
    { "name": "ingest workspace", "tokenEnv": "LINEAR_API_KEY_WORK", "context": "work", "teams": {} },
    { "name": "personal workspace", "tokenEnv": "LINEAR_API_KEY_PERSONAL", "context": "hobby", "teams": {} }
  ]
}
```

`context` is the default for each Source; `owners` (GitHub org or user) and `teams` (Linear team key) override it.
`personal` has no Source yet, so its Activity log says "_Nothing logged._" every day; it is kept as a slot for later
Sources.

Check both files:

```sh
ls -l .env                                              # expect -rw-------
python3 -m json.tool config.json > /dev/null && echo ok # expect ok
```

Check the GitHub token reaches `ingest-ai` (the token stays inside the container, out of your shell history):

```sh
docker compose run --rm --no-deps worker node -e '
fetch("https://api.github.com/orgs/ingest-ai/repos?per_page=1", {
  headers: { Authorization: `Bearer ${process.env.GITHUB_TOKEN_PERSONAL}`, "User-Agent": "obsidian-worklog" },
}).then(async (r) => console.log(r.status, r.status === 200 ? "" : await r.text()))'
```

Expect `200`. A `403` mentioning SAML means the token is not authorised for `ingest-ai`; go back to **Configure
SSO**.

## 4. Log in to Obsidian and connect the vault

**kumadrome.** Interactive, once. `ob` keeps its login and vault state in `data/config`.

```sh
docker compose run --rm sync ob login
```

Enter your Obsidian email, password and 2FA code when prompted. It returns to the shell without an error once logged in.

```sh
docker compose run --rm sync ob sync-list-remote
```

Lists your remote vaults. Note the exact name of the one the Worklog should write to.

```sh
docker compose run --rm sync ob sync-setup --vault "<vault name>" --path /vault --device-name kumadrome
```

Connects `/vault` (`data/vault` on the host) to that vault as device `kumadrome`. For an end-to-end encrypted vault
it prompts for the vault's encryption password. It returns to the shell without an error once connected.

```sh
docker compose run --rm sync ob sync-config --path /vault --configs "" --file-types ""
```

Stops this device syncing app settings and attachments, which it does not need: it only reads and writes Markdown.
It returns to the shell without an error.

## 5. Dry run

**kumadrome.** Prints the Activity logs instead of writing them, and pushes nothing to Kuma:

```sh
docker compose run --rm --no-deps -e DRY_RUN=1 worker node /app/src/run.mjs
```

Expect six blocks, two days (yesterday and today, from `DAYS_BACK=1`) × three Contexts, each starting with a line
like `--- /vault/log/2026/2026-10-28 work.md`, and nothing on stderr. A line such as
`[2026-10-28] GitHub "personal account": HTTP 401 {"message":"Bad credentials",…}` followed by
`[2026-10-28] skipped: a source failed, existing files left untouched` names the Source to fix; fix it and dry-run
again.

## 6. Create the Kuma push monitor

**Laptop**, on the tailnet: open the ops Kuma at `https://kuma.tail1afe5a.ts.net` and **Add New Monitor**:

| Setting | Value |
|---|---|
| Monitor type | Push |
| Friendly name | `kumadrome/obsidian-worklog` |
| Heartbeat interval | 10800 s (3 h) |
| Retries | 0 |
| Notification | `Discord #alerts` (on by default) |

Save. Kuma shows a push URL of the form `https://kuma.tail1afe5a.ts.net/api/push/<token>?status=up&msg=OK&ping=`.

**kumadrome:** take just the token from it and set, in `.env`:

```sh
KUMA_PUSH_URL=http://uptime-kuma:3001/api/push/<token>
```

No query string: the worker adds `status` and `msg` itself. The host name is `uptime-kuma` because the worker
reaches Kuma over the `kuma-push` network, not the tailnet.

With hourly Runs, two missed Runs in a row are tolerated and a third alerts. A Run where a Source failed pushes
`down` with the first failure and alerts at once.

## 7. Start it

**kumadrome:**

```sh
docker compose config -q   # validates the compose file and .env; prints nothing on success
docker compose up -d
docker compose ps
```

`docker compose ps` lists `sync`, `worker` and `watchtower`, each with a status of `Up`. The worker's first Run starts
straight away:

```sh
docker compose logs worker
```

Expect `[<date>] updated log/<year>/<date> <context>.md` lines, six on the first Run. Later Runs print only the files
whose content changed. In Kuma, `kumadrome/obsidian-worklog` turns green within a minute of the first Run.

## 8. Check the files reach another device

**Laptop or phone**, in Obsidian on the same vault: today's `log/<year>/<date> work.md`, `… hobby.md` and
`… personal.md` appear within a few minutes. If they don't, `docker compose logs sync` on kumadrome shows what Vault
sync is doing.

## 9. Record the monitor in ops

**Laptop**, in the ops repo: add the monitor to `docs/runbooks/uptime-kuma-monitors.md`, whose rule is that a monitor
not in that file does not exist. In the *kumadrome (host timers and containers)* table add:

```md
| `kumadrome/obsidian-worklog` | obsidian-worklog `worker` container, after every Run | hourly (`INTERVAL_SECONDS=3600`) | 3 h | `KUMA_PUSH_URL` in `~tom/obsidian-worklog/deploy/.env` |
```

and in the **Count** line below it, raise the total by one and kumadrome from 3 to 4, with the date. Open a PR for it.

## Day-to-day

Everything here runs on kumadrome, in `~/obsidian-worklog/deploy/`.

**Logs:**

```sh
docker compose logs -f worker       # Runs: updated files, Source failures, "run failed; will retry"
docker compose logs -f sync         # Vault sync
docker compose logs -f watchtower   # image updates
```

**Run now**, rather than waiting for the next hourly Run (writes files and pushes to Kuma like a scheduled Run):

```sh
docker compose exec worker node /app/src/run.mjs
```

Add `-e DRY_RUN=1` after `exec` to print instead of write.

**Updates** are automatic: Watchtower checks GHCR every 5 minutes and, when `latest` has moved, restarts `sync` and
`worker` on the new image and removes the old one. `docker compose logs watchtower` shows a
`Found new ghcr.io/tomboone/obsidian-worklog:latest image` line when that happens. It runs with
`--scope obsidian-worklog`, so it touches only this app's containers; the other apps on kumadrome each run their own
scoped Watchtower. To update by hand: `docker compose pull && docker compose up -d`.

**Roll back** by pinning a commit: change `image:` in `docker-compose.yml` to `ghcr.io/tomboone/obsidian-worklog:sha-<7>`
and run `docker compose up -d`. Watchtower keeps following that tag, which never moves, so updates stop until you
switch back. The pin is a local edit to a tracked file, so drop it with `git restore docker-compose.yml` before the
next `git pull`.

**Obsidian session expired.** If `docker compose logs sync` shows authentication errors and the Activity logs stop
reaching your devices (the worker still writes them, so Kuma stays green), log in again:

```sh
docker compose stop sync
docker compose run --rm sync ob login
docker compose start sync
```

The vault connection from `sync-setup` is kept in `data/config`, so only the login is repeated.

## Dry run without kumadrome

**Laptop**, from the repo root, after creating `deploy/.env` and `deploy/config.json`:

```sh
docker build -t obsidian-worklog:local .
docker run --rm --env-file deploy/.env -e DRY_RUN=1 \
  -v "$PWD/deploy/config.json:/app/config.json:ro" obsidian-worklog:local node /app/src/run.mjs
```
