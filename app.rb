require 'sinatra'
require 'sinatra/activerecord'
begin
  require 'sinatra/reloader' if development?
rescue LoadError
  # sinatra-contrib (which provides sinatra/reloader) is not installed.
  # Continue without automatic reloader. Install with bundler or `gem install sinatra-contrib`.
end
require 'json'
require 'csv'
require 'securerandom'
require_relative 'models/equipment'
require_relative 'models/request'
require_relative 'models/activity'
require_relative 'models/user'
require_relative 'models/user_equipment'
require_relative 'models/equipment_history'
set :database_file, 'config/database.yml'

# If a DATABASE_URL is provided (Render/Postgres), prefer it for ActiveRecord
if ENV['DATABASE_URL'] && !ENV['DATABASE_URL'].to_s.strip.empty?
  begin
    ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'])
  rescue => _e
    # fall back to database.yml if something goes wrong
  end
end

# Bind to all interfaces and honor the PORT environment variable (Render sets $PORT)
set :bind, ENV.fetch('BIND', '0.0.0.0')
set :port, ENV.fetch('PORT', 4567).to_i

# Enable sessions for login
enable :sessions
set :session_secret, ENV['SESSION_SECRET'] || 'inventory_system_secret_key_change_in_production_minimum_64_bytes_required_for_security'

# Admin credentials (in production, use database with hashed passwords)
ADMIN_USERNAME = 'admin'
ADMIN_PASSWORD = 'admin123'

# Helper methods for authentication and current user
helpers do
  def logged_in?
    session[:user_id] && User.exists?(id: session[:user_id])
  end

  def require_login!
    unless logged_in?
      redirect '/login'
    end
  end

  def require_super_admin!
    # Safely check current_user and role
    unless logged_in? && current_user && current_user.super_admin?
      redirect '/dashboard'
    end
  end
  
  def require_at_least_semi!
    unless logged_in? && current_user && (current_user.semi_admin? || current_user.super_admin?)
      redirect '/dashboard'
    end
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end
end

before do
  # Skip authentication for login routes
  pass if request.path_info == '/login' || request.path_info == '/logout'
  
  # Require login for all other routes
  require_login!
  
  # make pending requests count available to views (sidebar badge)
  begin
    @pending_requests_count = Request.where(status: 'pending').count
    @pending_returns_count = Request.where(status: 'pending_return').count
  rescue => _
    @pending_requests_count = 0
    @pending_returns_count = 0
  end
end

# Health check endpoint for Render / monitoring
get '/health' do
  content_type :json
  status 200
  { status: 'ok', time: Time.now.utc.iso8601 }.to_json
end

# Login routes
get '/login' do
  if logged_in?
    redirect '/dashboard'
  end
  erb :login, layout: false
end

post '/login' do
  username = params['username']&.strip
  password = params['password']

  # First try to authenticate against users table (bcrypt)
  if username && !username.empty?
    user = User.find_by(username: username)
    if user && user.password == password
        session[:user_id] = user.id
        session[:username] = user.username
        # If this account requires a password change, send them to the change flow
      if user.respond_to?(:must_change_password) && user.must_change_password
          redirect '/password_change'
        else
          redirect '/dashboard'
        end
    end
  end

  # Fallback: allow legacy ADMIN credentials and ensure a super-admin user exists
  if username == ADMIN_USERNAME && password == ADMIN_PASSWORD
    user = User.find_or_create_by(username: ADMIN_USERNAME) do |u|
      u.password = ADMIN_PASSWORD
      u.role = 'super-admin'
    end
    session[:user_id] = user.id
    session[:username] = user.username
    redirect '/dashboard'
  end

  @error = 'Invalid username or password'
  erb :login, layout: false
end

get '/logout' do
  session.clear
  redirect '/login'
end

get '/' do
  redirect '/dashboard'
end

