namespace :db do
  desc "Reset application data and load new seeds. Requires FORCE=true to run (destructive)."
  task :reset_and_seed => :environment do
    unless ENV['FORCE'] == 'true'
      puts "This task will DELETE ALL application data (equipments, requests, users, activities, histories)."
      puts "To proceed non-interactively, re-run with FORCE=true environment variable."
      puts "Example: FORCE=true bundle exec rake db:reset_and_seed"
      next
    end

    models = []
    begin
      model_names = %w[EquipmentHistory UserEquipment Activity Request Equipment User]
      models = model_names.map { |n| Object.const_get(n) rescue nil }.compact
    rescue => e
      puts "Model loading error: #{e.message}"
    end

    ActiveRecord::Base.transaction do
      models.each do |m|
        begin
          puts "Deleting #{m.name}..."
          m.delete_all
        rescue => ex
          puts "Failed to clear #{m.name}: #{ex.message}"
        end
      end

      # Reset sqlite sequences if using SQLite
      if ActiveRecord::Base.connection.adapter_name.downcase.include?('sqlite')
        %w[equipment_histories user_equipments activities requests equipments users].each do |t|
          begin
            ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name='#{t}'")
          rescue => _e
          end
        end
      else
        # For Postgres, attempt to reset pk sequences
        ActiveRecord::Base.connection.tables.each do |t|
          next if t == 'schema_migrations'
          begin
            ActiveRecord::Base.connection.reset_pk_sequence!(t)
          rescue => _e
          end
        end
      end
    end

    seed_file = File.exist?('db/seeds_new.rb') ? 'db/seeds_new.rb' : 'db/seeds.rb'
    puts "Loading seed file: #{seed_file}"
    load seed_file
    puts "Reset and seed completed."
  end
end
