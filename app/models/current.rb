class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :currency
  delegate :user, to: :session, allow_nil: true
end

