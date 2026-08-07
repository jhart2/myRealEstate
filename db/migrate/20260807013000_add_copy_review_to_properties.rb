class AddCopyReviewToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :copy_needs_review, :boolean, default: false, null: false
    add_column :properties, :copy_review_notes, :json, default: {}, null: false
    add_index :properties, :copy_needs_review
  end
end
