# videoflix-deploy

Deployment configuration for [Videoflix](https://github.com/PhilippKlinger/videoflix-backend): the single place that defines which image versions run in production.

The application repositories ([backend](https://github.com/PhilippKlinger/videoflix-backend), [frontend](https://github.com/PhilippKlinger/videoflix-frontend)) only build and push images to GHCR. This repository pins those images by digest and rolls them out to the VPS, so one commit equals one running combination.

## Contents

- `compose.yaml`: `web` (Gunicorn) and `worker` (RQ, ffmpeg) from the backend image, `demo-cleanup` (expired demo accounts every 10 minutes), `frontend` (nginx), Postgres 18 and Redis 8; all images pinned by digest, healthchecks, `depends_on` with conditions, dropped capabilities
- Networks: `internal` (no route outside, database and Redis) and the shared `edge` network of [vps-edge](https://github.com/PhilippKlinger/vps-edge) with the aliases `videoflix-web` and `videoflix-frontend`; no service publishes ports
- `.env.example`: every variable with purpose and whether it is required

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

## Update and rollback

Change the image digests in `compose.yaml`, commit, then on the server `git pull && docker compose pull && docker compose up -d`. Rollback: check out the previous commit and run the same commands.

## Planned

- Deploy workflow (GitHub Environment `production`) with smoke test
- Backup and restore of the database and the media catalog, runbook
