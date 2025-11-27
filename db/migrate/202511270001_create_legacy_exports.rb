class CreateLegacyExports < ActiveRecord::Migration[6.0]
  def change
    create_table :legacy_exports do |t|
      t.date :expiry_date
      t.date :import_date
      t.string :auto_exported_file
      t.datetime :auto_exported_at
      t.string :uploaded_to_repo
      t.datetime :uploaded_at
      t.string :uploaded_file
      t.string :uploaded_gz
      t.text :auto_export_upload_error
      t.text :auto_export_upload_logs

      t.timestamps
    end
  end
end
