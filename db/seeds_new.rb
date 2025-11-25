require_relative '../models/equipment'
require_relative '../models/user'
require_relative '../models/request'
require_relative '../models/user_equipment'
require_relative '../models/equipment_history'

puts "Seeding new dataset..."

equipments = [
  { name: 'Lenovo ThinkPad X1 Carbon', serial_number: 'LN-X1-1001', model: 'X1 Carbon Gen9', vendor: 'Lenovo', purchase_date: '2023-02-01', warranty_until: '2026-02-01', status: 'available', location: 'Office A', category: 'Laptop', notes: '', quantity: 5, purchase_price: 2000.0, brand: 'Lenovo' },
  { name: 'MacBook Pro 14', serial_number: 'MBP14-2001', model: 'MacBook Pro 14', vendor: 'Apple', purchase_date: '2024-01-15', warranty_until: '2027-01-14', status: 'available', location: 'Office B', category: 'Laptop', notes: '', quantity: 3, purchase_price: 2400.0, brand: 'Apple' },
  { name: 'Dell OptiPlex 7090', serial_number: 'DL-OP-3001', model: 'OptiPlex 7090', vendor: 'Dell', purchase_date: '2022-06-20', warranty_until: '2025-06-19', status: 'available', location: 'Office A', category: 'Desktop', notes: '', quantity: 4, purchase_price: 900.0, brand: 'Dell' },
  { name: 'Cisco Catalyst 9200', serial_number: 'CS-9200-4001', model: 'Catalyst 9200', vendor: 'Cisco', purchase_date: '2021-09-10', warranty_until: '2024-09-09', status: 'available', location: 'Server Room', category: 'Network', notes: '', quantity: 2, purchase_price: 1500.0, brand: 'Cisco' },
  { name: 'Logitech MX Master 3', serial_number: 'LG-MX3-5001', model: 'MX Master 3', vendor: 'Logitech', purchase_date: '2023-11-05', warranty_until: '2026-11-04', status: 'available', location: 'Consumables', category: 'Peripherals', notes: '', quantity: 10, purchase_price: 99.0, brand: 'Logitech' }
]

equipments.each do |attrs|
  item = Equipment.find_or_initialize_by(serial_number: attrs[:serial_number])
  item.assign_attributes(attrs)
  item.save!
end

puts "Created #{Equipment.count} equipments."

# Create users
users = [
  { username: 'alice', password: 'password1', role: 'super-admin' },
  { username: 'bob', password: 'password2', role: 'semi-admin' },
  { username: 'charlie', password: 'password3', role: 'normal' }
]

users.each do |u|
  user = User.find_or_initialize_by(username: u[:username])
  user.password = u[:password]
  user.role = u[:role]
  user.save!
end

puts "Created #{User.count} users."

# Create some deployed requests (approved)
r1_eq = Equipment.find_by(serial_number: 'LN-X1-1001')
r2_eq = Equipment.find_by(serial_number: 'MBP14-2001')

if r1_eq
  r = Request.create!(equipment: r1_eq, quantity: 1, requester_name: 'Charlie', requested_at: Time.now, status: 'approved', approved_at: Time.now, checkout_date: Date.today, expected_return_date: Date.today + 14)
  # decrement stock
  r1_eq.quantity = (r1_eq.quantity || 0) - r.quantity
  r1_eq.save!
  # create a user_equipment row
  ue = UserEquipment.create!(user: User.find_by(username: 'charlie'), equipment: r1_eq, request: r, serial: r1_eq.serial_number, assigned_at: Time.now)
  EquipmentHistory.create!(equipment: r1_eq, user: User.find_by(username: 'charlie'), user_equipment: ue, request: r, action: 'assigned', details: { serial: r1_eq.serial_number }.to_json, occurred_at: Time.now) rescue nil
end

if r2_eq
  r = Request.create!(equipment: r2_eq, quantity: 1, requester_name: 'Bob', requested_at: Time.now, status: 'approved', approved_at: Time.now, checkout_date: Date.today, expected_return_date: Date.today + 14)
  r2_eq.quantity = (r2_eq.quantity || 0) - r.quantity
  r2_eq.save!
  ue = UserEquipment.create!(user: User.find_by(username: 'bob'), equipment: r2_eq, request: r, serial: r2_eq.serial_number, assigned_at: Time.now)
  EquipmentHistory.create!(equipment: r2_eq, user: User.find_by(username: 'bob'), user_equipment: ue, request: r, action: 'assigned', details: { serial: r2_eq.serial_number }.to_json, occurred_at: Time.now) rescue nil
end

puts "Created sample approved requests and user_equipment records."
