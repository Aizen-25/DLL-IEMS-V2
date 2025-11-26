#!/usr/bin/env bash
set -euo pipefail

# Install production gems only
bundle config set without 'development test'
bundle install --jobs 4 --retry 3 --path vendor/bundle

# Run DB migrations if a DATABASE_URL is present (Render provides this for managed DBs)
if [ -n "${DATABASE_URL:-}" ]; then
	echo "DATABASE_URL detected — running migrations"
	bundle exec rake db:migrate
else
	echo "No DATABASE_URL detected — skipping migrations"
fi