get '/dashboard' do
  # Year filter (optional)
  filter_year = params['year']&.to_i
  filter_year = nil if filter_year && (filter_year < 2000 || filter_year > Date.today.year + 1)

  equipments = Equipment.order(:created_at)

  # Summary metrics
  # Compute deployed counts from approved, not-returned requests
  # Apply year filter to approved_at if present
  deployed_scope = Request.where(status: 'approved').where(returned_at: nil)
  if filter_year
    year_start = Date.new(filter_year, 1, 1)
    year_end = Date.new(filter_year, 12, 31)
    deployed_scope = deployed_scope.where('approved_at >= ? AND approved_at <= ?', year_start, year_end)
  end
  deployed_counts = deployed_scope.group(:equipment_id).sum(:quantity)
  # totals for tiles
  @total_deployed = deployed_counts.values.sum
  @total_available_stock = Equipment.sum(:quantity)
  # Backwards-compatible variables used elsewhere
  @total_units = @total_deployed
  @assets_in_stock = Equipment.where(status: 'available').sum(:quantity)
  @assets_in_use = @total_deployed
  @total_value = equipments.sum { |e| (e.quantity || 0) * (e.purchase_price || 0.0) }

  # Low stock: configurable threshold
  low_stock_threshold = (params['low_stock_threshold'] || 3).to_i
  @low_stock = Equipment.where('quantity IS NOT NULL').select { |e| (e.quantity || 0) < low_stock_threshold }

  # Recent activity: build simple events from created_at and updated_at (no audit log yet)
  events = []
  Equipment.find_each do |e|
    # Apply year filter to event timestamps
    if filter_year.nil? || e.created_at.year == filter_year
      events << { time: e.created_at, message: "#{e.name} added", equipment_id: e.id }
    end
    if e.updated_at && e.updated_at > e.created_at
      if filter_year.nil? || e.updated_at.year == filter_year
        events << { time: e.updated_at, message: "#{e.name} updated (status: #{e.status})", equipment_id: e.id }
      end
    end
  end
  @recent_activity = events.sort_by { |ev| -ev[:time].to_i }.first(10)

  # Upcoming warranty / end-of-life needs (3,6,12 months buckets)
  today = Date.today
  three = today + 90
  six = today + 180
  twelve = today + 365

  @warranty_3 = Equipment.where('warranty_until IS NOT NULL AND warranty_until >= ? AND warranty_until <= ?', today, three).count
  @warranty_6 = Equipment.where('warranty_until IS NOT NULL AND warranty_until > ? AND warranty_until <= ?', three, six).count
  @warranty_12 = Equipment.where('warranty_until IS NOT NULL AND warranty_until > ? AND warranty_until <= ?', six, twelve).count

  # distribution by category
  @category_distribution = Equipment.group(:category).count.transform_keys { |k| k || 'Uncategorized' }

  # distribution by equipment status (e.g., working, undermaintenance)
  @status_counts = Equipment.group(:status).count.transform_keys { |k| k || 'Unspecified' }
  # build ordered rows for status display (sort descending) and ensure 'Other' appears at the end
  status_rows = @status_counts.map { |k, v| { status: k.to_s, count: v } }
  status_rows = status_rows.sort_by { |r| -r[:count] }
  unless status_rows.any? { |r| r[:status].to_s == 'Other' }
    status_rows << { status: 'Other', count: 0 }
  end
  @status_rows = status_rows

  # distribution by location/office
  # NOTE: Use deployed Request rows (approved, not returned) so dashboard shows where assets are actually deployed.
  # We parse `notes` for a "Deployed to <location>" pattern (deployed flow writes this), falling back to equipment.location.
  deployed_loc_counts = Hash.new(0)
  deployed_scope.find_each do |rq|
    loc = nil
    if rq.notes && rq.notes.match(/Deployed to\s*([^;\n]+)/i)
      loc = rq.notes.match(/Deployed to\s*([^;\n]+)/i)[1].to_s.strip
      loc = nil if loc.empty?
    end
    loc ||= (rq.equipment && rq.equipment.location)
    loc = (loc.nil? || loc.to_s.strip.empty?) ? 'Unspecified' : loc.to_s
    deployed_loc_counts[loc] += (rq.quantity || 1)
  end
  location_rows = deployed_loc_counts.map { |k, v| { location: k.to_s, count: v } }
  location_rows = location_rows.sort_by { |r| -r[:count] }
  unless location_rows.any? { |r| r[:location].to_s == 'Other' }
    location_rows << { location: 'Other', count: 0 }
  end
  @location_rows = location_rows
  # compute deployed per product for dashboard (showing number deployed per equipment)
  # allow optional name filter (search by equipment name)
  name_filter = params['equipment_name']&.strip
  if name_filter && !name_filter.empty?
    equipments_scope = Equipment.where('name LIKE ?', "%#{name_filter}%")
  else
    equipments_scope = Equipment.all
  end

  top_n = (params['top_n'] || 6).to_i
  # Build deployed names list per equipment (try to parse serials from request notes)
  @top_deployed = equipments_scope.map do |e|
    reqs = deployed_scope.where(equipment_id: e.id)
    deployed_names = []
    reqs.each do |rq|
      # remember where this request's entries start so we can attach a per-request status suffix
      start_index = deployed_names.length
      # try component_serials: {..} pattern
      if rq.notes && rq.notes.match(/component_serials:\s*(\{.*\})/m)
        begin
          json = rq.notes.match(/component_serials:\s*(\{.*\})/m)[1]
          parsed = JSON.parse(json) rescue {}
          # parsed may be a hash of unit indexes or component => serial; flatten values
          if parsed.is_a?(Hash)
            # If keys are numeric strings mapping to component objects, handle nested
            if parsed.values.all? { |v| v.is_a?(Hash) }
              parsed.values.each do |unit|
                unit_serials = unit.values.map(&:to_s).reject(&:empty?)
                  unit_serials = unit.values.map(&:to_s).map(&:strip).reject(&:empty?)
                  deployed_names << (unit_serials.empty? ? "#{e.name} (no-serial)" : unit_serials.join(' / '))
              end
            else
              # flat hash of component=>serial
              vals = parsed.values.map(&:to_s).reject(&:empty?)
                vals = parsed.values.map(&:to_s).map(&:strip).reject(&:empty?)
                deployed_names << (vals.empty? ? "#{e.name} (no-serial)" : vals.join(' / '))
            end
          end
        rescue => _e
        end
      elsif rq.notes && rq.notes.match(/serial:\s*([^;\n]+)/i)
        s = rq.notes.match(/serial:\s*([^;\n]+)/i)[1].to_s.strip
        deployed_names << (s.empty? ? "#{e.name} (no-serial)" : s)
      else
        # fallback: create placeholders according to quantity
        (rq.quantity || 1).times { deployed_names << "#{e.name} (deployed)" }
      end
      # attach per-request status (if any) to the entries we just added for this request
      added_count = deployed_names.length - start_index
      if added_count > 0
        begin
          latest = EquipmentHistory.where(request_id: rq.id, action: 'status_change').order(occurred_at: :desc).first
          if latest && latest.details
            details = JSON.parse(latest.details) rescue nil
            new_status = details.is_a?(Hash) ? (details['status'] || details['new_status']) : nil
            if new_status && !new_status.to_s.strip.empty?
              # append status to the entries added for this request
              (0...added_count).each do |i|
                idx = start_index + i
                deployed_names[idx] = "#{deployed_names[idx]} (#{new_status})"
              end
            end
          end
        rescue => _e
          # ignore history parsing failures
        end
      end
    end
    # ensure count matches deployed_counts if possible
    desired = deployed_counts[e.id] || 0
    if deployed_names.length < desired
      (desired - deployed_names.length).times { deployed_names << "#{e.name} (deployed)" }
    end
    { id: e.id, name: e.name, deployed: deployed_counts[e.id] || 0, deployed_names: deployed_names }
  end.sort_by { |h| -h[:deployed] }.first(top_n)

    # Deployed counts by category (e.g., laptop, desktop)
    raw_by_cat = deployed_scope.joins(:equipment).group('equipments.category').sum(:quantity)
    cat_counts = raw_by_cat.transform_keys { |k| k || 'Uncategorized' }
    rows = cat_counts.map { |cat, cnt| { category: cat.to_s, count: cnt } }.sort_by { |h| -h[:count] }
    unless rows.any? { |r| r[:category].to_s == 'Other' }
      rows << { category: 'Other', count: 0 }
    end
    @deployed_by_category_rows = rows
    # keep old variable name for compatibility where used elsewhere
    @deployed_by_category = @deployed_by_category_rows
    # debug logging removed: no persistent dashboard snapshots
  @inventory_by_product = @top_deployed
  @stockout_rates = { monthly: [5, 2, 8, 3], quarterly: [6, 4, 7] }
  @inventory_costs = { holding: 55, ordering: 30, shortage: 15 }
  
  # Calculate turnover rates per quarter for the filtered year (or current year)
  target_year = filter_year || Date.today.year
  @turnover_rates = {}
  [1, 2, 3, 4].each do |q|
    q_start = Date.new(target_year, (q-1)*3 + 1, 1)
    q_end = q_start.end_of_quarter rescue Date.new(target_year, q*3, [31, 30, 30, 31][q-1])
    q_scope = Request.where(status: 'approved').where('approved_at >= ? AND approved_at <= ?', q_start, q_end)
    deployed_qty = q_scope.sum(:quantity)
    avg_stock = Equipment.sum(:quantity) # simplified: use current stock as average
    rate = avg_stock > 0 ? (deployed_qty.to_f / avg_stock * 4).round(1) : 0.0
    @turnover_rates["Q#{q}"] = rate
  end

  erb :'dashboard'
