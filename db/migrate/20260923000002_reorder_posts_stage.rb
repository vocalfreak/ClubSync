class ReorderPostsStage < ActiveRecord::Migration[8.0]
  # Stage enum grows a new terminal stage (deduped moves after extracted), so
  # the two integer values swap. A naive UPDATE would collide (both live at 2
  # and 3), so remap through the temp value 99 before swapping (dedup plan §1).
  def up
    execute "UPDATE posts SET stage = 99 WHERE stage = 3"
    execute "UPDATE posts SET stage = 3 WHERE stage = 2"
    execute "UPDATE posts SET stage = 2 WHERE stage = 99"
  end

  def down
    execute "UPDATE posts SET stage = 99 WHERE stage = 2"
    execute "UPDATE posts SET stage = 2 WHERE stage = 3"
    execute "UPDATE posts SET stage = 3 WHERE stage = 99"
  end
end
