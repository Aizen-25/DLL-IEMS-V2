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
require 'uri'
require 'fileutils'
require 'zlib'
require 'open3'
require 'tmpdir'
require 'yaml'
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
# Ensure SESSION_SECRET is present and at least 64 bytes long.
# Rack/session requires a sufficiently long secret; fail-fast with a clear
# message so the deploy logs show the problem instead of obscure runtime errors.
secret = ENV['SESSION_SECRET'] || 'inventory_system_secret_key_change_in_production_minimum_64_bytes_required_for_security'
if secret.to_s.length < 64
  STDERR.puts "FATAL: SESSION_SECRET is missing or too short (#{secret.to_s.length} chars). Set SESSION_SECRET to at least 64 bytes."
  raise "SESSION_SECRET must be set to at least 64 bytes"
end
set :session_secret, secret

# Path to store legacy migration metadata and exports
LEGACY_CONFIG_PATH = File.join(Dir.pwd, 'tmp', 'legacy_migration.yml')
LEGACY_EXPORT_DIR = File.join(Dir.pwd, 'tmp', 'db_exports')
FileUtils.mkdir_p(LEGACY_EXPORT_DIR) unless Dir.exist?(LEGACY_EXPORT_DIR)

def read_legacy_config
  if File.exist?(LEGACY_CONFIG_PATH)
    YAML.load_file(LEGACY_CONFIG_PATH) || {}
  else
    {}
  end
end

def write_legacy_config(hash)
  FileUtils.mkdir_p(File.dirname(LEGACY_CONFIG_PATH))
  File.write(LEGACY_CONFIG_PATH, hash.to_yaml)
end

def create_db_export_file(prefix = 'db_export')
  now = Time.now.utc.strftime('%Y%m%d%H%M%S')
  fname = "#{prefix}_#{now}.json"
  path = File.join(LEGACY_EXPORT_DIR, fname)
  tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
  payload = {}
  tables.each do |t|
    begin
      rows = ActiveRecord::Base.connection.exec_query("SELECT * FROM #{ActiveRecord::Base.connection.quote_table_name(t)}").to_a
      payload[t] = rows
    rescue => e
      payload[t] = { 'error' => e.message }
    end
  end
  File.write(path, JSON.pretty_generate(payload))
  fname
end

def reset_serial_sequences(tables = nil)
  conn = ActiveRecord::Base.connection
  begin
    rows = conn.exec_query(<<~SQL)
      SELECT table_name, column_name
      FROM information_schema.columns
      WHERE column_default LIKE 'nextval(%' AND table_schema='public'
    SQL

    rows.each do |r|
      table = r['table_name']
      col = r['column_name']
      next if tables && !tables.include?(table)
      begin
        # set sequence to max(id) so nextval returns max+1
        conn.execute("SELECT setval(pg_get_serial_sequence('" + table + "','" + col + "'), COALESCE((SELECT MAX(" + col + ") FROM " + table + "),0), true)")
      rescue => e
        STDERR.puts "Failed to reset sequence for #{table}.#{col}: #{e.message}"
      end
    end
  rescue => e
    STDERR.puts "Failed to query sequences: #{e.message}"
  end
end

def perform_auto_export(prefix = 'auto_export')
  begin
    fname = create_db_export_file(prefix)
    src = File.join(LEGACY_EXPORT_DIR, fname)
    gz_path = "#{src}.gz"

    # record export in legacy config (so UI shows it)
    cfg = read_legacy_config
    cfg['auto_exported_file'] = File.basename(src)
    cfg['auto_exported_at'] = Time.now.utc.iso8601
    write_legacy_config(cfg)

    uploaded = false
    upload_msg = nil
    if ENV['GITHUB_TOKEN'] && ENV['GITHUB_REPO']
      ok, upload_msg = upload_file_to_github_repo(src)
      uploaded = ok
      if ok
        cfg['uploaded_to_repo'] = ENV['GITHUB_REPO']
        cfg['uploaded_at'] = Time.now.utc.iso8601
        cfg['uploaded_file'] = File.basename(src)
        write_legacy_config(cfg)
      end
    end

    # gzip the JSON locally for storage
    begin
      Zlib::GzipWriter.open(gz_path) do |gz|
        gz.write(File.read(src))
      end
    rescue => e
      return [false, "Failed to gzip export: #{e.message}"]
    end

    # Attempt to upload the gzipped JSON to GitHub repo if configured
    if ENV['GITHUB_TOKEN'] && ENV['GITHUB_REPO']
      ok2, msg2 = upload_file_to_github_repo(gz_path)
      if ok2
        cfg = read_legacy_config
        cfg['uploaded_to_repo'] = ENV['GITHUB_REPO']
        cfg['uploaded_at'] = Time.now.utc.iso8601
        write_legacy_config(cfg)
        uploaded = true
        upload_msg = msg2
      else
        upload_msg = [upload_msg, msg2].compact.join('; ')
      end
    end

    return [true, "Automatic backup created: #{File.basename(src)}" + (uploaded ? " and uploaded to repo" : " (not uploaded)") + (upload_msg && !upload_msg.empty? ? ": #{upload_msg}" : "")]
  rescue => e
    return [false, "Failed to run automatic backup: #{e.message}"]
  end
