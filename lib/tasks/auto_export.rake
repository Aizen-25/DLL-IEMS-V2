require 'zlib'
require 'date'

namespace :db do
  desc 'Export DB to JSON when configured expiry date is reached'
  task :export_on_expiry do
    # Load app helpers (create_db_export_file, read_legacy_config, write_legacy_config)
    require File.expand_path('../../app', __dir__)

    cfg = read_legacy_config
    expiry = cfg['expiry_date']
    unless expiry
      puts 'No expiry date configured; skipping export.'
      next
    end

    begin
      expiry_date = Date.parse(expiry.to_s)
    rescue => e
      puts "Invalid expiry date in config: #{e.message}";
      next
    end

    today = Date.today
    if today >= expiry_date && cfg['auto_exported_file'].to_s.strip.empty?
      ok, msg = perform_auto_export('scheduled_export')
      if ok
        puts msg
      else
        puts "Export failed: #{msg}"
      end
    else
      puts "No export needed. Today=#{today}, expiry=#{expiry_date}, exported=#{cfg['auto_exported_file']}"
    end
  end
end
