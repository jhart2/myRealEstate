class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :favorites, dependent: :destroy
  has_many :favorited_properties, through: :favorites, source: :property
  has_many :inquiries, dependent: :nullify
  has_one :agent_profile, class_name: "Agent", dependent: :nullify

  enum :role, { buyer: 0, agent: 1, admin: 2 }, default: :buyer

  validates :email_address, presence: true, uniqueness: true
  validates :name, presence: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  def favorited?(property)
    favorites.exists?(property_id: property.id)
  end
end