end

def check_and_trigger_auto_export
  cfg = read_legacy_config
  expiry = cfg['expiry_date']
  exported = cfg['auto_exported_file']
  return unless expiry
  begin
    expiry_date = Date.parse(expiry.to_s)
  rescue
    return
  end

  today = Date.today
  # Trigger automatic export when the expiry date is reached (or passed)
  if today >= expiry_date && exported.to_s.strip.empty?
    # use the central perform_auto_export so expiry triggers same full flow
    ok, msg = perform_auto_export('auto_export')
    unless ok
      STDERR.puts "Auto export on expiry failed: #{msg}"
    end
  end
end

# Start a background thread to check expiry once per day
Thread.new do
  loop do
    begin
      check_and_trigger_auto_export
    rescue => e
      STDERR.puts "Legacy export checker failed: #{e.message}"
    end
    sleep 60 * 60 * 24
  end
end

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
  
  # HTML-escape helper for views (`h` is a common helper in ERB)
  def h(text)
    ERB::Util.html_escape(text.to_s)
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
  category_q = params['category']

  @pending_requests = Request.pending.order(created_at: :desc)

  # If user requested to view pending returns, show those; otherwise show active approved loans
  if params['filter'] == 'pending_return' || params['filter'] == 'pending_returns'
    loans = Request.where(status: 'pending_return')
  else
    loans = Request.approved.where(returned_at: nil)
  end
  loans = loans.joins(:equipment).where('equipments.name LIKE ?', "%#{equipment_q}%") if equipment_q && !equipment_q.strip.empty?
  loans = loans.joins(:equipment).where('equipments.category = ?', category_q) if category_q && !category_q.strip.empty?
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

  # Pagination: show 7 entries per page for deployed list
  per_page = 7
  page = (params['page'] || '1').to_i
  page = 1 if page < 1
  total_count = loans.count
  total_pages = (total_count / per_page.to_f).ceil
  offset = (page - 1) * per_page
  @page = page
  @total_pages = total_pages
  @total_loans = total_count
  @current_loans = loans.order(checkout_date: :desc).offset(offset).limit(per_page)
  # one-time temp password info (set after deploy auto-create or force-reset)
  @categories = Equipment.distinct.pluck(:category).compact
  @temp_password_info = session.delete(:temp_password_for_user)
  erb :'requests'
end

# Show a single request (deployment/loan) details
get '/requests/:id' do
  @request = Request.find_by(id: params[:id])
  halt 404, "Request not found" unless @request
  # load associated user equipments for this request
  @user_equipments = UserEquipment.where(request_id: @request.id)
  erb :'requests_show'
end

# Edit a deployed unit (semi-admins and up)
get '/user_equipments/:id/edit' do
  require_at_least_semi!
  @ue = UserEquipment.find_by(id: params[:id])
  halt 404, "UserEquipment not found" unless @ue
  erb :'user_equipments/edit'
end

