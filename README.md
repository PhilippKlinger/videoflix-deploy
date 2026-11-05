# videoflix-deploy

Deployment configuration for [Videoflix](https://github.com/PhilippKlinger/videoflix-backend): the single place that defines which image versions run in production.

The application repositories ([backend](https://github.com/PhilippKlinger/videoflix-backend), [frontend](https://github.com/PhilippKlinger/videoflix-frontend)) only build and push images to GHCR. This repository pins those images by digest and rolls them out to the VPS, so one commit equals one running combination.

## Contents

- `compose.yaml`: `web` (Gunicorn) and `worker` (RQ, ffmpeg) from the backend image, `demo-cleanup` (expired demo accounts every 10 minutes), `frontend` (nginx), Postgres 18 and Redis 8; all images pinned by digest, healthchecks, `depends_on` with conditions, dropped capabilities
- Networks: `internal` (no route outside, database and Redis) and the shared `edge` network of [vps-edge](https://github.com/PhilippKlinger/vps-edge) with the aliases `videoflix-web` and `videoflix-frontend`; no service publishes ports
- `.env.example`: every variable with purpose and whether it is required
- `backup/`: backup and restore test scripts, systemd service and timer

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

## Logs

All services log to journald instead of `json-file`, because `json-file` can only rotate by size. The time limit of 14 days from the privacy policy is set on the host, see [vps-edge](https://github.com/PhilippKlinger/vps-edge). Reading logs stays the same: `docker compose logs`.

## Update and rollback

Change the image digests in `compose.yaml`, commit, then on the server `git pull && docker compose pull && docker compose up -d`. Rollback: check out the previous commit and run the same commands.

## Backup and restore

`backup/backup.sh` writes a Postgres dump every day and a media archive once a week (and on the first run), to `/srv/backups/videoflix`. Dumps are kept for 14 days, the last 2 media archives stay. `.env` is not part of the backup: keep its values in a password manager, a restore needs them.

**The backups stay on the VPS.** They protect against bad deployments and deleted data, not against losing the server. Copy a dump to another machine from time to time:

```bash
scp <admin>@<host>:/srv/backups/videoflix/db-<time>.dump .   # contains personal data, store it encrypted
```

Setup on the server (once, as admin user):

```bash
sudo install -d -m 2750 -o deploy -g "$USER" /srv/backups/videoflix
sudo cp /srv/videoflix/backup/videoflix-backup.service /srv/videoflix/backup/videoflix-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now videoflix-backup.timer
systemctl list-timers videoflix-backup.timer     # next run
```

Restore test: restores into the separate database `videoflix_restore_test`, compares the row counts with the live database, checks that the archive contains every file the database refers to, and drops the copy again. Live data stays untouched.

```bash
sudo -u deploy /srv/videoflix/backup/backup.sh --with-media
sudo -u deploy /srv/videoflix/backup/restore-test.sh   # ends with "Restore test passed."
```

Real restore as user deploy, `sudo -iu deploy` (overwrites the live data, the site is down meanwhile):

```bash
cd /srv/videoflix
docker compose stop web worker demo-cleanup
docker compose exec -T db sh -c 'dropdb -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
docker compose exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' < /srv/backups/videoflix/db-<time>.dump
docker compose run --rm -T --no-deps web tar -xf - -C /app/media < /srv/backups/videoflix/media-<time>.tar
docker compose up -d
docker compose ps                                # web healthy
```

## Planned

- Deploy workflow (GitHub Environment `production`) with smoke test
