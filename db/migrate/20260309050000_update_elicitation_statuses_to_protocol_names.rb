# frozen_string_literal: true

# Migrate elicitation status values from past-tense internal names to
# MCP protocol action names (e.g. "accepted" -> "accept").
class UpdateElicitationStatusesToProtocolNames < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE elicitations SET status = 'accept' WHERE status = 'accepted';
      UPDATE elicitations SET status = 'decline' WHERE status = 'declined';
      UPDATE elicitations SET status = 'cancel' WHERE status = 'cancelled';
    SQL
  end

  def down
    execute <<~SQL
      UPDATE elicitations SET status = 'accepted' WHERE status = 'accept';
      UPDATE elicitations SET status = 'declined' WHERE status = 'decline';
      UPDATE elicitations SET status = 'cancelled' WHERE status = 'cancel';
    SQL
  end
end
