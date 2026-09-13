class MakePostsStructurallyInvalidColumnsNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :posts, :account, true
    change_column_null :posts, :post_type, true
    change_column_null :posts, :source_url, true
    change_column_null :posts, :posted_at, true
  end
end
