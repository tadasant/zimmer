# Where a turn delivered to an agent session came from (TurnSource). Additive and
# nullable everywhere: a row written before this column exists, or by a caller
# that reports nothing, has no source and delivers exactly as it always did.
class AddSourceContextToTurns < ActiveRecord::Migration[8.1]
  def change
    # The initial prompt's source. Follow-ups carry theirs inside the delivered
    # prompt and in metadata["last_turn_source"].
    add_column :sessions, :source_context, :jsonb
    # A queued message's source, rendered into the turn when the queue drains.
    add_column :enqueued_messages, :source_context, :jsonb
    # Which client last drove a Live conversation (web, ios, carplay, mcp), so a
    # delegation the live model makes can say where the person was.
    add_column :live_conversations, :client_surface, :string
  end
end
