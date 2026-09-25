class AddEventGroupToEvents < ActiveRecord::Migration[8.0]
  def change
    add_reference :events, :event_group, foreign_key: true, index: true
  end
end
