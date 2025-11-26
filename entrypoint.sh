#!/usr/bin/env bash
set -euo pipefail

# Defaults
DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-5432}

# Wait for Postgres only if a DATABASE_URL is provided or DB_HOST looks reachable
if [ -n "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL detected — waiting for Postgres at ${DB_HOST}:${DB_PORT}..."
  for i in $(seq 1 60); do
    (echo > /dev/tcp/${DB_HOST}/${DB_PORT}) >/dev/null 2>&1 && break
    echo "Postgres not available yet (${i})..."
    sleep 1
  done

  echo "Running DB migrations"
  bundle exec rake db:migrate
else
  echo "No DATABASE_URL — skipping DB wait and migrations"
fi

echo "Starting app on 0.0.0.0:${PORT:-4567}"
exec bundle exec rackup -o 0.0.0.0 -p ${PORT:-4567}
