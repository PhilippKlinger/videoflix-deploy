# videoflix-deploy

Deployment configuration for [Videoflix](https://github.com/PhilippKlinger/videoflix-backend): the single place that defines which image versions run in production.

The application repositories ([backend](https://github.com/PhilippKlinger/videoflix-backend), [frontend](https://github.com/PhilippKlinger/videoflix-frontend)) only build and push images to GHCR. This repository pins those images by digest and rolls them out to the VPS, so one commit equals one running combination.

## Planned contents

- `compose.yaml`: backend (`web`, `worker`), frontend, Postgres, Redis; images pinned by digest, healthchecks, internal network plus the shared `edge` network
- Deploy workflow (GitHub Environment `production`): pull, `up --no-build`, smoke test
- Backup and restore of the database and the public media catalog
- Runbook: deploy, rollback (previous digest), restore

TLS and routing are handled by [vps-edge](https://github.com/PhilippKlinger/vps-edge).

## Status

Repository set up, contents follow.
