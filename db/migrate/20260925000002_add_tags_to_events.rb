class AddTagsToEvents < ActiveRecord::Migration[8.0]
  def change
    # Event tags (2026-09-25): the closed EventTags list stored verbatim as
    # display labels; empty array = no tags (only event posts get an events
    # row, so non-events never carry tags here).
    add_column :events, :tags, :string, array: true, default: [], null: false
  end
end
