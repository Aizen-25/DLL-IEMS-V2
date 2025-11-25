namespace :db do
  desc "Normalize EquipmentHistory.details to JSON. Dry-run by default. Set APPLY=true to modify rows. Backups written to tmp/history_normalize_backup.jsonl"
  task :normalize_history => :environment do
    require 'json'
    FileUtils.mkdir_p('tmp')
    apply = ENV['APPLY'] == 'true'
    backup_path = 'tmp/history_normalize_backup.jsonl'
    failed_path = 'tmp/history_normalize_failed.log'

    puts "Normalize EquipmentHistory.details -> JSON (APPLY=#{apply})"
    changed = 0
    failed = 0

    File.open(backup_path, (apply ? 'a' : 'w')) do |backup_file|
      File.open(failed_path, (apply ? 'a' : 'w')) do |failed_file|
        EquipmentHistory.find_each do |h|
          next if h.details.nil? || h.details.to_s.strip.empty?
          dstr = h.details.to_s
          begin
            JSON.parse(dstr)
            # already valid JSON
            next
          rescue JSON::ParserError
            # not valid JSON, attempt heuristic conversion
          end

          candidate = dstr.dup
          # Heuristic transformations from Ruby-like hashes to JSON-ish strings
          # 1) Convert Ruby symbol keys like :key => to "key":
          candidate.gsub!(/:([a-zA-Z0-9_]+)\s*=>/, '"\1":')
          # 2) Convert hashrocket => to : (if any left), then ensure keys quoted
          candidate.gsub!('=>', ':')
          # 3) Convert single-quoted strings to double quotes
          candidate.gsub!(/'([^']*)'/, '"\1"')
          # 4) Add quotes around bare keys like { key: to {"key":
          candidate.gsub!(/([\{,\s])(\w+)\s*:/, '\1"\2":')

          # Try parse
          begin
            parsed = JSON.parse(candidate)
            puts "Candidate parsed for history id=#{h.id}"
            if apply
              # Backup original
              backup_file.puts({ id: h.id, original: dstr }.to_json)
              h.update_column(:details, parsed.to_json)
              changed += 1
            else
              puts "Would update id=#{h.id} -> #{parsed.to_json}"
              changed += 1
            end
          rescue JSON::ParserError => e
            failed_file.puts({ id: h.id, details: dstr, error: e.message }.to_json)
            failed += 1
            next
          end
        end
      end
    end

    puts "Dry-run results: candidates=#{changed}, failed=#{failed}."
    puts "Backup: #{backup_path}  Failures: #{failed_path}" unless apply
    puts "Normalization complete (APPLY=#{apply}). Modified: #{changed}, failed: #{failed}." if apply
  end
end
