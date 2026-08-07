class ChangePriceCentsToBigint < ActiveRecord::Migration[8.0]
  def change
    change_column :properties, :price_cents, :bigint
  end
end
