# Remembers admin-resolved near-duplicate pairs so the detector / rake APPLY
# does not re-flag them. Keys are always stored as (low_id, high_id).
class DuplicateDismissal < ApplicationRecord
  belongs_to :property_low, class_name: "Property", foreign_key: :property_low_id
  belongs_to :property_high, class_name: "Property", foreign_key: :property_high_id

  validates :property_low_id, :property_high_id, presence: true
  validate :ordered_ids

  def self.dismiss!(left_id, right_id, action: "dismissed")
    low_id, high_id = [ left_id.to_i, right_id.to_i ].minmax
    raise ArgumentError, "pair requires two distinct property ids" if low_id == high_id

    record = find_or_initialize_by(property_low_id: low_id, property_high_id: high_id)
    record.action = action.to_s
    record.save!
    record
  end

  def self.pair_key_set
    pluck(:property_low_id, :property_high_id).each_with_object(Set.new) do |(low_id, high_id), set|
      set << [ low_id, high_id ]
    end
  end

  def self.dismissed?(left_id, right_id, cache: nil)
    key = [ left_id.to_i, right_id.to_i ].minmax
    if cache
      cache.include?(key)
    else
      exists?(property_low_id: key[0], property_high_id: key[1])
    end
  end

  private

  def ordered_ids
    return if property_low_id.blank? || property_high_id.blank?
    return if property_low_id < property_high_id

    errors.add(:base, "property_low_id must be less than property_high_id")
  end
end