# Update deployed unit details
post '/user_equipments/:id' do
  require_at_least_semi!
  ue = UserEquipment.find_by(id: params[:id])
  halt 404, "UserEquipment not found" unless ue
  begin
    # permit a small set of editable fields
    ue.serial = params['serial'] if params.key?('serial')
    if params['assigned_at'] && !params['assigned_at'].to_s.strip.empty?
      ue.assigned_at = Date.parse(params['assigned_at'].to_s) rescue ue.assigned_at
    end
    if params['returned_at'] && !params['returned_at'].to_s.strip.empty?
      ue.returned_at = Date.parse(params['returned_at'].to_s) rescue ue.returned_at
    end
    ue.save!
    begin
      Activity.create!(trackable: ue, action: 'user_equipment_updated', user_name: current_user&.username || 'system', changes_made: ue.attributes.to_json)
    rescue => _e
    end
    redirect back
  rescue => e
    @error = "Failed to update: #{e.message}"
    @ue = ue
    erb :'user_equipments/edit'
  end
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

    # Also update the equipment's status (this represents the physical item's condition)
    # Do NOT change the Request lifecycle/status here (that would remove it from deployed lists).
    begin
      if rq.equipment
        eq = rq.equipment
        prev_status = eq.status
        # Only update if the status meaningfully changed
        if prev_status.to_s.downcase != new_status.to_s.downcase
          eq.status = new_status
          eq.save!
          begin
            Activity.create!(trackable: eq, action: 'status_change', user_name: (current_user && current_user.username) || 'system', changes_made: { from: prev_status, to: new_status, request_id: rq.id, diagnostic: diagnostic }.to_json)
          rescue => _e
          end
          begin
            EquipmentHistory.create!(equipment: eq, user: current_user, request: rq, action: 'status_change', details: { from: prev_status, to: new_status, diagnostic: diagnostic }.to_json, occurred_at: Time.now)
          rescue => _e
          end
        end
      end
    rescue => _e
      # ignore equipment update failures to avoid breaking the admin flow
    end

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
        EquipmentHistory.create!(equipment: rq.equipment, user: nil, request: rq, action: 'status_change', details: { status: new_status, diagnostic: diagnostic }.to_json, occurred_at: Time.now)
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
  # the reports index will render available reports and a filter
  # If preview=1 is present, prepare small preview snippets for each card
  if params['preview'] && params['preview'].to_s == '1'
    from, to = parse_date_range(params)
    # Deployed by category preview: top 3 categories
    begin
      ds = Request.where(status: 'approved')
      ds = ds.where('approved_at >= ?', from.beginning_of_day) if from
      ds = ds.where('approved_at <= ?', to.end_of_day) if to
      raw = ds.joins(:equipment).group('equipments.category').sum(:quantity)
      @deployed_preview = raw.sort_by { |_,v| -v }.first(3).map { |k,v| { name: (k||'Uncategorized'), value: v } }
    rescue => _e
      @deployed_preview = []
    end

    # Top assignees preview: top 3 users by approved requests
    begin
      ta = Request.where(status: 'approved').joins(:user).group('users.id','users.name').sum(:quantity)
      @assignees_preview = ta.sort_by { |_,v| -v }.first(3).map { |(uid,name),v| { name: (name || 'Unknown'), value: v } }
    rescue => _e
      @assignees_preview = []
    end

    # Average deployment duration preview: compute average days for completed requests
    begin
      durations = Request.where.not(approved_at: nil).where.not(returned_at: nil).pluck(Arel.sql("julianday(returned_at) - julianday(approved_at)"))
      avg = durations.compact.map(&:to_f).reject { |d| d.nan? }.then { |arr| arr.any? ? (arr.sum / arr.size) : nil }
      @avg_duration_preview = avg ? (avg.round(1)) : nil
    rescue => _e
      @avg_duration_preview = nil
    end

    # Warranty expiring preview: count expiring within 90 days
    begin
      today = Date.today
      cutoff = today + 90
      wp = Equipment.where.not(warranty_expires_at: nil).where('warranty_expires_at BETWEEN ? AND ?', today, cutoff).limit(3)
      @warranty_preview = wp.map { |e| { name: e.name || e.model || e.serial_number, expires: e.warranty_expires_at } }
    rescue => _e
      @warranty_preview = []
    end

    # Assets by location preview: top 3 locations
    begin
      locs = Equipment.group(:location).sum(:quantity)
      @location_preview = locs.sort_by { |_,v| -v }.first(3).map { |k,v| { name: (k || 'Unspecified'), value: v } }
    rescue => _e
      @location_preview = []
    end

    # Top problematic equipment preview: equipments with status maintenance/damaged
    begin
      @problem_preview = Equipment.where(status: ['maintenance','damaged']).order(updated_at: :desc).limit(3).map { |e| { name: e.name || e.model || e.serial_number, status: e.status } }
    rescue => _e
      @problem_preview = []
    end
  end

  erb :'reports/index'
end

# Helper to parse date range params (from/to/year)
def parse_date_range(params)
  from = params['from'] ? (Date.parse(params['from']) rescue nil) : nil
  to = params['to'] ? (Date.parse(params['to']) rescue nil) : nil
  if params['year'] && !params['year'].to_s.strip.empty?
    y = params['year'].to_i
    from ||= Date.new(y,1,1) rescue nil
    to ||= Date.new(y,12,31) rescue nil
  end
  return from, to
end

# Report: deployed by category
get '/reports/deployed_by_category' do
  from, to = parse_date_range(params)
  @report_title = 'Deployed by Category'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  scope = Request.where(status: 'approved')
  scope = scope.where('approved_at >= ?', from.beginning_of_day) if from
  scope = scope.where('approved_at <= ?', to.end_of_day) if to
  raw = scope.joins(:equipment).group('equipments.category').sum(:quantity)
  @table_columns = ['Category','Count']
  @table_rows = raw.map { |cat,cnt| { 'Category': (cat || 'Uncategorized'), 'Count': cnt } }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "deployed_by_category_#{@report_as_of}.csv"
    csv = CSV.generate do |csv|
      csv << @table_columns
      @table_rows.each { |r| csv << [r[:Category], r[:Count]] }
    end
    body csv
  else
    erb :'reports/show'
  end
end

