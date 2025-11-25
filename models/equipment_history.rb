require 'active_record'

class EquipmentHistory < ActiveRecord::Base
  self.table_name = 'equipment_histories'

  belongs_to :equipment
  belongs_to :user, optional: true
  belongs_to :user_equipment, optional: true
  belongs_to :request, optional: true

  validates :action, presence: true

  before_save :ensure_details_json

  private
  def ensure_details_json
    # If details is a Hash or Array (accidentally assigned), convert to JSON string.
    if details.is_a?(Hash) || details.is_a?(Array)
      self.details = details.to_json
    end
    # If details is a string, leave as-is; normalization of legacy strings is done by rake task
  end

  def details_hash
    begin
      JSON.parse(details || '{}')
    rescue
      {}
    end
  end
end
