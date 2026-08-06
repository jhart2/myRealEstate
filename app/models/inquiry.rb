class Inquiry < ApplicationRecord
  belongs_to :property, optional: true
  belongs_to :agent, optional: true
  belongs_to :user, optional: true

  STATUSES = %w[new contacted closed].freeze

  scope :recent, -> { order(created_at: :desc) }
  scope :open, -> { where(status: %w[new contacted]) }

  validates :name, :email, :message, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :status, inclusion: { in: STATUSES }

  before_validation :assign_agent_from_property, on: :create

  private

  def assign_agent_from_property
    self.agent ||= property&.agent
  end
end