# Interactive analytics page: three filterable charts
get '/reports/analytics' do
  from, to = parse_date_range(params)
  @report_title = 'Interactive Analytics'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  # Deployed by category (approved, not returned within range)
  deployed_scope = Request.where(status: 'approved')
  deployed_scope = deployed_scope.where('approved_at >= ?', from.beginning_of_day) if from
  deployed_scope = deployed_scope.where('approved_at <= ?', to.end_of_day) if to
  @deployed_by_category = deployed_scope.joins(:equipment).group('equipments.category').sum(:quantity)

  # Equipment distribution by category (inventory counts)
  # Sum quantities per equipment category (use 0 when NULL)
  begin
    @equipment_by_category = Equipment.group(:category).sum(:quantity)
  rescue => _e
    @equipment_by_category = {}
  end

  # Office distribution (Deployed location parsed from notes)
  deployed_loc_counts = Hash.new(0)
  deployed_scope.find_each do |rq|
    loc = nil
    if rq.notes && rq.notes.match(/Deployed to\s*([^;\n]+)/i)
      loc = rq.notes.match(/Deployed to\s*([^;\n]+)/i)[1].to_s.strip
    end
    # If a category filter is provided, skip requests for other categories
    if params['category'] && !params['category'].to_s.strip.empty?
      begin
        eq_cat = rq.equipment && rq.equipment.category
        next unless eq_cat && eq_cat.to_s == params['category'].to_s
      rescue => _e
      end
    end
    loc ||= (rq.equipment && rq.equipment.location)
    loc = (loc.nil? || loc.to_s.strip.empty?) ? 'Unspecified' : loc.to_s
    deployed_loc_counts[loc] += (rq.quantity || 1)
  end
  @office_distribution = deployed_loc_counts

  # Request status counts for analytics (summary of request lifecycle statuses)
  begin
    @request_status_counts = Request.group(:status).count.transform_keys { |k| k || 'Unspecified' }
  rescue => _e
    @request_status_counts = {}
  end

  # Equipment condition counts (working / under repair / damaged etc.) for analytics
  begin
    @equipment_status_counts = Equipment.group(:status).count.transform_keys { |k| k || 'Unspecified' }
  rescue => _e
    @equipment_status_counts = {}
  end

  # Status over time: aggregate EquipmentHistory status_change counts by month
  q = EquipmentHistory.where(action: 'status_change')
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to
  status_by_month = Hash.new { |h,k| h[k] = Hash.new(0) }
  q.find_each do |h|
    d = (h.occurred_at || h.created_at).to_date rescue nil
    next unless d
    m = d.strftime('%Y-%m')
    details = (begin; JSON.parse(h.details) rescue {}; end)
    new_status = (details['to'] || details['status'] || details['new_status'] || 'unknown')
    status_by_month[m][new_status] += 1
  end
  @status_by_month = status_by_month

  # Problematic brands: count status_change events where new status indicates problems
  begin
    problem_statuses = ['maintenance','under repair','damaged','repair']
    brand_counts = Hash.new(0)
    q2 = EquipmentHistory.where(action: 'status_change')
    q2 = q2.where('occurred_at >= ?', from.beginning_of_day) if from
    q2 = q2.where('occurred_at <= ?', to.end_of_day) if to
    q2.find_each do |h|
      begin
        details = (JSON.parse(h.details) rescue {})
        new_status = (details['to'] || details['status'] || details['new_status'] || '').to_s.downcase
        next unless new_status && problem_statuses.include?(new_status)
        # prefer associated equipment brand
        if h.respond_to?(:equipment) && h.equipment && h.equipment.respond_to?(:brand)
          brand = h.equipment.brand.to_s.strip
        else
          # try to look up equipment by id
          brand = ''
          if h.equipment_id
            eq = Equipment.find_by(id: h.equipment_id)
            brand = (eq&.brand || '').to_s.strip
          end
        end
        brand = 'Unknown' if brand.nil? || brand.to_s.strip.empty?
        brand_counts[brand] += 1
      rescue => _e
      end
    end
    # sort descending and keep as ordered hash
    @problem_brands = brand_counts.sort_by { |_,c| -c }.to_h
  rescue => _e
    @problem_brands = {}
  end

  erb :'reports/analytics'
end

# Equipment Repair listing: show equipments currently marked under repair or damaged
get '/repairs' do
  # show equipments whose status indicates a problem
  problem_statuses = ['under repair','damaged','repair','maintenance']
  begin
    @repairs = Equipment.where(status: problem_statuses).order(updated_at: :desc)
  rescue => _e
    # fallback: safe empty array
    @repairs = []
  end

  erb :'repairs'
end

