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
      fname = create_db_export_file('scheduled_export')
      src = File.join(LEGACY_EXPORT_DIR, fname)
      gz_path = "#{src}.gz"

      # Attempt to upload the raw JSON to GitHub backup repo if configured
      if ENV['GITHUB_TOKEN'] && ENV['GITHUB_REPO']
        begin
          ok, msg = upload_file_to_github_repo(src)
          if ok
            cfg['uploaded_to_repo'] = ENV['GITHUB_REPO']
            cfg['uploaded_at'] = Time.now.utc.iso8601
            cfg['uploaded_file'] = File.basename(src)
            write_legacy_config(cfg)
            puts "Uploaded backup to #{ENV['GITHUB_REPO']}: #{msg}"
          else
            puts "Failed to upload backup: #{msg}"
          end
        rescue => e
          puts "Upload attempt failed: #{e.message}"
        end
      end

      begin
        Zlib::GzipWriter.open(gz_path) do |gzio|
          gzio.write(File.read(src))
        end
      rescue => e
        puts "Failed to gzip export: #{e.message}"
      end

      cfg['auto_exported_file'] = File.basename(src)
      cfg['auto_exported_at'] = Time.now.utc.iso8601
      write_legacy_config(cfg)
      puts "Exported DB to #{src} (gzipped to #{gz_path}) and recorded in config."
      # Attempt to upload to GitHub repo if configured
      if ENV['GITHUB_TOKEN'] && ENV['GITHUB_REPO']
        begin
          ok, msg = upload_file_to_github_repo(gz_path)
          if ok
            cfg = read_legacy_config
            cfg['uploaded_to_repo'] = ENV['GITHUB_REPO']
            cfg['uploaded_at'] = Time.now.utc.iso8601
            write_legacy_config(cfg)
            puts "Uploaded backup to #{ENV['GITHUB_REPO']}: #{msg}"
          else
            puts "Failed to upload backup: #{msg}"
          end
        rescue => e
          puts "Upload attempt failed: #{e.message}"
        end
      end
    else
      puts "No export needed. Today=#{today}, expiry=#{expiry_date}, exported=#{cfg['auto_exported_file']}"
    end
  end
end
