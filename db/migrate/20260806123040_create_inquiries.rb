class CreateInquiries < ActiveRecord::Migration[8.1]
  def change
    create_table :inquiries do |t|
      t.string :name
      t.string :email
      t.string :phone
      t.text :message
      t.string :status
      t.references :property, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
