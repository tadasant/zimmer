class CreateLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :logs do |t|
      t.references :session, null: false, foreign_key: true
      t.text :content
      t.string :level

      t.timestamps
    end
  end
end
