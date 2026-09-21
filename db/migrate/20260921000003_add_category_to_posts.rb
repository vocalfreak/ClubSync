class AddCategoryToPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :posts, :category, :string
  end
end
