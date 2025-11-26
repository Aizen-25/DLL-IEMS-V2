#!/usr/bin/env bash
set -euo pipefail

# Install production gems only
bundle config set without 'development test'
bundle config set path 'vendor/bundle'
# Warn during build if SESSION_SECRET is missing or too short (helps catch runtime
# errors early). This does not fail the build; it only logs a warning.
if [ -z "${SESSION_SECRET:-}" ] || [ "${#SESSION_SECRET}" -lt 64 ]; then
	echo "WARNING: SESSION_SECRET is missing or has length <64. Set SESSION_SECRET to a strong secret (>=64 bytes) in the service environment to avoid runtime errors."
fi

bundle install --jobs 4 --retry 3

# Run DB migrations if a DATABASE_URL is present (Render provides this for managed DBs)
if [ -n "${DATABASE_URL:-}" ]; then
	echo "DATABASE_URL detected — running migrations"
	bundle exec rake db:migrate
else
	echo "No DATABASE_URL detected — skipping migrations"
fi
	
# If a legacy DB is provided, copy its data into the current DB after migrations
if [ -n "${LEGACY_DATABASE_URL:-}" ]; then
	echo "LEGACY_DATABASE_URL detected — running legacy -> current DB transfer"
	bundle exec rake db:transfer_from_legacy || echo "Warning: db:transfer_from_legacy failed (check logs)"
fi