end

# Placeholder pages for sidebar navigation
get '/requests' do
  # Filters
  name_q = params['name']
  office_q = params['office']
  equipment_q = params['equipment_name']
  serial_q = params['serial']
  deployed_date_q = params['deployed_date']

  @pending_requests = Request.pending.order(created_at: :desc)

  # If user requested to view pending returns, show those; otherwise show active approved loans
  if params['filter'] == 'pending_return' || params['filter'] == 'pending_returns'
    loans = Request.where(status: 'pending_return')
  else
    loans = Request.approved.where(returned_at: nil)
  end
  loans = loans.joins(:equipment).where('equipments.name LIKE ?', "%#{equipment_q}%") if equipment_q && !equipment_q.strip.empty?
  loans = loans.where('requests.requester_name LIKE ?', "%#{name_q}%") if name_q && !name_q.strip.empty?
  loans = loans.where('requests.notes LIKE ?', "%#{office_q}%") if office_q && !office_q.strip.empty?
  loans = loans.where('requests.notes LIKE ?', "%#{serial_q}%") if serial_q && !serial_q.strip.empty?
  if deployed_date_q && !deployed_date_q.strip.empty?
    begin
      d = Date.parse(deployed_date_q) rescue nil
      loans = loans.where(checkout_date: d) if d
    rescue => _e
    end
  end

  @current_loans = loans.order(checkout_date: :desc)
  # one-time temp password info (set after deploy auto-create or force-reset)
  @temp_password_info = session.delete(:temp_password_for_user)
  erb :'requests'
end

post '/requests/:id/status' do
  require_super_admin!
  rq = Request.find(params[:id])
  new_status = params['new_status']
  diagnostic = params['diagnostic']
  # Update request-level status (per-deployed unit) and append diagnostic to request notes
  # Avoid mutating the shared Equipment.status which represents the model stock
  if rq && new_status
    # Do not change the Request lifecycle status for equipment condition updates
    # (e.g., 'under repair', 'damaged') because that would remove the loan from
    # the active deployed list which should only happen on return flows.
    note = "Status changed to #{new_status}"
    note += "; Diagnostic: #{diagnostic}" if diagnostic && !diagnostic.strip.empty?
    rq.notes = [rq.notes, note].compact.join(' ; ')
    rq.save! if rq.changed?

    # Create UserEquipment records for each deployed unit so we track per-unit assignment and purchase date
    if defined?(deployed_units) && deployed_units.any?
      deployed_units.each_with_index do |unit, idx|
        begin
          serial_val = unit.is_a?(Hash) ? (unit['serial'] || unit['component']) : nil
          purchase_date_val = nil
          if unit.is_a?(Hash) && unit['purchase_date'] && !unit['purchase_date'].to_s.strip.empty?
            begin
              purchase_date_val = Date.parse(unit['purchase_date'].to_s) rescue nil
            rescue => _e
              purchase_date_val = nil
            end
          end
          # try to resolve the assigned user: prefer created candidate username, then assigned_to field, else current_user
          assigned_user = nil
          if defined?(candidate) && candidate
            assigned_user = User.find_by(username: candidate)
          end
          if !assigned_user && unit.is_a?(Hash) && unit['assigned_to'] && !unit['assigned_to'].strip.empty?
            assigned_user = User.find_by(username: unit['assigned_to'])
          end
          assigned_user ||= current_user

          ue = UserEquipment.create!(user: assigned_user, equipment: equipment, request: rq, serial: serial_val, purchase_date: purchase_date_val, assigned_at: Time.now, unit_index: (unit['unit_index'] || idx+1))
          begin
            if defined?(EquipmentHistory)
              EquipmentHistory.create!(equipment: equipment, user: assigned_user, user_equipment: ue, request: rq, action: 'assigned', details: { serial: serial_val, purchase_date: purchase_date_val, assigned_at: ue.assigned_at }.to_json, occurred_at: Time.now)
            end
          rescue => _e
            # ignore history failures
          end
        rescue => _e
          # ignore per-unit failures to avoid breaking deploy; log activity optionally
        end
      end
    end
    begin
      Activity.create!(trackable: rq, action: 'status_change', user_name: 'system', changes_made: {status: new_status, diagnostic: diagnostic}.to_json)
    rescue => _e
    end
    # also persist equipment-history for analytics if equipment present
    begin
      if rq.equipment
        # normalize action names for easier querying
        action_name = case new_status.to_s.strip.downcase
                      when 'damaged' then 'damaged'
                      when 'under repair', 'maintenance' then 'under_repair'
                      else 'status_change'
                      end
        EquipmentHistory.create!(equipment: rq.equipment, user: (current_user rescue nil), request: rq, action: action_name, details: { status: new_status, diagnostic: diagnostic, changed_by: (current_user&.username rescue nil) }.to_json, occurred_at: Time.now)
      end
    rescue => _e
    end
  end
  redirect '/requests'
end

get '/requests/new' do
  @equipments = Equipment.order(:name)
  erb :'requests_new'
end

post '/requests' do
  rq = Request.new(
    equipment_id: params.dig('request','equipment_id'),
    quantity: params.dig('request','quantity') || 1,
    requester_name: params.dig('request','requester_name'),
    requested_at: Time.now,
    notes: params.dig('request','notes')
  )
  if rq.save
    redirect '/requests'
  else
    status 422
    body rq.errors.full_messages.join(', ')
  end
end

post '/requests/:id/approve' do
  rq = Request.find(params[:id])
  equipment = rq.equipment
  # basic stock check and create loan
  if equipment && (equipment.quantity || 0) < rq.quantity
    status 422
    return "Not enough stock to approve"
  end

  rq.status = 'approved'
  rq.approved_at = Time.now
  rq.checkout_date ||= Date.today
  rq.expected_return_date ||= Date.today + 14
  rq.save!

  if equipment
    equipment.quantity = (equipment.quantity || 0) - rq.quantity
    equipment.save!
  end

  redirect '/requests'
