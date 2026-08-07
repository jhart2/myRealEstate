# frozen_string_literal: true

class MigratePropertyDescriptionsToActionText < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    rename_column :properties, :description, :description_legacy

    say_with_time "copying property description_legacy into action_text" do
      Property.reset_column_information
      Property.unscoped.find_each do |property|
        legacy = property.read_attribute(:description_legacy)
        next if legacy.blank?

        html = plain_text_to_action_text_html(legacy)
        ActionText::RichText.find_or_initialize_by(
          record_type: "Property",
          record_id: property.id,
          name: "description"
        ).update!(body: html)
      end
    end

    remove_column :properties, :description_legacy, :text
  end

  def down
    add_column :properties, :description_legacy, :text

    Property.reset_column_information
    Property.unscoped.find_each do |property|
      rich = ActionText::RichText.find_by(
        record_type: "Property",
        record_id: property.id,
        name: "description"
      )
      next unless rich

      property.update_column(:description_legacy, rich.to_plain_text.presence)
    end

    ActionText::RichText.where(record_type: "Property", name: "description").delete_all
    rename_column :properties, :description_legacy, :description
  end

  private

  def plain_text_to_action_text_html(text)
    escaped = ERB::Util.html_escape(text.to_s)
    paragraphs = escaped.split(/\n{2,}/).map(&:strip).reject(&:blank?)
    return "<div></div>" if paragraphs.empty?

    paragraphs.map { |p| "<div>#{p.gsub("\n", "<br>")}</div>" }.join
  end
end
