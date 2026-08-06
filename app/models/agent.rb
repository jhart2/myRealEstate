class Agent < ApplicationRecord
  include ImageAttachable

  belongs_to :user, optional: true
  has_many :properties, dependent: :nullify
  has_many :inquiries, dependent: :nullify

  scope :active, -> { where(active: true) }
  scope :featured, -> { active.order(listings_count: :desc) }
  scope :show_on_homepage, -> { active.where(show_on_homepage: true).order(listings_count: :desc) }

  validates :name, :title, :email, presence: true
  validates :years_experience, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 80 }, allow_nil: true

  def experience_label
    return if years_experience.blank?
    years_experience == 1 ? "1 year experience" : "#{years_experience} years experience"
  end

  def to_param
    "#{id}-#{name.parameterize}"
  end
end
