# videoflix-deploy

Deployment configuration for [Videoflix](https://github.com/PhilippKlinger/videoflix-backend): the single place that defines which image versions run in production.

The application repositories ([backend](https://github.com/PhilippKlinger/videoflix-backend), [frontend](https://github.com/PhilippKlinger/videoflix-frontend)) only build and push images to GHCR. This repository pins those images by digest and rolls them out to the VPS, so one commit equals one running combination.

## Contents

- `compose.yaml`: `web` (Gunicorn) and `worker` (RQ, ffmpeg) from the backend image, `demo-cleanup` (expired demo accounts every 10 minutes), `frontend` (nginx), Postgres 18 and Redis 8; all images pinned by digest, healthchecks, `depends_on` with conditions, dropped capabilities
- Networks: `internal` (no route outside, database and Redis) and the shared `edge` network of [vps-edge](https://github.com/PhilippKlinger/vps-edge) with the aliases `videoflix-web` and `videoflix-frontend`; no service publishes ports
- `.env.example`: every variable with purpose and whether it is required
- `.github/workflows/deploy.yml`, `scripts/`: deploy with smoke test and automatic rollback

TLS and routing are handled by [vps-edge](https://github.com/PhilippKlinger/vps-edge).

## First start on the server

```bash
cd /srv/videoflix
cp .env.example .env && chmod 600 .env    # fill in the required values
docker compose pull
docker compose up -d
docker compose ps                          # web healthy, frontend healthy
docker compose exec web python manage.py createsuperuser
```

Sample catalog (folder with .mp4 files copied to `/srv/videoflix/import`):

```bash
docker compose cp import/. web:/tmp/import
docker compose exec web python manage.py import_catalog /tmp/import
# Containers drop all capabilities, so not even root may delete the copy;
# recreating web discards it (the imported videos live in the media volume)
docker compose up -d --force-recreate web
docker compose logs -f worker              # conversions run one after another
```

## Deploy and rollback

`.github/workflows/deploy.yml` rolls out one image at a time, in the GitHub Environment `production`:

1. Trigger: `repository_dispatch` of type `image-published` from the backend or frontend CI (`{service, digest}`), or started by hand with `workflow_dispatch`
2. `scripts/deploy.sh` runs on the server over SSH: it remembers the running images and commit, pulls this repository, writes the digest to the gitignored `compose.override.yaml` and starts the stack with `docker compose up --wait`
3. `scripts/smoke-test.sh` checks from the runner, the way a visitor comes in: `/api/health/` reports database and cache as ok, the start page serves the app, the certificate is valid for at least 7 more days
4. On failure the previous images and commit are restored and checked again; the run stays red
5. On success a pull request pins the digest in `compose.yaml`; merging it records the state and does not deploy again

Secrets of the Environment: `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`. The server keeps its own `.env`.

**Roll back by hand:** Actions → Deploy → Run workflow, choose the service and enter an earlier digest (the deploy summaries and the history of `compose.yaml` list them). Run this for one service at a time.

**Limits of a rollback:** the backend applies migrations at startup and they are not reverted, so an older backend image must still work with the newer schema. Recreating the worker interrupts a running conversion.

**Without the workflow:** on the server `docker compose pull && docker compose up -d`; `compose.override.yaml` applies to manual commands as well. Delete that file to go back to the digests in `compose.yaml`.

## Planned

- Backup and restore of the database and the media catalog, runbook
