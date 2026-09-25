class AddEmbeddingToPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :posts, :embedding, :jsonb
  end
end
