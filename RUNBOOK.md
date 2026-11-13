# videoflix-deploy runbook

Operating notes for the Videoflix stack. The [incident assistant](https://github.com/PhilippKlinger/vps-incident-assistant) reads the Troubleshooting section below and links its cases in incident issues.

## Deploy and rollback

`.github/workflows/deploy.yml` rolls out one image at a time: the server pulls the new digest and starts the stack with `docker compose up --wait`, then a smoke test checks from outside that `/api/health/` reports database and cache as ok, the start page serves the app and the certificate is valid. On failure the previous images are restored and the run stays red; on success a pull request pins the digest in `compose.yaml`.

**Pin pull requests:** a pull request opened with the `GITHUB_TOKEN` starts no checks. Close and reopen it once, then merge.

**Roll back by hand:** Actions → Deploy → Run workflow, choose the service and enter an earlier digest (the deploy summaries and the history of `compose.yaml` list them). One service at a time.

**Limits of a rollback:** migrations are not reverted, so an older backend image must still work with the newer schema. Recreating the worker interrupts a running conversion.

**Without the workflow:** `docker compose pull && docker compose up -d`; delete `compose.override.yaml` to go back to the digests in `compose.yaml`.

## Backup and restore

`backup/backup.sh` writes a Postgres dump every night and a media archive once a week; a systemd timer from `backup/` runs it. Dumps are kept for 14 days, the last two media archives stay.

The restore test restores the latest dump into a separate database, compares the row counts with the live database, checks that the media archive contains every file the database refers to, and drops the copy again. Live data stays untouched. `restore-test.json` records the date and result of the last run.

## Troubleshooting

Sorted by what the monitors report (Videoflix · Web-App, Videoflix · API). Commands run in `/srv/videoflix`. Proxy and certificate problems are in the runbook of [vps-edge](https://github.com/PhilippKlinger/vps-edge/blob/main/RUNBOOK.md#troubleshooting).

### Deploy rolled back

**Symptom:** a short outage during a deploy, the Deploy run is red.

**Check:** the run summary in Actions → Deploy shows the failed step (pull, start, smoke test) and whether the check after the rollback passed.

**Fix:** if the rollback check passed, the server needs nothing; fix the image in the application repository, the next published image deploys again. If it failed, continue with [Regression after deploy](#regression-after-deploy).

**Way back:** none needed, the previous images are running.

### Regression after deploy

**Symptom:** errors shortly after a green deploy (API errors, broken pages).

**Check:** `docker compose ps`, `docker compose logs --since 30m web worker frontend`; compare `docker compose images` and `/version.json` with the deploy summary.

**Fix:** [roll back by hand](#deploy-and-rollback) to the previous digest, one service at a time; mind the limits of a rollback (migrations are not reverted).

**Way back:** deploy the fixed image once it is published.

### Database or cache not ok

**Symptom:** `/api/health/` reports database or cache not ok, the API monitor is down while the web app may still load.

**Check:** `docker compose ps db redis`, `docker compose logs --tail 50 db redis`, `df -h /var/lib/docker` for a full disk.

**Fix:** `docker compose up -d db redis`, then `docker compose restart web`. Disk full → remove old images (`docker image prune`) or old backups; never delete a volume.

**Way back:** a damaged database is restored from the backup, see [Backup and restore](#backup-and-restore).

### Web crash loop

**Symptom:** the API returns 502, the web app shell still loads.

**Check:** `docker compose ps web` shows `restarting`; `docker compose logs --tail 80 web` shows the reason. Typical are a new setting of the backend without a value in `.env`, or a migration that fails at startup.

**Fix:** missing value → add it to `.env` (`.env.example` lists every variable), then `docker compose up -d web worker mail-worker`. Failing migration → roll the backend image back ([Deploy and rollback](#deploy-and-rollback)) and fix the migration in the backend.

**Way back:** deploy the fixed backend image.

### API 5xx

**Symptom:** the API returns 500 while `web` is healthy.

**Check:** `docker compose logs --since 15m web` shows the traceback. A 400 instead of a 500 points to the allowed hosts in `.env`.

**Fix:** error in the code → roll the backend image back; wrong setting → correct `.env`, then `docker compose up -d web`.

**Way back:** deploy the fixed backend image.

### App shell error

**Symptom:** the web app returns 404 or 502, the API works.

**Check:** `docker compose ps frontend`, `docker compose logs --tail 50 frontend` for an nginx error or missing files.

**Fix:** roll the frontend image back ([Deploy and rollback](#deploy-and-rollback)).

**Way back:** deploy the fixed frontend image.

### App shell stale

**Symptom:** no alert; the web app works but shows an older version.

**Check:** `/version.json` and `docker compose images frontend` against the latest deploy summary. A leftover `compose.override.yaml` keeps an old digest.

**Fix:** deploy the current digest by hand, or delete `compose.override.yaml` and run `docker compose up -d` (see *Without the workflow* above).

**Way back:** none needed.
