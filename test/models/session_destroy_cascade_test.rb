# frozen_string_literal: true

require "test_helper"

# Deleting a session cleans up after itself in the DATABASE, not only in ActiveRecord.
#
# Session declares `dependent: :destroy` for every table that references it, which
# covers `session.destroy`. It does not cover a row-level delete: `Session.delete_all`
# (which many of this suite's setup blocks use), `session.delete`, or a `DELETE FROM
# sessions` typed into psql all skip the callbacks and go straight to the database.
# Without an ON DELETE rule on the foreign key, Postgres refuses those deletes with a
# foreign-key violation. The same violation can reach `session.destroy` itself: a
# notification INSERT that commits between destroy's child-delete and its parent-delete
# leaves a row the parent delete then trips over.
#
# These tests pin the ON DELETE rules, so the invariant holds whichever path a caller
# takes.
class SessionDestroyCascadeTest < ActiveSupport::TestCase
  # Every foreign key that points at `sessions`, and the rule each one carries:
  # [from_table, column, on_delete].
  EXPECTED_SESSION_FOREIGN_KEYS = [
    [ "elicitations", "session_id", :cascade ],
    [ "enqueued_messages", "session_id", :cascade ],
    [ "logs", "session_id", :cascade ],
    [ "mcp_oauth_pending_flows", "session_id", :cascade ],
    [ "notifications", "session_id", :cascade ],
    [ "sessions", "blocked_by_session_id", :nullify ],
    [ "sessions", "parent_session_id", :nullify ],
    [ "subagent_transcripts", "session_id", :cascade ]
  ].freeze

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

  # Guards the rules themselves rather than one path through them. A table added later
  # that references sessions — or an existing key that loses its rule — fails here,
  # with the expected set spelling out what each key is supposed to do, instead of
  # surfacing as a foreign-key violation in production.
  test "the foreign keys into sessions carry exactly the expected on_delete rules" do
    connection = ActiveRecord::Base.connection
    actual = connection.tables
                       .flat_map { |table| connection.foreign_keys(table) }
                       .select { |fk| fk.to_table == "sessions" }
                       .map { |fk| [ fk.from_table, fk.column, fk.on_delete ] }
                       .sort

    assert_equal EXPECTED_SESSION_FOREIGN_KEYS.sort, actual,
      "a foreign key into sessions changed. A key with no ON DELETE rule (nil) makes a " \
      "row-level session delete raise; update this list only alongside a deliberate migration."
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
