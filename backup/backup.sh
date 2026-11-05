#!/bin/sh
# Daily backup of the running stack: Postgres dump, plus a media archive once a week.
# Usage: backup/backup.sh [--with-media]
set -eu

cd "$(dirname "$0")/.."

BACKUP_DIR="${BACKUP_DIR:-/srv/backups/videoflix}"
KEEP_DB_DAYS="${KEEP_DB_DAYS:-14}"
KEEP_MEDIA="${KEEP_MEDIA:-2}"
MEDIA_WEEKDAY="${MEDIA_WEEKDAY:-7}"

# Group-readable, so the admin user can copy backups off the server
umask 027

stamp=$(date -u +%Y%m%dT%H%M%SZ)

# A failed run leaves only *.tmp files behind, and those never count as a backup
trap 'rm -f "$BACKUP_DIR"/*.tmp' EXIT

backup_db() {
  target="$BACKUP_DIR/db-$stamp.dump"
  docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$target.tmp"
  # Reads the table of contents only; restore-test.sh is the real proof
  docker compose exec -T db pg_restore --list < "$target.tmp" > /dev/null
  mv "$target.tmp" "$target"
  echo "Database: $target"
  # -mtime counts full days: +13 means 14 days or older
  find "$BACKUP_DIR" -name 'db-*.dump' -mtime +"$((KEEP_DB_DAYS - 1))" -delete
}

backup_media() {
  # The archive must not fill the disk the database is running on
  needed=$(docker compose exec -T web du -sk /app/media | cut -f1)
  free=$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')
  if [ "$free" -lt "$((needed * 2))" ]; then
    echo "Not enough disk space for the media archive: ${needed} KB needed, ${free} KB free." >&2
    exit 1
  fi

  target="$BACKUP_DIR/media-$stamp.tar"
  docker compose exec -T web tar -C /app/media -cf - . > "$target.tmp"
  tar -tf "$target.tmp" > /dev/null
  mv "$target.tmp" "$target"
  echo "Media: $target"

  # Names start with the UTC time, so the glob lists the oldest first
  set -- "$BACKUP_DIR"/media-*.tar
  while [ "$#" -gt "$KEEP_MEDIA" ]; do
    rm -f "$1"
    shift
  done
}

media_due() {
  [ "${1:-}" = "--with-media" ] && return 0
  [ "$(date -u +%u)" = "$MEDIA_WEEKDAY" ] && return 0
  # The first run has no archive yet
  [ -z "$(find "$BACKUP_DIR" -name 'media-*.tar' -print -quit)" ]
}

backup_db
if media_due "${1:-}"; then
  backup_media
fi
