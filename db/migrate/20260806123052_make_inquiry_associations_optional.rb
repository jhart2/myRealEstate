class MakeInquiryAssociationsOptional < ActiveRecord::Migration[8.1]
  def change
    change_column_null :inquiries, :property_id, true
    change_column_null :inquiries, :agent_id, true
    change_column_null :inquiries, :user_id, true
    change_column_null :agents, :user_id, true
    change_column_default :agents, :active, from: nil, to: true
    change_column_default :agents, :listings_count, from: nil, to: 0
    change_column_default :properties, :featured, from: nil, to: false
    change_column_default :properties, :status, from: nil, to: "active"
    change_column_default :inquiries, :status, from: nil, to: "new"
    change_column_default :subscriptions, :active, from: nil, to: true
  end
end