# Report: office distribution (deployed locations) - HTML table or CSV
get '/reports/office_distribution' do
  from, to = parse_date_range(params)
  @report_title = 'Office Distribution'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  deployed_scope = Request.where(status: 'approved')
  deployed_scope = deployed_scope.where('approved_at >= ?', from.beginning_of_day) if from
  deployed_scope = deployed_scope.where('approved_at <= ?', to.end_of_day) if to

  deployed_loc_counts = Hash.new(0)
  deployed_scope.find_each do |rq|
    loc = nil
    if rq.notes && rq.notes.match(/Deployed to\s*([^;\n]+)/i)
      loc = rq.notes.match(/Deployed to\s*([^;\n]+)/i)[1].to_s.strip
    end
    # Apply optional category filter (matches equipment.category)
    if params['category'] && !params['category'].to_s.strip.empty?
      begin
        eq_cat = rq.equipment && rq.equipment.category
        next unless eq_cat && eq_cat.to_s == params['category'].to_s
      rescue => _e
      end
    end
    loc ||= (rq.equipment && rq.equipment.location)
    loc = (loc.nil? || loc.to_s.strip.empty?) ? 'Unspecified' : loc.to_s
    deployed_loc_counts[loc] += (rq.quantity || 1)
  end

  @table_columns = ['Location','Count']
  @table_rows = deployed_loc_counts.map { |loc,c| { 'Location': loc, 'Count': c } }.sort_by { |r| -r[:Count] }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "office_distribution_#{@report_as_of}.csv"
    csv = CSV.generate do |csv_out|
      csv_out << @table_columns
      @table_rows.each { |r| csv_out << [r[:Location], r[:Count]] }
    end
    body csv
  elsif params['format'] == 'json' || request.xhr?
    content_type :json
    # return a simple hash of location => count
    deployed_loc_counts.to_json
  else
    erb :'reports/show'
  end
end

# Report: Top problematic equipment (most frequently reported damaged/under repair)
get '/reports/top_problem_equipment' do
  from, to = parse_date_range(params)
  @report_title = 'Top Problematic Equipment'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  problem_statuses = ['maintenance', 'under repair', 'damaged']

  q = EquipmentHistory.where(action: 'status_change')
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to

  counts = Hash.new(0)
  q.find_each do |h|
    begin
      details = (JSON.parse(h.details) rescue {})
      new_status = (details['to'] || details['status'] || details['new_status']).to_s.downcase
      if new_status && problem_statuses.include?(new_status)
        if h.equipment_id
          counts[h.equipment_id] += 1
        elsif h.equipment
          counts[h.equipment.id] += 1
        end
      end
    rescue => _e
    end
  end

  rows = counts.map do |eq_id, cnt|
    eq = Equipment.find_by(id: eq_id)
    { equipment_id: eq_id, name: (eq ? eq.name : "Unknown (#{eq_id})"), model: (eq&.model || ''), count: cnt }
  end.sort_by { |r| -r[:count] }

  @table_columns = ['Equipment','Model','Count']
  @table_rows = rows.map { |r| { 'Equipment': r[:name], 'Model': r[:model], 'Count': r[:count] } }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "top_problem_equipment_#{@report_as_of}.csv"
    csv = CSV.generate do |csv_out|
      csv_out << @table_columns
      @table_rows.each { |r| csv_out << [r[:Equipment], r[:Model], r[:Count]] }
    end
    body csv
  else
    erb :'reports/top_problem_equipment'
  end
end

# Report: top assignees
get '/reports/top_assignees' do
  from, to = parse_date_range(params)
  @report_title = 'Top Assignees'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  scope = Request.where(status: 'approved')
  scope = scope.where('approved_at >= ?', from.beginning_of_day) if from
  scope = scope.where('approved_at <= ?', to.end_of_day) if to
  rows = scope.group(:requester_name).sum(:quantity)
  @table_columns = ['Assignee','Count']
  @table_rows = rows.map { |name,cnt| { 'Assignee': name, 'Count': cnt } }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "top_assignees_#{@report_as_of}.csv"
    csv = CSV.generate do |csv|
      csv << @table_columns
      @table_rows.each { |r| csv << [r[:Assignee], r[:Count]] }
    end
    body csv
  else
    erb :'reports/show'
  end
end

# Report: average deployment duration
get '/reports/avg_deployment_duration' do
  from, to = parse_date_range(params)
  @report_title = 'Average Deployment Duration (days)'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  scope = Request.where(status: 'returned')
  scope = scope.where('returned_at IS NOT NULL AND checkout_date IS NOT NULL')
  scope = scope.where('checkout_date >= ?', from) if from
  scope = scope.where('returned_at <= ?', to) if to
  durations = scope.map { |r| (r.returned_at - r.checkout_date).to_i rescue nil }.compact
  avg = durations.any? ? (durations.sum.to_f / durations.size).round(1) : 0
  @table_columns = ['Metric','Value']
  @table_rows = [{ 'Metric': 'Average Days', 'Value': avg }, { 'Metric': 'Count Samples', 'Value': durations.size }]

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "avg_deployment_duration_#{@report_as_of}.csv"
    csv = CSV.generate do |csv|
      csv << @table_columns
      @table_rows.each { |r| csv << [r[:Metric], r[:Value]] }
    end
    body csv
  else
    erb :'reports/show'
  end
end

