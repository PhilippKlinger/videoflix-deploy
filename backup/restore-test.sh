#!/bin/sh
# Restores a backup into a separate database and checks the result. Live data stays untouched.
# Usage: backup/restore-test.sh [db-*.dump] [media-*.tar]    (default: the newest of each)
set -eu

cd "$(dirname "$0")/.."

BACKUP_DIR="${BACKUP_DIR:-/srv/backups/videoflix}"
TEST_DB=videoflix_restore_test

newest() {
  # Names start with the UTC time, so the last match is the newest
  newest_file=""
  for file in "$BACKUP_DIR"/$1; do
    [ -e "$file" ] && newest_file="$file"
  done
  echo "$newest_file"
}

dump="${1:-$(newest 'db-*.dump')}"
media="${2:-$(newest 'media-*.tar')}"

if [ -z "$dump" ] || [ ! -f "$dump" ]; then
  echo "No database dump found in $BACKUP_DIR." >&2
  exit 1
fi

# Runs SQL from the arguments in the given database, one bare value per line
sql() {
  db="$1"
  shift
  printf '%s\n' "$*" | docker compose exec -T db sh -c \
    'psql -U "$POSTGRES_USER" -d "$0" -v ON_ERROR_STOP=1 -At' "$db"
}

live_db=$(docker compose exec -T db printenv POSTGRES_DB)

# The copy contains personal data: never leave it behind
work=$(mktemp -d)
drop_test_db() {
  sql postgres "DROP DATABASE IF EXISTS $TEST_DB;" > /dev/null || true
  rm -rf "$work"
}
trap drop_test_db EXIT

echo "Restoring $dump into $TEST_DB"
sql postgres "DROP DATABASE IF EXISTS $TEST_DB;" > /dev/null
sql postgres "CREATE DATABASE $TEST_DB;" > /dev/null
docker compose exec -T db sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$0" --no-owner --exit-on-error' "$TEST_DB" < "$dump"

failed=0

echo "Table: restored / live"
for table in accounts_app_customuser video_app_video video_app_videoresolution; do
  restored_rows=$(sql "$TEST_DB" "SELECT count(*) FROM $table;")
  live_rows=$(sql "$live_db" "SELECT count(*) FROM $table;")
  echo "  $table: $restored_rows / $live_rows"
  if [ "$restored_rows" -eq 0 ]; then
    echo "  FAILED: $table is empty" >&2
    failed=1
  fi
done

ready=$(sql "$TEST_DB" "SELECT count(*) FROM video_app_video WHERE status = 'ready';")
echo "Videos with status ready: $ready"
if [ "$ready" -eq 0 ]; then
  echo "FAILED: no video is ready" >&2
  failed=1
fi

if [ -z "$media" ] || [ ! -f "$media" ]; then
  echo "FAILED: no media archive found, files were not checked" >&2
  failed=1
else
  echo "Checking the files the database refers to against $media"
  # Paths in the archive start with ./, paths in the database do not
  tar -tf "$media" > "$work/listing"
  sed 's#^\./##' "$work/listing" | sort -u > "$work/archive"
  sql "$TEST_DB" "SELECT thumbnail_url FROM video_app_video WHERE thumbnail_url <> ''
    UNION SELECT converted_file FROM video_app_videoresolution WHERE converted_file <> '';" > "$work/rows"
  sort -u "$work/rows" > "$work/expected"
  comm -23 "$work/expected" "$work/archive" > "$work/missing"
  expected_files=$(wc -l < "$work/expected")
  missing_files=$(wc -l < "$work/missing")
  echo "Files: $expected_files expected, $missing_files missing"
  if [ "$expected_files" -eq 0 ]; then
    echo "FAILED: the database refers to no files" >&2
    failed=1
  fi
  if [ "$missing_files" -gt 0 ]; then
    echo "FAILED: files missing from the archive, for example:" >&2
    head -n 5 "$work/missing" >&2
    failed=1
  fi
fi

if [ "$failed" -ne 0 ]; then
  echo "Restore test FAILED." >&2
  exit 1
fi
echo "Restore test passed."
