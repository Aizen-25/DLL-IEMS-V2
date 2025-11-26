require 'uri'
require 'pg'

namespace :db do
  desc "Transfer data from legacy DB (ENV['LEGACY_DATABASE_URL']) into the current DATABASE_URL. Uses INSERT ... ON CONFLICT (id) DO UPDATE for id-based upserts."
  task transfer_from_legacy: :environment do
    legacy_url = ENV['LEGACY_DATABASE_URL']
    if legacy_url.nil? || legacy_url.strip.empty?
      puts "No LEGACY_DATABASE_URL set; nothing to transfer."
      next
    end

    puts "Starting transfer from legacy DB..."

    uri = URI.parse(legacy_url)
    legacy_conn_params = {
      host: uri.host,
      port: (uri.port || 5432),
      dbname: (uri.path && uri.path.sub(%r{^/}, '')),
      user: uri.user,
      password: uri.password
    }

    legacy = PG.connect(legacy_conn_params)
    current_ar = ActiveRecord::Base.connection
    current_pg = current_ar.raw_connection

    tables = current_ar.tables - %w[schema_migrations ar_internal_metadata]

    tables.each do |table|
      puts "Processing table: #{table}"
      begin
        legacy_res = legacy.exec("SELECT * FROM #{PG::Connection.escape_identifier(table)}")
      rescue PG::Error => e
        puts "  Skipping table #{table}: #{e.message}"
        next
      end

      next if legacy_res.ntuples == 0

      cols = legacy_res.fields
      pk = cols.include?('id') ? 'id' : nil

      cols_quoted = cols.map { |c| current_ar.quote_column_name(c) }
      cols_list_sql = cols_quoted.join(', ')

      legacy_res.each do |row|
        values = cols.map { |c| row[c] }

        placeholders = (1..values.size).map { |i| "$#{i}" }.join(', ')

        if pk
          update_assigns = cols.reject { |c| c == pk }.map { |c| "#{current_ar.quote_column_name(c)} = EXCLUDED.#{current_ar.quote_column_name(c)}" }.join(', ')
          conflict_sql = "ON CONFLICT (#{current_ar.quote_column_name(pk)}) DO UPDATE SET #{update_assigns}"
        else
          conflict_sql = ''
        end

        insert_sql = "INSERT INTO #{current_ar.quote_table_name(table)} (#{cols_list_sql}) VALUES (#{placeholders}) #{conflict_sql}"

        begin
          # Use the low-level PG connection for parameterized execution
          current_pg.exec_params(insert_sql, values)
        rescue => e
          puts "  Failed to insert into #{table}: #{e.message}"
        end
      end
    end

    legacy.close
    puts "Legacy data transfer complete."
  end
end