# Report: warranty expiring
get '/reports/warranty_expiring' do
  from, to = parse_date_range(params)
  @report_title = 'Warranty Expiring'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'Next 90 days')

  # default to 90 days if no range
  if from.nil? && to.nil?
    from = Date.today
    to = Date.today + 90
  end

  eqs = Equipment.where('warranty_until IS NOT NULL')
  eqs = eqs.where('warranty_until >= ? AND warranty_until <= ?', from, to)
  @table_columns = ['Asset Tag','Name','Model','Warranty Until']
  @table_rows = eqs.map { |e| { 'Asset Tag': e.serial_number || '', 'Name': e.name, 'Model': e.model, 'Warranty Until': (e.warranty_until || '') } }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "warranty_expiring_#{@report_as_of}.csv"
    csv = CSV.generate do |csv|
      csv << @table_columns
      @table_rows.each { |r| csv << [r[:'Asset Tag'], r[:Name], r[:Model], r[:'Warranty Until']] }
    end
    body csv
  else
    erb :'reports/show'
  end
end

# Report: status changes over time (uses EquipmentHistory)
get '/reports/status_over_time' do
  from, to = parse_date_range(params)
  @report_title = 'Status Changes Over Time'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  q = EquipmentHistory.where(action: 'status_change')
  q = q.where('occurred_at >= ?', from.beginning_of_day) if from
  q = q.where('occurred_at <= ?', to.end_of_day) if to
  # group by date and status
  rows = q.map do |h|
    d = (h.occurred_at || h.created_at).to_date rescue nil
    details = (begin; JSON.parse(h.details) rescue {}; end)
    new_status = (details['to'] || details['status'] || details['new_status'])
    { date: d, status: new_status }
  end.compact
  summary = {}
  rows.each do |r|
    key = [r[:date].to_s, r[:status].to_s]
    summary[key] = (summary[key] || 0) + 1
  end
  @table_columns = ['Date','Status','Count']
  @table_rows = summary.map { |(date,status),cnt| { 'Date': date, 'Status': status, 'Count': cnt } }.sort_by { |r| [r[:Date].to_s, r[:Status].to_s] }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "status_over_time_#{@report_as_of}.csv"
    csv = CSV.generate do |csv|
      csv << @table_columns
      @table_rows.each { |r| csv << [r[:Date], r[:Status], r[:Count]] }
    end
    body csv
  else
    erb :'reports/show'
  end
end

# Report: assets by location
get '/reports/assets_by_location' do
  from, to = parse_date_range(params)
  @report_title = 'Assets by Location'
  @report_as_of = to || Date.today
  @report_filter_label = from && to ? "#{from} to #{to}" : (params['year'] ? params['year'] : 'All')

  rows = Equipment.group(:location).count
  @table_columns = ['Location','Count']
  @table_rows = rows.map { |loc,c| { 'Location': (loc || 'Unspecified'), 'Count': c } }

  if params['format'] == 'csv'
    content_type 'text/csv'
    attachment "assets_by_location_#{@report_as_of}.csv"
    csv = CSV.generate do |csv|
      csv << @table_columns
      @table_rows.each { |r| csv << [r[:Location], r[:Count]] }
    end
    body csv
  else
    erb :'reports/show'
  end
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

# Database management: export/import JSON (super-admin only)
get '/database_manage' do
  require_super_admin!
  # Provide expiry status and list available exports
  cfg = read_legacy_config
  @expiry_date = cfg['expiry_date']
  if @expiry_date
    begin
      ed = Date.parse(@expiry_date.to_s)
      days_left = (ed - Date.today).to_i
      @days_left = days_left
      @expiry_status = "Legacy DB expires on #{ed.iso8601} (#{days_left} days left)"
    rescue
      @expiry_status = "Invalid expiry date configured"
    end
  end
  @auto_export_file = cfg['auto_exported_file']
  @exports = Dir.glob(File.join(LEGACY_EXPORT_DIR, '*.json')).map { |p| File.basename(p) }.sort.reverse

  erb :'database_manage/index'
end

get '/database_manage/export' do
  require_super_admin!
  # Create export file on disk and return it as download
  fname = create_db_export_file('manual_export')
  path = File.join(LEGACY_EXPORT_DIR, fname)
  content_type 'application/json'
  attachment fname
  File.read(path)
end