end

post '/requests/:id/deny' do
  rq = Request.find(params[:id])
  rq.status = 'denied'
  rq.approved_at = Time.now
  rq.save!
  redirect '/requests'
end

post '/requests/:id/return' do
  require_at_least_semi!
  rq = Request.find(params[:id])
  # If super-admin, finalize return immediately. If semi-admin, mark as pending_return for confirmation.
  if rq.returned_at
    redirect '/requests'
  end

  if current_user && current_user.super_admin?
    # finalize return
    rq.returned_at = Date.today
    rq.status = 'returned'
    rq.notes = [rq.notes, "Return confirmed by #{current_user.username}"].compact.join(' ; ')
    rq.save!
    if rq.equipment
      rq.equipment.quantity = (rq.equipment.quantity || 0) + rq.quantity
      rq.equipment.save!
    end
    begin
      Activity.create!(trackable: rq, action: 'return_confirmed', user_name: current_user.username, changes_made: { returned_at: rq.returned_at, request_id: rq.id }.to_json)
    rescue => _e
    end
    # mark associated user_equipment rows as returned
    begin
      UserEquipment.where(request_id: rq.id, active: true).find_each do |ue|
        ue.mark_returned!
      end
    rescue => _e
    end
    # record returned history entries
    begin
      UserEquipment.where(request_id: rq.id).find_each do |ue|
        begin
          EquipmentHistory.create!(equipment: ue.equipment, user: ue.user, user_equipment: ue, request: rq, action: 'returned', details: { returned_at: ue.returned_at, serial: ue.serial }.to_json, occurred_at: ue.returned_at || Time.now)
        rescue => _e2
        end
      end
    rescue => _e
    end
  else
    # mark pending return for super-admin confirmation
    rq.status = 'pending_return'
    rq.notes = [rq.notes, "Return requested by #{current_user&.username || 'unknown'}"].compact.join(' ; ')
    rq.save!
    begin
      Activity.create!(trackable: rq, action: 'return_requested', user_name: current_user&.username || 'unknown', changes_made: { request_id: rq.id }.to_json)
    rescue => _e
    end
  end

  redirect '/requests'
end

# Super-admin confirmation endpoint for pending returns
post '/requests/:id/confirm_return' do
  require_super_admin!
  rq = Request.find(params[:id])
  if rq && rq.status == 'pending_return'
    rq.returned_at = Date.today
    rq.status = 'returned'
    rq.notes = [rq.notes, "Return confirmed by #{current_user.username}"].compact.join(' ; ')
    rq.save!
    if rq.equipment
      rq.equipment.quantity = (rq.equipment.quantity || 0) + rq.quantity
      rq.equipment.save!
    end
    begin
      Activity.create!(trackable: rq, action: 'return_confirmed', user_name: current_user.username, changes_made: { request_id: rq.id }.to_json)
    rescue => _e
    end
    # mark associated user_equipment rows as returned
    begin
      UserEquipment.where(request_id: rq.id, active: true).find_each do |ue|
        ue.mark_returned!
      end
    rescue => _e
    end
    # record returned history entries
    begin
      UserEquipment.where(request_id: rq.id).find_each do |ue|
        begin
          EquipmentHistory.create!(equipment: ue.equipment, user: ue.user, user_equipment: ue, request: rq, action: 'returned', details: { returned_at: ue.returned_at, serial: ue.serial }.to_json, occurred_at: ue.returned_at || Time.now)
        rescue => _e2
        end
      end
    rescue => _e
    end
  end
  redirect '/requests'
end

post '/requests/:id/reject_return' do
  require_super_admin!
  rq = Request.find(params[:id])
  if rq && rq.status == 'pending_return'
    # Revert to deployed/approved state when rejecting a return
    rq.status = 'approved'
    rq.notes = [rq.notes, "Return rejected by #{current_user.username}; reverted to approved"].compact.join(' ; ')
    rq.save!
    begin
      Activity.create!(trackable: rq, action: 'return_rejected', user_name: current_user.username, changes_made: { request_id: rq.id }.to_json)
    rescue => _e
    end
    begin
      # record history of the rejection
      EquipmentHistory.create!(equipment: rq.equipment, user: current_user, request: rq, action: 'return_rejected', details: { request_id: rq.id }.to_json, occurred_at: Time.now) if rq.equipment
    rescue => _e
    end
  end
  redirect '/requests'
end

get '/users' do
  require_super_admin!
  @users = User.all.order(:created_at)
  # one-time temp password info (set after force-reset or create)
  @temp_password_info = session.delete(:temp_password_for_user)
  erb :'users/index'
end

get '/users/:id/temp_password' do
  require_super_admin!
  u = User.find_by(id: params[:id])
  if u && u.respond_to?(:must_change_password) && u.must_change_password && u.respond_to?(:temporary_password) && u.temporary_password
    content_type :json
    { username: u.username, password: u.temporary_password }.to_json
  else
    status 404
    "Not found or no temporary password available"
  end
end

post '/users/:id/force_reset' do
  require_super_admin!
  u = User.find_by(id: params[:id])
  if u
    # generate a secure temporary password, set on the user and mark for change
    # use urlsafe_base64 and strip non-alphanumerics to avoid dependency on base58
    temp_pw = SecureRandom.urlsafe_base64(8).gsub(/[^0-9A-Za-z]/, '')[0,12]
    u.password = temp_pw
    u.must_change_password = true
    u.temporary_password = temp_pw if u.respond_to?(:temporary_password)
    u.password_changed_at = nil if u.respond_to?(:password_changed_at)
    u.save!
    # store one-time info in session for immediate display; password is also persisted in temporary_password
    session[:temp_password_for_user] = { 'id' => u.id, 'username' => u.username, 'password' => temp_pw }
  end
  redirect '/users'
end

get '/users/new' do
  require_super_admin!
  erb :'users/new'
end

post '/users' do
  require_super_admin!
  username = params['username']
  password = params['password']
  role = params['role']

  if username.empty? || password.empty? || !%w[normal semi-admin super-admin].include?(role)
    @error = 'Invalid input. Please fill all fields correctly.'
    erb :'users/new'
  else
    # mark newly created users to require password change on first login and store temp password
    u = User.create!(username: username, password: password, role: role, must_change_password: true, temporary_password: password)
    redirect '/users'
  end
end

# Password change flow for first-time / forced change
get '/password_change' do
  require_login!
  erb :'users/change_password'
end

