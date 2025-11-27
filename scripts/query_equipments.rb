require 'yaml'
require 'erb'
require 'active_record'

cfg_text = File.read(File.join(__dir__, '..', 'config', 'database.yml'))
# Allow YAML aliases used by database.yml (ERB-processed)
cfg = YAML.load(ERB.new(cfg_text).result, aliases: true)
ActiveRecord::Base.establish_connection(cfg['development'])
require File.join(__dir__, '..', 'models', 'equipment')

puts '--- equipments matching faculty ---'
Equipment.where("LOWER(location) LIKE ?", '%faculty%').limit(200).each do |e|
  puts [e.id, e.name, e.serial_number, e.location, e.quantity].inspect
end

puts '--- equipments matching it+faculty ---'
Equipment.where("LOWER(location) LIKE ?", '%it+faculty%').limit(200).each do |e|
  puts [e.id, e.name, e.serial_number, e.location, e.quantity].inspect
end

puts '--- equipments matching it ---'
Equipment.where("LOWER(location) LIKE ?", '%it%').limit(200).each do |e|
  puts [e.id, e.name, e.serial_number, e.location, e.quantity].inspect
end
