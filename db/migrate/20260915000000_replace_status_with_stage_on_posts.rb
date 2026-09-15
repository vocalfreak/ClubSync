class ReplaceStatusWithStageOnPosts < ActiveRecord::Migration[8.0]
  def change
    remove_column :posts, :status, :integer, default: 0, null: false

    add_column :posts, :stage, :integer, default: 0, null: false
    add_column :posts, :is_event, :boolean
    add_column :posts, :last_error, :text
    add_column :posts, :stage_failed_at, :datetime

    add_index :posts, :stage
  end
end
