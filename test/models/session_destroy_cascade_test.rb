# frozen_string_literal: true

require "test_helper"

# Deleting a session must clean up after itself in the DATABASE, not only in
# ActiveRecord.
#
# Session declares `dependent: :destroy` for every table that references it, which
# covers `session.destroy`. It does not cover a row-level delete: `Session.delete_all`
# (which most of this suite's setup blocks use), `session.delete`, or a `DELETE FROM
# sessions` typed into psql all skip the callbacks. Without an ON DELETE rule on the
# foreign key, Postgres refuses those deletes outright — that is the
# `PG::ForeignKeyViolation ... still referenced from table "notifications"` this suite
# used to raise, and the reason the fixture files for elicitations, enqueued_messages
# and subagent_transcripts are deliberately empty. The same violation can reach
# `session.destroy` too: a notification INSERT that commits between destroy's
# child-delete and its parent-delete leaves a row the parent delete then trips over.
#
# These tests pin the ON DELETE rules, so the invariant survives whichever path a
# caller takes.
class SessionDestroyCascadeTest < ActiveSupport::TestCase
  test "row-level delete of a session with notifications does not raise a foreign key violation" do
    session = create_session
    notification = Notification.create!(session: session, notification_type: "needs_input")

    assert_nothing_raised do
      Session.where(id: session.id).delete_all
    end

    assert_not Notification.exists?(notification.id), "the notification should have been deleted with its session"
  end

  test "row-level delete cascades to every table that references the session" do
    session = create_session
    children = {
      Log => Log.create!(session: session, content: "Agent started", level: "info"),
      Notification => Notification.create!(session: session, notification_type: "needs_input"),
      EnqueuedMessage => EnqueuedMessage.create!(session: session, content: "next up", position: 1),
      SubagentTranscript => SubagentTranscript.create!(session: session, agent_id: "agent-1"),
      Elicitation => Elicitation.create!(
        session: session,
        request_id: "req-#{SecureRandom.hex(8)}",
        mode: "form",
        message: "Confirm?",
        expires_at: 1.hour.from_now
      ),
      McpOauthPendingFlow => McpOauthPendingFlow.create!(
        session: session,
        server_name: "notion",
        server_url: "https://mcp.notion.com/v1/mcp",
        state: "state-#{SecureRandom.hex(8)}",
        code_verifier: "v" * 43,
        authorization_endpoint: "https://api.notion.com/v1/oauth/authorize",
        token_endpoint: "https://api.notion.com/v1/oauth/token",
        client_id: "zimmer-test",
        redirect_uri: "http://localhost:3000/mcp_oauth/callback",
        mcp_server_config: { "url" => "https://mcp.notion.com/v1/mcp", "headers" => {} },
        expires_at: 1.hour.from_now
      )
    }

    assert_nothing_raised { session.delete }

    children.each do |model, record|
      assert_not model.exists?(record.id), "#{model.name} row should have been deleted with its session"
    end
  end

  test "row-level delete of a parent session nullifies its children's parent_session_id" do
    parent = create_session
    child = create_session(parent_session_id: parent.id)

    assert_nothing_raised { parent.delete }

    child.reload
    assert_predicate child, :persisted?, "the child session should outlive its parent"
    assert_nil child.parent_session_id, "the child's parent pointer should be nulled, not left dangling"
  end

  test "destroy still removes dependent rows through ActiveRecord" do
    session = create_session
    notification = Notification.create!(session: session, notification_type: "needs_input")
    log = Log.create!(session: session, content: "Agent started", level: "info")

    assert_nothing_raised { session.destroy! }

    assert_not Notification.exists?(notification.id)
    assert_not Log.exists?(log.id)
  end

  # Guards the rules themselves rather than one path through them: a future migration
  # that adds a table referencing sessions without an ON DELETE rule reintroduces the
  # foreign-key violation, and fails here instead of in production.
  test "every foreign key into sessions declares an on_delete rule" do
    connection = ActiveRecord::Base.connection
    referencing = connection.tables.flat_map { |table| connection.foreign_keys(table) }
                            .select { |fk| fk.to_table == "sessions" }

    assert_operator referencing.size, :>=, 7, "expected the known session-referencing foreign keys"

    referencing.each do |fk|
      assert_not_nil fk.on_delete,
        "#{fk.from_table}.#{fk.column} references sessions with no ON DELETE rule; " \
        "a row-level session delete would raise a foreign-key violation"
    end
  end

  private

  def create_session(**attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      agent_runtime: "claude_code",
      **attrs
    )
  end
end
