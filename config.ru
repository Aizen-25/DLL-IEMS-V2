# If a DATABASE_URL environment variable is present but empty, remove it.
# Some platforms may set an empty DATABASE_URL which ActiveRecord treats as
# an invalid connection string and raises during app load. Removing the key
# lets the app fall back to `config/database.yml` or skip DB setup.
if ENV.key?('DATABASE_URL') && ENV['DATABASE_URL'].to_s.strip.empty?
	ENV.delete('DATABASE_URL')
end

require_relative 'app'
run Sinatra::Application