post '/password_change' do
  require_login!
  new_pw = params['new_password']
  confirm_pw = params['confirm_password']
  if new_pw.nil? || new_pw.strip.empty?
    @error = 'Password cannot be blank'
    return erb :'users/change_password'
  end
  if new_pw != confirm_pw
    @error = 'Passwords do not match'
    return erb :'users/change_password'
  end

  u = current_user
  begin
    u.password = new_pw
    # clear temporary password and mark changed
    u.must_change_password = false if u.respond_to?(:must_change_password)
    u.password_changed_at = Time.now if u.respond_to?(:password_changed_at)
    u.temporary_password = nil if u.respond_to?(:temporary_password)
    u.save!
    redirect '/dashboard'
  rescue => e
    @error = 'Failed to update password'
    erb :'users/change_password'
  end
end

get '/reports' do
  erb :'reports'
end

# Report: brands-by-category with high problem/under-repair rates
get '/reports/problem_brands' do
  # consider statuses that indicate problems
  problem_statuses = ['maintenance', 'under repair', 'damaged']

  # ensure latest columns
  Equipment.reset_column_information

  # total by category+brand
  totals = Equipment.group(:category, :brand).count
  problems = Equipment.where(status: problem_statuses).group(:category, :brand).count

  @rows = totals.map do |(category, brand), total_count|
    problem_count = problems.fetch([category, brand], 0)
    pct = total_count > 0 ? ((problem_count.to_f / total_count) * 100).round(1) : 0.0
    { category: (category || 'Uncategorized'), brand: (brand || 'Unknown'), total: total_count, problems: problem_count, pct: pct }
  end

  # sort by pct desc then problem count
  @rows = @rows.sort_by { |r| [-r[:pct], -r[:problems], r[:category], r[:brand]] }

  erb :'reports/problem_brands'
end

# Top repaired / damaged items report
get '/reports/top_repairs' do
  require_super_admin!
  top_n = (params['top_n'] || 10).to_i
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil

  q = EquipmentHistory.where(action: ['damaged','under_repair','status_change','returned','assigned'])
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to

  # Count damaged and repair events per equipment
  counts = Hash.new { |h,k| h[k] = { damaged: 0, repairs: 0, returned: 0, total: 0 } }
  q.find_each do |h|
    next unless h.equipment_id
    counts[h.equipment_id][:total] += 1
    case h.action
    when 'damaged'
      counts[h.equipment_id][:damaged] += 1
    when 'under_repair'
      counts[h.equipment_id][:repairs] += 1
    when 'returned'
      counts[h.equipment_id][:returned] += 1
    when 'status_change'
      # treat status_change that mention repair/damaged as repairs
      d = h.details_hash rescue {}
      s = (d['status'] || '').to_s.downcase
      if s.include?('repair') || s.include?('under repair')
        counts[h.equipment_id][:repairs] += 1
      elsif s.include?('damaged')
        counts[h.equipment_id][:damaged] += 1
      end
    end
  end

  # Build rows with equipment info
  rows = counts.map do |equipment_id, c|
    eq = Equipment.find_by(id: equipment_id)
    next unless eq
    { equipment: eq, damaged: c[:damaged], repairs: c[:repairs], returned: c[:returned], total: c[:total] }
  end.compact

  # sort by (damaged+repairs) desc then total desc
  @rows = rows.sort_by { |r| [-(r[:damaged] + r[:repairs]), -r[:total], r[:equipment].name] }.first(top_n)
  @from = from
  @to = to
  @top_n = top_n

  erb :'reports/top_repairs'
end

get '/reports/top_repairs.csv' do
  require_super_admin!
  content_type 'text/csv'
  top_n = (params['top_n'] || 100).to_i
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil

  q = EquipmentHistory.where(action: ['damaged','under_repair','status_change','returned','assigned'])
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to

  counts = Hash.new { |h,k| h[k] = { damaged: 0, repairs: 0, returned: 0, total: 0 } }
  q.find_each do |h|
    next unless h.equipment_id
    counts[h.equipment_id][:total] += 1
    case h.action
    when 'damaged' then counts[h.equipment_id][:damaged] += 1
    when 'under_repair' then counts[h.equipment_id][:repairs] += 1
    when 'returned' then counts[h.equipment_id][:returned] += 1
    when 'status_change'
      d = h.details_hash rescue {}
      s = (d['status'] || '').to_s.downcase
      counts[h.equipment_id][:repairs] += 1 if s.include?('repair')
      counts[h.equipment_id][:damaged] += 1 if s.include?('damaged')
    end
  end

  rows = counts.map do |equipment_id, c|
    eq = Equipment.find_by(id: equipment_id)
    next unless eq
    [eq.id, eq.name, eq.serial_number, eq.brand, c[:damaged], c[:repairs], c[:returned], c[:total]]
  end.compact
  rows = rows.sort_by { |r| [-(r[4] + r[5]), -r[7]] }.first(top_n)

  csv = CSV.generate do |csv_out|
    csv_out << ['equipment_id','name','serial_number','brand','damaged_count','repair_count','returned_count','total_events']
    rows.each { |r| csv_out << r }
  end
  csv
end