post '/database_manage/import' do
  require_super_admin!
  unless params[:file] && params[:file][:tempfile]
    @error = 'No file uploaded'
    return erb :'database_manage/index'
  end

  begin
    data = JSON.parse(params[:file][:tempfile].read)
  rescue => e
    @error = "Failed to parse JSON: #{e.message}"
    return erb :'database_manage/index'
  end

  conn = ActiveRecord::Base.connection
  begin
    conn.transaction do
      data.each do |table, rows|
        next if ['schema_migrations', 'ar_internal_metadata'].include?(table)
        # Ensure rows is an array
        unless rows.is_a?(Array)
          raise "Invalid data for table #{table}"
        end

        # Truncate table and reset identity
        conn.execute("TRUNCATE TABLE #{conn.quote_table_name(table)} RESTART IDENTITY CASCADE")

        rows.each do |row|
          cols = row.keys.map { |c| conn.quote_column_name(c) }
          vals = row.values.map { |v| conn.quote(v) }
          sql = "INSERT INTO #{conn.quote_table_name(table)} (#{cols.join(',')}) VALUES (#{vals.join(',')})"
          conn.execute(sql)
        end
      end
    end
    @success = 'Import completed successfully.'

    # After import, reset serial/identity sequences for imported tables (Postgres only)
    begin
      if conn.adapter_name.to_s.downcase.include?('postg')
        reset_serial_sequences(data.keys)
        @success += ' DB sequences reset.'
      end
    rescue => e
      STDERR.puts "Failed to reset sequences after import: #{e.message}"
      @success += " (Warning: failed to reset DB sequences: #{e.message})"
    end
    # Record import date (day 1) and set expiry = import_date + 28 days
    begin
      cfg = read_legacy_config
      import_date = Date.today
      expiry_date = (import_date + 28).iso8601
      cfg['import_date'] = import_date.iso8601
      cfg['expiry_date'] = expiry_date
      # reset any previous auto-export markers so a fresh export can occur on expiry
      cfg['auto_exported_file'] = nil
      cfg.delete('auto_exported_at')
      write_legacy_config(cfg)
      @success += " Import recorded: day1=#{import_date.iso8601}, expiry=#{expiry_date}."
    rescue => e
      @error = "Import succeeded but failed to record import/expiry: #{e.message}"
    end
  rescue => e
    @error = "Import failed: #{e.message}"
  end

  erb :'database_manage/index'
end

# Download saved export file
get '/database_manage/download/:file' do |file|
  require_super_admin!
  safe = File.basename(file)
  path = File.join(LEGACY_EXPORT_DIR, safe)
  unless File.exist?(path)
    status 404
    return "File not found"
  end
  content_type 'application/json'
  attachment safe
  File.read(path)
end

# Manual trigger to run the automatic-style export (for testing)
post '/database_manage/run_backup' do
  require_super_admin!
  begin
    # create json export
    fname = create_db_export_file('auto_export')
    src = File.join(LEGACY_EXPORT_DIR, fname)
    gz_path = "#{src}.gz"
    # record export in legacy config (so UI shows it)
    cfg = read_legacy_config
    cfg['auto_exported_file'] = File.basename(src)
    cfg['auto_exported_at'] = Time.now.utc.iso8601
    write_legacy_config(cfg)

    # Attempt to upload the raw JSON to GitHub backup repo if configured
    uploaded = false
    upload_msg = nil
    if ENV['GITHUB_TOKEN'] && ENV['GITHUB_REPO']
      ok, upload_msg = upload_file_to_github_repo(src)
      uploaded = ok
      if ok
        cfg['uploaded_to_repo'] = ENV['GITHUB_REPO']
        cfg['uploaded_at'] = Time.now.utc.iso8601
        cfg['uploaded_file'] = File.basename(src)
        write_legacy_config(cfg)
      end
    end

    # gzip the JSON locally for storage
    Zlib::GzipWriter.open(gz_path) do |gz|
      gz.write(File.read(src))
    end

    @success = "Automatic backup created: #{File.basename(src)}"
    @success += uploaded ? " and uploaded to repo" : " (not uploaded to repo)"
    @success += ": #{upload_msg}" if upload_msg && !upload_msg.empty?
  rescue => e
    @error = "Failed to run automatic backup: #{e.message}"
  end
  redirect '/database_manage'
end


def upload_file_to_github_repo(path)
  token = ENV['GITHUB_TOKEN']
  repo = ENV['GITHUB_REPO']
  unless token && repo && !token.to_s.strip.empty?
    return [false, 'GITHUB_TOKEN or GITHUB_REPO not set']
  end

  begin
    Dir.mktmpdir('backup_push') do |td|
      repo_dir = File.join(td, 'repo')
      FileUtils.mkdir_p(repo_dir)
      Dir.chdir(repo_dir) do
        # Initialize a small git repo and push the backup file into a backups branch
        Open3.capture3('git', 'init')
        Open3.capture3('git', 'config', 'user.name', 'auto-backup')
        Open3.capture3('git', 'config', 'user.email', 'auto-backup@example.com')
        FileUtils.mkdir_p('backups')
        dest = File.join('backups', File.basename(path))
        FileUtils.cp(path, dest)
        Open3.capture3('git', 'add', '.')
        Open3.capture3('git', 'commit', '-m', "Add backup #{File.basename(path)}")
        remote_url = "https://x-access-token:#{token}@github.com/#{repo}.git"
        Open3.capture3('git', 'remote', 'add', 'origin', remote_url)
        out, err, st = Open3.capture3('git', 'push', 'origin', 'HEAD:refs/heads/backups')
        if st.success?
          return [true, out.to_s.strip]
        else
          return [false, err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip]
        end
      end
    end
  rescue => e
    return [false, e.message]
  end
end

