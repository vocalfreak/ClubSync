class Event < ApplicationRecord
  belongs_to :post
  belongs_to :event_group, optional: true
end