# JSON endpoint for charts: supports snapshot (current status) and history (activity-based)
get '/reports/problem_brands.json' do
  content_type :json
  mode = params['mode'] || 'snapshot' # 'snapshot' or 'history'
  top_n = (params['top_n'] || 10).to_i
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil

  problem_statuses = ['maintenance', 'under repair', 'damaged']

  Equipment.reset_column_information

  if mode == 'history'
    # Use EquipmentHistory entries to compute history-mode analytics (per-serial accuracy)
    histories = EquipmentHistory.where(action: 'status_change')
    histories = histories.where('occurred_at >= ?', from.beginning_of_day) if from
    histories = histories.where('occurred_at <= ?', to.end_of_day) if to

    brand_counts = Hash.new(0)
    brand_by_month = Hash.new { |h,k| h[k] = Hash.new(0) }

    histories.find_each do |h|
      begin
        details = h.details_hash
        # details expected to be like { 'status' => 'damaged', 'diagnostic' => '...' }
        new_status = details.is_a?(Hash) ? (details['status'] || details['new_status']) : nil
        if new_status && problem_statuses.include?(new_status.to_s.downcase)
          eq = h.equipment || (h.equipment_id && Equipment.find_by(id: h.equipment_id))
          next unless eq
          brand = eq.brand || 'Unknown'
          brand_counts[brand] += 1
          month = (h.occurred_at || h.created_at).strftime('%Y-%m')
          brand_by_month[brand][month] += 1
        end
      rescue => _e
        # ignore malformed history entries
      end
    end

    # prepare top brands
    top_brands = brand_counts.sort_by { |_b,c| -c }.first(top_n).map(&:first)

    # prepare pareto cumulative for the top brands
    counts = top_brands.map { |b| brand_counts[b] || 0 }
    total_problems = counts.sum
    cum = 0
    pareto = top_brands.map.with_index do |b, i|
      cnt = counts[i]
      cum += cnt
      { brand: b, problems: cnt, cumulative_pct: (total_problems > 0 ? ((cum.to_f / total_problems) * 100).round(1) : 0.0) }
    end

    data = {
      mode: 'history',
      top_brands: top_brands,
      counts: counts,
      by_month: top_brands.map { |b| brand_by_month[b] || {} },
      pareto: pareto
    }
    return data.to_json
  else
    # snapshot mode: current equipment statuses
    totals = Equipment.group(:brand).count
    problems = Equipment.where(status: problem_statuses).group(:brand).count

    rows = totals.map do |brand, total_count|
      problem_count = problems.fetch(brand, 0)
      { brand: (brand || 'Unknown'), total: total_count, problems: problem_count }
    end
    rows = rows.sort_by { |r| -r[:problems] }
    top = rows.first(top_n)
    # pareto cumulative
    cum = 0
    total_problems = top.map { |r| r[:problems] }.sum
    pareto = top.map do |r|
      cum += r[:problems]
      { brand: r[:brand], problems: r[:problems], cumulative_pct: (total_problems > 0 ? ((cum.to_f / total_problems) * 100).round(1) : 0.0) }
    end

    # stacked by category for these top brands
    cat_rows = Equipment.where(brand: top.map { |r| r[:brand] }).group(:brand, :category, :status).count
    # build structure: { brand => { category => {problem: x, ok: y, total: z } } }
    stacked = {}
    cat_rows.each do |(brand, category, status), cnt|
      b = brand || 'Unknown'
      c = category || 'Uncategorized'
      stacked[b] ||= {}
      stacked[b][c] ||= { problem: 0, ok: 0, total: 0 }
      if problem_statuses.include?(status)
        stacked[b][c][:problem] += cnt
      else
        stacked[b][c][:ok] += cnt
      end
      stacked[b][c][:total] += cnt
    end

    result = {
      mode: 'snapshot',
      pareto: pareto,
      stacked: stacked
    }

    result.to_json
  end
end

# CSV export for the same report (snapshot or history)
get '/reports/problem_brands.csv' do
  content_type 'text/csv'
  mode = params['mode'] || 'snapshot'
  top_n = (params['top_n'] || 10).to_i
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil

  problem_statuses = ['maintenance', 'under repair', 'damaged']
  Equipment.reset_column_information

  csv = CSV.generate(headers: true) do |csv_out|
    if mode == 'history'
      activities = Activity.where(action: 'status_change')
      activities = activities.where('created_at >= ?', from.beginning_of_day) if from
      activities = activities.where('created_at <= ?', to.end_of_day) if to

      brand_counts = Hash.new(0)
      activities.find_each do |a|
        ch = a.changes_hash rescue {}
        if ch && ch['status'] && ch['status'].is_a?(Array)
          new_status = ch['status'][1]
          if new_status && problem_statuses.include?(new_status.downcase)
            if a.trackable_type == 'Equipment' && a.trackable_id
              eq = Equipment.find_by(id: a.trackable_id)
              next unless eq
              brand = eq.brand || 'Unknown'
              brand_counts[brand] += 1
            elsif a.trackable && a.trackable.respond_to?(:equipment)
              eq = a.trackable.equipment rescue nil
              if eq
                brand = eq.brand || 'Unknown'
                brand_counts[brand] += 1
              end
            end
          end
        end
      end

      rows = brand_counts.map { |b,c| { brand: b, problems: c } }.sort_by { |r| -r[:problems] }
      top = rows.first(top_n)
      total_problems = top.map { |r| r[:problems] }.sum
      csv_out << ['brand', 'problems', 'cumulative_pct']
      cum = 0
      top.each do |r|
        cum += r[:problems]
        csv_out << [r[:brand], r[:problems], (total_problems > 0 ? ((cum.to_f / total_problems) * 100).round(1) : 0.0)]
      end
    else
      totals = Equipment.group(:brand).count
      problems = Equipment.where(status: problem_statuses).group(:brand).count
      rows = totals.map do |brand, total_count|
        { brand: (brand || 'Unknown'), total: total_count, problems: problems.fetch(brand, 0) }
      end
      rows = rows.sort_by { |r| -r[:problems] }
      top = rows.first(top_n)
      total_problems = top.map { |r| r[:problems] }.sum
      csv_out << ['brand', 'total', 'problems', 'cumulative_pct']
      cum = 0
      top.each do |r|
        cum += r[:problems]
        csv_out << [r[:brand], r[:total], r[:problems], (total_problems > 0 ? ((cum.to_f / total_problems) * 100).round(1) : 0.0)]
      end
    end
  end

  attachment "problem_brands_#{mode}.csv"
  csv
end

# Simple test page to validate chart rendering in the browser
get '/chart_test' do
  # compute deployed-by-category for the test chart (approved, not returned)
  raw_by_cat = Request.joins(:equipment).where(status: 'approved', returned_at: nil).group('equipments.category').sum(:quantity)
  if raw_by_cat && raw_by_cat.any?
    @cat_labels = raw_by_cat.keys.map { |k| (k || 'Uncategorized') }
    @cat_data = raw_by_cat.values
  else
    # default sample so the page always has something to show
    @cat_labels = ['Laptop']
    @cat_data = [2]
  end
  erb :'chart_test'
end

get '/reports/utilization' do
  # params: from, to
  from = params['from'] ? Date.parse(params['from']) : (Date.today - 365)
  to = params['to'] ? Date.parse(params['to']) : Date.today

  # Count approved requests per equipment in range
  usages = Request.where(status: 'approved').where(approved_at: from.beginning_of_day..to.end_of_day)
  usage_counts = usages.group(:equipment_id).count

  @rows = Equipment.all.map do |e|
    { equipment: e, usages: usage_counts[e.id] || 0 }
  end

  respond_to = params['format']
  if respond_to == 'csv'
    content_type 'text/csv'
    attachment "utilization_#{from}_to_#{to}.csv"
    csv = CSV.generate do |csv|
      csv << ['Asset Tag','Name','Model','Usages']
      @rows.each do |r|
        csv << [r[:equipment].serial_number, r[:equipment].name, r[:equipment].model, r[:usages]]
      end
    end
    body csv
  else
    erb :'reports/utilization'
  end
