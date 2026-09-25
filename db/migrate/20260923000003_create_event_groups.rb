class CreateEventGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :event_groups do |t|
      t.timestamps
    end
  end
end
