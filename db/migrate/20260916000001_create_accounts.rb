class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :handle, null: false
      t.timestamps
    end

    add_index :accounts, :handle, unique: true
  end
end