end

get '/reports/depreciation' do
  # params: as_of, life_years
  as_of = params['as_of'] ? Date.parse(params['as_of']) : Date.today
  life_years = (params['life_years'] || 3).to_f

  @rows = Equipment.all.map do |e|
    price = e.purchase_price.to_f
    purchased = e.purchase_date || Date.today
    years = ((as_of - purchased).to_f / 365).round(2)
    years = 0 if years < 0
    depreciation = [years, life_years].min
    book = if life_years > 0
      price * (1 - (depreciation / life_years))
    else
      price
    end
    { equipment: e, purchase_price: price, years: years, book_value: book.round(2) }
  end

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "depreciation_#{as_of}.csv"
    csv = CSV.generate do |csv|
      csv << ['Asset Tag','Name','Model','Purchase Price','Years Since Purchase','Book Value']
      @rows.each do |r|
        csv << [r[:equipment].serial_number, r[:equipment].name, r[:equipment].model, sprintf('%.2f', r[:purchase_price]), r[:years], sprintf('%.2f', r[:book_value])]
      end
    end
    body csv
  else
    erb :'reports/depreciation'
  end
end

get '/reports/audit' do
  from = params['from'] ? Date.parse(params['from']) : (Date.today - 365)
  to = params['to'] ? Date.parse(params['to']) : Date.today
  @activities = Activity.where(created_at: from.beginning_of_day..to.end_of_day).order(created_at: :desc).limit(1000)

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "audit_#{from}_to_#{to}.csv"
    csv = CSV.generate do |csv|
      csv << ['When','Trackable','Action','User','Details']
      @activities.each do |a|
        csv << [a.created_at, a.trackable_type, a.action, a.user_name, a.changes_made]
      end
    end
    body csv
  else
    erb :'reports/audit'
  end
end

get '/settings' do
  erb :'settings'
end

# Endpoint to receive client-side JS errors for debugging
# client-side error reporting removed (no-op in production)

# Deploy route: show categories with quantity > 0 and allow assignment
get '/deploy' do
  require_at_least_semi!
  # categories that have total quantity > 0
  @categories = Equipment.group(:category).having('SUM(COALESCE(quantity,0)) > 0').pluck(:category).compact
  @equipments = Equipment.order(:name)
  erb :'deploy/new'
end

post '/deploy' do
  require_at_least_semi!
  cat = params['category']
  equipment_id = params['equipment_id']
  qty = (params['quantity'] || 0).to_i
  assignee = params['assignee_name']
  deploy_location = params['deploy_location']
  serial = params['serial_number']
  serials_struct = params['serials']

  if equipment_id && qty > 0
    equipment = Equipment.find_by(id: equipment_id)
    if equipment.nil?
      status 404
      return "Equipment not found"
    end
    if (equipment.quantity || 0) < qty
      status 422
      return "Not enough stock available"
    end

    # If assignee is a name that does not have a user account, create a normal user with a temporary password
    if assignee && !assignee.strip.empty?
      # derive a username from the assignee name
      base_username = assignee.strip.downcase.gsub(/[^0-9a-z]/i, '.')
      base_username = base_username.gsub(/\.{2,}/, '.').gsub(/^\.|\.$/, '')
      candidate = base_username
      suffix = 0
      while candidate.nil? || candidate.strip.empty? || User.exists?(username: candidate)
        suffix += 1
        candidate = "#{base_username}#{suffix}"
        # avoid infinite loop: if base_username empty, use 'user'
        if suffix > 1000
          candidate = "user#{Time.now.to_i}"
          break
        end
      end
      # If the candidate username doesn't exist, create the user and set a one-time temp password
      if !User.exists?(username: candidate)
        temp_pw = SecureRandom.urlsafe_base64(8).gsub(/[^0-9A-Za-z]/, '')[0,12]
        new_u = User.create!(username: candidate, password: temp_pw, role: 'normal', must_change_password: true, temporary_password: temp_pw)
        # store one-time temp password info in session so the admin can copy it from the next page
        session[:temp_password_for_user] = { 'id' => new_u.id, 'username' => new_u.username, 'password' => temp_pw }
        begin
          Activity.create!(trackable: new_u, action: 'user_created_by_deploy', user_name: session[:username] || 'system', changes_made: { generated_username: new_u.username }.to_json)
        rescue => _e
        end
      end
    end

    # Create a Request as the loan/deployment record
    # Build notes that include structured serials and purchase-date metadata when available
    note_parts = []
    deployed_units = []
    purchase_date_str = equipment.purchase_date ? equipment.purchase_date.to_s : nil

    if serials_struct && serials_struct.is_a?(Hash)
      # attach purchase_date to each component/unit if present
      begin
        parsed = serials_struct.dup
        # parsed may be nested; iterate values and attach purchase_date
        if parsed.values.all? { |v| v.is_a?(Hash) }
          parsed.each do |_k, unit_hash|
            unit_hash['purchase_date'] = purchase_date_str if purchase_date_str
            deployed_units << unit_hash.merge('assigned_to' => (assignee || ''))
          end
        else
          # flat hash: component=>serial
          parsed.each do |comp, serial_val|
            deployed_units << { 'component' => comp.to_s, 'serial' => serial_val.to_s, 'purchase_date' => purchase_date_str, 'assigned_to' => (assignee || '') }
          end
        end
      rescue => _e
      end
      note_parts << "component_serials: #{serials_struct.to_json}"
    elsif serial && !serial.strip.empty?
      deployed_units << { 'serial' => serial.strip, 'purchase_date' => purchase_date_str, 'assigned_to' => (assignee || '') }
      note_parts << "serial: #{serial}"
    else
      # No serials provided: create placeholders for count with purchase_date included
      qty.times do |i|
        deployed_units << { 'unit_index' => i+1, 'purchase_date' => purchase_date_str, 'assigned_to' => (assignee || '') }
      end
    end

    # add structured deployed_units JSON to notes so assignee can see purchase dates
    if deployed_units.any?
      note_parts << "deployed_units: #{deployed_units.to_json}"
    end

    rq = Request.new(
      equipment_id: equipment.id,
      quantity: qty,
      requester_name: assignee || 'Unknown',
      requested_at: Time.now,
      approved_at: Time.now,
      checkout_date: Date.today,
      expected_return_date: nil,
      status: 'approved',
      notes: (["Deployed to #{deploy_location}"] + note_parts).join(' ; ')
    )
    rq.save!

    equipment.quantity = (equipment.quantity || 0) - qty
    equipment.save!

    # Log activity
    begin
      Activity.create!(trackable_type: 'Equipment', trackable_id: equipment.id, action: 'deployed', user_name: assignee || 'system', changes_made: {deploy_location: deploy_location, quantity: qty, serial: serial}.to_json)
    rescue => _e
      # ignore logging errors
    end

    redirect '/requests'
  else
    status 422
    "Invalid deploy request"
  end