# Set legacy expiry date (YYYY-MM-DD)
post '/database_manage/set_expiry' do
  require_super_admin!
  date = params['expiry_date']
  begin
    Date.parse(date.to_s)
  rescue => e
    @error = "Invalid date: #{e.message}"
    return erb :'database_manage/index'
  end
  cfg = read_legacy_config
  cfg['expiry_date'] = date
  # Reset auto export flag when expiry changes
  cfg['auto_exported_file'] = nil
  cfg.delete('auto_exported_at')
  write_legacy_config(cfg)
  @success = "Expiry date saved: #{date}"
  redirect '/database_manage'
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

get '/equipments/delete' do
  require_super_admin!
  Equipment.reset_column_information
  @equipments = Equipment.order(:name)
  erb :'equipments/delete'
end

# API endpoints
get '/api/equipments' do
  content_type :json
  Equipment.all.to_json
end

# API: search serial numbers / asset tags across UserEquipment, Equipment and Requests
get '/api/serials' do
  require_login!
  content_type :json
  q = params['q']&.to_s&.strip
  halt 400, { error: 'missing_query' }.to_json if q.nil? || q.empty?

  matches = []

  # search user-assigned units first (per-serial accuracy)
  begin
    ue_q = UserEquipment.where('serial LIKE ?', "%#{q}%").limit(50)
    ue_q.find_each do |ue|
      matches << {
        type: 'user_equipment',
        serial: ue.serial,
        equipment_id: ue.equipment_id,
        equipment_name: ue.equipment&.name,
        equipment_model: ue.equipment&.model,
        user_id: ue.user_id,
        user_name: ue.user&.username,
        request_id: ue.request_id,
        assigned_at: ue.assigned_at,
        returned_at: ue.returned_at,
        active: ue.active
      }
    end
  rescue => _e
  end

  # search master equipment serial_number (asset tag)
  begin
    Equipment.where('serial_number LIKE ?', "%#{q}%").limit(50).find_each do |eq|
      matches << {
        type: 'equipment',
        serial: eq.serial_number,
        equipment_id: eq.id,
        equipment_name: eq.name,
        equipment_model: eq.model,
        status: eq.status,
        location: eq.location
      }
    end
  rescue => _e
  end

  # also search requests notes for embedded serials (best-effort)
  begin
    Request.where('notes LIKE ?', "%#{q}%").limit(50).find_each do |r|
      # try to extract serial lines from notes
      s = nil
      if r.notes && r.notes.match(/serial:\s*([^;\n]+)/i)
        s = r.notes.match(/serial:\s*([^;\n]+)/i)[1].to_s.strip
      end
      matches << {
        type: 'request_note',
        serial: s || q,
        request_id: r.id,
        equipment_id: r.equipment_id,
        equipment_name: r.equipment&.name,
        requester_name: r.requester_name,
        notes: r.notes,
        checkout_date: r.checkout_date,
        approved_at: r.approved_at,
        returned_at: r.returned_at
      }
    end
  rescue => _e
  end

  # de-duplicate by serial+type+request/equipment
  uniq = {}
  filtered = []
  matches.each do |m|
    key = [m[:type], m[:serial].to_s, m[:equipment_id].to_s, m[:request_id].to_s].join('::')
    next if uniq[key]
    uniq[key] = true
    filtered << m
  end

  { q: q, results: filtered }.to_json
end

get '/api/equipments/:id' do
  content_type :json
  Equipment.find(params[:id]).to_json
end

# API: equipment full timeline (history + user assignments + requests)
get '/api/equipments/:id/history' do
  require_login!
  content_type :json
  eq = Equipment.find_by(id: params[:id])
  halt 404, { error: 'not_found' }.to_json unless eq

  histories = EquipmentHistory.where(equipment_id: eq.id).order(:occurred_at).map do |h|
    {
      id: h.id,
      action: h.action,
      details: (begin; JSON.parse(h.details) rescue h.details; end),
      user_id: h.user_id,
      user_name: h.user&.username,
      request_id: h.request_id,
      occurred_at: h.occurred_at
    }
  end

  user_eqs = UserEquipment.where(equipment_id: eq.id).order(:assigned_at).map do |ue|
    {
      id: ue.id,
      user_id: ue.user_id,
      user_name: ue.user&.username,
      serial: ue.serial,
      assigned_at: ue.assigned_at,
      returned_at: ue.returned_at,
      active: ue.active,
      request_id: ue.request_id
    }
  end

  reqs = Request.where(equipment_id: eq.id).order(:created_at).map do |r|
    {
      id: r.id,
      status: r.status,
      requester_name: r.requester_name,
      quantity: r.quantity,
      checkout_date: r.checkout_date,
      approved_at: r.approved_at,
      returned_at: r.returned_at,
      notes: r.notes
    }
  end

  {
    equipment: eq.attributes.slice('id','name','model','serial_number','status','location','category','quantity','created_at','updated_at','notes','brand'),
    histories: histories,
    assignments: user_eqs,
    requests: reqs
  }.to_json
end
