# IT Equipment Inventory (Sinatra)

Simple IT Equipment inventory management app built with Sinatra + ActiveRecord + SQLite.

Prerequisites
- Ruby (3.0+)
- Bundler (`gem install bundler`)

Setup (PowerShell)
```powershell
cd "d:\Master of Information Technology\WITM\Demo\Inventory management"
bundle install
# migrate and seed DB
bundle exec rake db:migrate
bundle exec rake db:seed
# run the app
bundle exec rackup -p 4567
```

Then open http://localhost:4567 in your browser.

API endpoints
- `GET /api/equipments` - list JSON
- `GET /api/equipments/:id` - single equipment JSON

Next steps
- Add authentication
- Add pagination and search
- Add export (CSV) and import features

## LEGACY Database Migration (LEGACY_DATABASE_URL)

This repo includes a helper Rake task and a build-time hook to copy data from an expiring/legacy Postgres database into the active `DATABASE_URL` database.

- Purpose: allow you to bring data from an old DB into a newly provisioned DB automatically during deploy or manually when needed.
- How it works: when `LEGACY_DATABASE_URL` is set in the environment, the build script runs `rake db:transfer_from_legacy` after migrations. The task reads rows from the legacy DB and upserts into the current DB using `INSERT ... ON CONFLICT (id) DO UPDATE` for any table that contains an `id` column.

Usage (Render - recommended automated path):

1. In the Render Dashboard for the Web Service, add the following Environment Variables:
	 - `DATABASE_URL` — connection string for the new/active Postgres database (Render managed or external).
	 - `LEGACY_DATABASE_URL` — connection string for the expiring/legacy Postgres database.
	 - `SESSION_SECRET` — a secure secret at least 64 bytes long.
2. Click **Save, rebuild and deploy**. During build the script will run migrations then copy rows from the legacy DB into the current DB.

Manual usage (PowerShell):

```powershell
Set-Location -Path "D:\Master of Information Technology\WITM\Demo\Inventory management"
# $env:DATABASE_URL = "postgresql://user:pass@host:port/dbname"
# $env:LEGACY_DATABASE_URL = "postgresql://user:pass@host:port/legacy_db"
bundle exec rake db:migrate
bundle exec rake db:transfer_from_legacy
```

Safety notes & caveats
- Backup first: take a dump of both databases before transferring. You can use the provided wrapper rake tasks or `pg_dump`:
	- `bundle exec rake db:dump_pg OUT=tmp/backup.dump` (requires `pg_dump` available in PATH)
- Upsert behaviour: the transfer task assumes a primary key column named `id` and uses it as the conflict target. If your tables use different primary keys or composite keys, the task will not deduplicate correctly — consider customizing the task or using `pg_dump`/`pg_restore` instead.
- Performance: the task inserts rows one-by-one which may be slow for large tables. For large datasets prefer `pg_dump` + `pg_restore` or use `COPY`/bulk import methods.
- Permissions: ensure the DB user in `DATABASE_URL` has `INSERT` and `UPDATE` privileges on the destination tables.
- Inspect logs: the rake task prints progress and any per-row failures. Check Render deploy logs or run locally for diagnostics.

If you want help customizing the transfer behaviour (batching, different conflict keys, skipping tables), tell me which tables or keys you need and I can update the task.