end

get '/equipments' do
  Equipment.reset_column_information
  @equipments = Equipment.order(:id)
  @categories = Equipment.distinct.pluck(:category).compact
  @locations = Equipment.distinct.pluck(:location).compact
  @statuses = Equipment.distinct.pluck(:status).compact
  erb :'equipments/index'
end

get '/equipments/new' do
  require_super_admin!
  Equipment.reset_column_information
  @equipment = Equipment.new
  @categories = Equipment.distinct.pluck(:category).compact
  @locations = Equipment.distinct.pluck(:location).compact
  @statuses = Equipment.distinct.pluck(:status).compact
  erb :'equipments/new'
end

post '/equipments' do
  require_super_admin!
  ep = (params[:equipment] || {})
  # if user provided 'other' typed values, prefer those
  ep['category'] = ep['category_other'] if ep['category_other'] && !ep['category_other'].strip.empty?
  ep['location'] = ep['location_other'] if ep['location_other'] && !ep['location_other'].strip.empty?
  # Remove transient form-only fields so ActiveRecord won't try to assign them
  ep.delete('category_other')
  ep.delete('location_other')
  @equipment = Equipment.new(ep)
  if @equipment.save
    redirect "/equipments/#{@equipment.id}?created=1"
  else
    @categories = Equipment.distinct.pluck(:category).compact
    @locations = Equipment.distinct.pluck(:location).compact
    @statuses = Equipment.distinct.pluck(:status).compact
    erb :'equipments/new'
  end
end

get '/equipments/:id' do
  Equipment.reset_column_information
  @equipment = Equipment.find(params[:id])
  begin
    hist = EquipmentHistory.where(equipment_id: @equipment.id)
    @history_counts = {
      total: hist.count,
      returned: hist.where(action: 'returned').count,
      damaged: hist.where(action: 'damaged').count,
      repairs: hist.where(action: 'under_repair').count + hist.where("details LIKE ?", "%repair%").count
    }
  rescue => _e
    @history_counts = { total: 0, returned: 0, damaged: 0, repairs: 0 }
  end
  erb :'equipments/show'
end

get '/equipments/:id/history' do
  require_super_admin!
  Equipment.reset_column_information
  @equipment = Equipment.find(params[:id])

  # filters
  serial_q = params['serial']&.strip
  user_id = params['user_id'] && params['user_id'].to_i > 0 ? params['user_id'].to_i : nil
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil

  q = EquipmentHistory.where(equipment_id: @equipment.id)
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to
  q = q.where(user_id: user_id) if user_id
  if serial_q && !serial_q.empty?
    # simple JSON-like substring match on details for serial (best-effort)
    q = q.where('details LIKE ?', "%\"serial\":%#{serial_q}%")
  end

  @histories = q.order(occurred_at: :desc).limit(1000)
  @users = User.order(:username)
  # Summary counts for this equipment's lifecycle
  begin
    all_hist = EquipmentHistory.where(equipment_id: @equipment.id)
    @summary = {
      total_events: all_hist.count,
      assigned: all_hist.where(action: 'assigned').count,
      returned: all_hist.where(action: 'returned').count,
      damaged: all_hist.where(action: 'damaged').count,
      under_repair: all_hist.where(action: 'under_repair').count,
      other_status_changes: all_hist.where(action: 'status_change').count
    }
  rescue => _e
    @summary = { total_events: 0 }
  end
  erb :'equipments/history'
end

# Super-admin index of equipment histories (recent / searchable)
get '/equipment_histories' do
  require_super_admin!
  serial_q = params['serial']&.strip
  equipment_id = params['equipment_id'] && params['equipment_id'].to_i > 0 ? params['equipment_id'].to_i : nil
  user_id = params['user_id'] && params['user_id'].to_i > 0 ? params['user_id'].to_i : nil
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil

  q = EquipmentHistory.all
  q = q.where(equipment_id: equipment_id) if equipment_id
  q = q.where(user_id: user_id) if user_id
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to
  if serial_q && !serial_q.empty?
    q = q.where('details LIKE ?', "%\"serial\":%#{serial_q}%")
  end
  if params['action'] && !params['action'].to_s.strip.empty?
    q = q.where(action: params['action'].to_s.strip)
  end

  @histories = q.order(occurred_at: :desc).limit(1000)
  @equipments = Equipment.order(:name)
  @users = User.order(:username)
  erb :'equipment_histories/index'
end

get '/equipments/:id/edit' do
  require_super_admin!
  Equipment.reset_column_information
  @equipment = Equipment.find(params[:id])
  @categories = Equipment.distinct.pluck(:category).compact
  @locations = Equipment.distinct.pluck(:location).compact
  @statuses = Equipment.distinct.pluck(:status).compact
  erb :'equipments/edit'
end

put '/equipments/:id' do
  require_super_admin!
  @equipment = Equipment.find(params[:id])
  ep = (params[:equipment] || {})
  ep['category'] = ep['category_other'] if ep['category_other'] && !ep['category_other'].strip.empty?
  ep['location'] = ep['location_other'] if ep['location_other'] && !ep['location_other'].strip.empty?
  # Remove transient form-only fields so ActiveRecord won't try to assign them
  ep.delete('category_other')
  ep.delete('location_other')
  if @equipment.update(ep)
    redirect "/equipments/#{@equipment.id}"
  else
    @categories = Equipment.distinct.pluck(:category).compact
    @locations = Equipment.distinct.pluck(:location).compact
    @statuses = Equipment.distinct.pluck(:status).compact
    erb :'equipments/edit'
  end
end

delete '/equipments/:id' do
  require_super_admin!
  Equipment.find(params[:id]).destroy
  redirect '/equipments'
end

# API endpoints
get '/api/equipments' do
  content_type :json
  Equipment.all.to_json
end

get '/api/equipments/:id' do
  content_type :json
  Equipment.find(params[:id]).to_json
end
