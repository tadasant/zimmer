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
    # Nullify, not cascade: the record of a comment an agent posted has to outlive
    # the session, because the comment on GitHub does.
    [ "agent_posted_github_comments", "session_id", :nullify ],
    [ "elicitations", "session_id", :cascade ],
    [ "enqueued_messages", "session_id", :cascade ],
    [ "gate_decisions", "writing_session_id", :nullify ],
    # Cascade, not nullify: a human message is a record of what a human said to
    # THIS session, so it is meaningless without it — and HumanMessage's
    # read-only guard deliberately allows the association-driven destroy.
    [ "human_messages", "session_id", :cascade ],
    [ "logs", "session_id", :cascade ],
    [ "mcp_oauth_pending_flows", "session_id", :cascade ],
    [ "notifications", "session_id", :cascade ],
    # An analysis describes one transcript, so it goes when that transcript does;
    # the session that PRODUCED it is nullified instead, because the finding
    # outlives the worker that found it.
    [ "outcome_analyses", "analyzer_session_id", :nullify ],
    [ "outcome_analyses", "session_id", :cascade ],
    # Same split on a batch item: it exists to name a session (NOT NULL, so it
    # cascades), and separately points at the analysis session it spawned, which
    # is nullified so a deleted analyzer does not erase the record of the attempt.
    [ "outcome_analysis_batch_items", "analysis_session_id", :nullify ],
    [ "outcome_analysis_batch_items", "session_id", :cascade ],
    # Cascade: an experimental-setting label describes one session's run and is
    # meaningless without it. Unlike a usage row it records no money spent, so
    # there is nothing to preserve past the session itself.
    [ "session_experimental_flags", "session_id", :cascade ],
    # Nullify on the fork, cascade on the subject: losing the throwaway fork that
    # wrote a status summary must not lose the summary text, but the summary is
    # meaningless without the session it describes.
    [ "session_status_summaries", "fork_session_id", :nullify ],
    [ "session_status_summaries", "session_id", :cascade ],
    # Nullify, not cascade: a usage row is a record of money already spent. Deleting
    # the session it belonged to must not delete the evidence that it cost something,
    # or the by-root totals silently shrink when a session is cleaned up.
    [ "session_token_usages", "session_id", :nullify ],
    [ "sessions", "parent_session_id", :nullify ],
    # Cascade on BOTH ends, which is where an uncle edge differs from the spawn
    # pointer above. Nulling a parent pointer leaves a meaningful row — a session
    # with no recorded parent. Nulling either end of an edge leaves a row that
    # asserts nothing, so the edge goes away with either session.
    [ "session_uncle_links", "session_id", :cascade ],
    [ "session_uncle_links", "uncle_session_id", :cascade ],
    [ "subagent_transcripts", "session_id", :cascade ],
    # Nullify for the same reason the parent usage row does, and it has to MATCH the
    # parent: `session_token_usages` blanks its own `session_id` on delete, so a
    # feature row that cascaded away would leave the split shorter than the whole,
    # and one that kept a dead id would leave a split with no whole to reconcile
    # against. Both tables forget the session and keep the spend.
    [ "token_usage_features", "session_id", :nullify ]
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

  test "deleting a session keeps its spend and its feature split, both unattributed" do
    session = create_session
    usage = SessionTokenUsage.create!(
      request_id: "req_cascade", session_id: session.id, model: "claude-opus-5",
      agent_root: "zimmer", called_at: 1.hour.ago, cache_read_tokens: 100_000
    )
    feature = TokenUsageFeature.create!(
      request_id: usage.request_id, feature: "goal", session_id: session.id,
      agent_root: "zimmer", model: "claude-opus-5", called_at: 1.hour.ago,
      cache_read_tokens: 40_000
    )

    assert_nothing_raised { session.destroy! }

    # Spend that happened is still spend, and its split is still its split. Both
    # forget the session; neither forgets the money.
    assert_nil usage.reload.session_id
    assert_nil feature.reload.session_id
    assert_equal 40_000, feature.cache_read_tokens
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
