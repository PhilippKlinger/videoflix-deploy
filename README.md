# videoflix-deploy

Deployment configuration for [Videoflix](https://github.com/PhilippKlinger/videoflix-backend): the single place that defines which image versions run in production.

[![CI](https://github.com/PhilippKlinger/videoflix-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/PhilippKlinger/videoflix-deploy/actions/workflows/ci.yml)
[![Security Checks](https://github.com/PhilippKlinger/videoflix-deploy/actions/workflows/security.yml/badge.svg)](https://github.com/PhilippKlinger/videoflix-deploy/actions/workflows/security.yml)
[![CodeQL](https://github.com/PhilippKlinger/videoflix-deploy/actions/workflows/codeql.yml/badge.svg)](https://github.com/PhilippKlinger/videoflix-deploy/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/PhilippKlinger/videoflix-deploy/badge)](https://scorecard.dev/viewer/?uri=github.com/PhilippKlinger/videoflix-deploy)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Overview

- Pins the backend and frontend images by digest, so one commit equals one running combination
- Deploys one image at a time with a smoke test from outside and an automatic rollback
- Hardened Compose stack: no published ports, separated networks, non-root containers, dropped capabilities, healthchecks
- Nightly database backup with a restore test; `restore-test.json` records the last result
- Logs go to journald with a time limit of 14 days

## Architecture

```mermaid
flowchart LR
    browser([Browser]) -->|HTTPS| caddy["Caddy<br/>(vps-edge)"]
    caddy -- "app shell" --> frontend["frontend<br/>nginx, Angular"]
    caddy -- "/api, /admin" --> web["web<br/>Django API"]
    subgraph internal [network internal, no route outside]
        db[(Postgres)]
        redis[(Redis)]
        worker["worker<br/>RQ, ffmpeg"]
        mail["mail-worker<br/>RQ"]
    end
    web --> db
    web -- jobs --> redis
    redis --> worker
    redis --> mail
    worker --> db
    mail -- SMTP --> smtp([Mail provider])
```

Caddy reaches `frontend` and `web` over the shared network `edge`; only `mail-worker` has a route outside.

## Tech stack

- Docker Compose with images pinned by digest
- PostgreSQL 18, Redis 8
- GitHub Actions for deploy, smoke test and rollback
- Shell scripts and a systemd timer for backup and restore test

## CI and security

- **Validate compose, scripts and workflows:** compose validation with the complete `.env.example`, shellcheck, actionlint
- **Start pinned stack and check security properties:** health, app shell, no published ports, separated networks, non-root containers
- **Scan pinned images (Trivy):** every pinned image, also weekly for vulnerabilities published later
- **Security checks:** secret scan (gitleaks), workflow lint (zizmor), CodeQL for the workflows

All checks are required before a merge, pin pull requests included. Deploy, rollback, backup and troubleshooting: [RUNBOOK.md](RUNBOOK.md).

## Related repositories

| Repository | Role |
|---|---|
| [videoflix-backend](https://github.com/PhilippKlinger/videoflix-backend) | Builds and publishes the backend image (`web`, `worker`, `mail-worker`, `demo-cleanup`) |
| [videoflix-frontend](https://github.com/PhilippKlinger/videoflix-frontend) | Builds and publishes the frontend image (nginx) |
| [vps-edge](https://github.com/PhilippKlinger/vps-edge) | Caddy with TLS in front of the stack, network `edge` |
| [vps-monitoring](https://github.com/PhilippKlinger/vps-monitoring) | Uptime Kuma checks the web app and the API |
| [vps-incident-assistant](https://github.com/PhilippKlinger/vps-incident-assistant) | Turns alerts into issues and uses RUNBOOK.md as runbook |
| [v-server-setup](https://github.com/PhilippKlinger/v-server-setup) | How the server is set up and hardened |

## License

[MIT](LICENSE)
