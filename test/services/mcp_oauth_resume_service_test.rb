require "test_helper"

# Covers the auto-resume decision for sessions blocked on MCP OAuth:
# the resume fires exactly once when (and only when) the last flow completes,
# the original intent (the stored prompt) is replayed, partial authorization
# keeps the session blocked, and the edge cases (expired/abandoned pending
# flow, already-authorized server, retried callback idempotency) behave.
class McpOauthResumeServiceTest < ActiveJob::TestCase
  include AttachmentFixtures

  KEY_A = "server-a|aaaaaaaaaaaaaaaa".freeze
  KEY_B = "server-b|bbbbbbbbbbbbbbbb".freeze

  setup do
    @session = Session.create!(
      prompt: "Do the original work",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "failure_reason" => "oauth_required",
        "oauth_required_servers" => [
          { "server_name" => "server-a", "server_url" => "https://a.example.com/mcp", "credential_key" => KEY_A },
          { "server_name" => "server-b", "server_url" => "https://b.example.com/mcp", "credential_key" => KEY_B }
        ]
      }
    )
  end

  teardown { cleanup_stored_attachments! }

  # Authorize both servers, which is what makes the next #call resume.
  def authorize_everything
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")
  end

  # The arguments of the one AgentSessionJob the resume enqueued.
  def enqueued_agent_session_args
    jobs = enqueued_jobs.select { |job| job["job_class"] == "AgentSessionJob" }
    assert_equal 1, jobs.length, "expected exactly one enqueued AgentSessionJob"
    ActiveJob::Arguments.deserialize(jobs.first["arguments"])
  end

  def authorize(credential_key, server_name:, expires_at: 1.hour.from_now)
    McpOauthCredential.create!(
      server_name: server_name,
      server_url: "https://#{server_name}.example.com/mcp",
      credential_key: credential_key,
      client_id: "test-client",
      access_token: "token-#{credential_key}",
      token_endpoint: "https://#{server_name}.example.com/oauth/token",
      expires_at: expires_at
    )
  end

  # --- partial authorization keeps the session blocked --------------------

  test "authorizing some but not all servers keeps the session blocked and trims the list" do
    authorize(KEY_A, server_name: "server-a")

    assert_no_enqueued_jobs do
      assert_equal :partial, McpOauthResumeService.new(@session).call
    end

    @session.reload
    assert @session.failed?, "session should remain blocked while a server still needs OAuth"
    assert_equal "oauth_required", @session.metadata["failure_reason"]
    remaining = @session.metadata["oauth_required_servers"]
    assert_equal [ "server-b" ], remaining.map { |s| s["server_name"] }
  end

  # --- full authorization resumes the original intent ---------------------

  test "authorizing the last server resumes the session and replays the original prompt" do
    authorize(KEY_A, server_name: "server-a")
    McpOauthResumeService.new(@session).call # first authorization -> partial

    authorize(KEY_B, server_name: "server-b")

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session.reload).call
    end

    @session.reload
    assert @session.waiting?, "session should be re-queued in waiting state"
    assert_equal true, @session.metadata["oauth_complete"]
    assert_nil @session.metadata["failure_reason"]
    assert_nil @session.metadata["oauth_required_servers"]
    assert_equal "Do the original work", @session.prompt, "original intent must be preserved for replay"
  end

  test "authorizing all servers at once resumes immediately" do
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
    end

    assert @session.reload.waiting?
  end

  # --- exactly-once / idempotency -----------------------------------------

  test "a retried callback after resume does not enqueue a second run" do
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")

    assert_enqueued_jobs 1, only: AgentSessionJob do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
      # Simulate the provider re-delivering the callback for the same flow.
      assert_equal :not_blocked, McpOauthResumeService.new(@session.reload).call
    end
  end

  # --- pending flows gate the resume --------------------------------------

  test "an active pending flow blocks resume even when all recorded servers are authorized" do
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")

    McpOauthPendingFlow.create!(
      session: @session,
      server_name: "server-c",
      server_url: "https://c.example.com/mcp",
      state: "pending-state-c",
      code_verifier: "c" * 43,
      authorization_endpoint: "https://c.example.com/oauth/authorize",
      token_endpoint: "https://c.example.com/oauth/token",
      client_id: "test-client",
      redirect_uri: "http://localhost:3000/mcp_oauth/callback",
      mcp_server_config: { "type" => "http", "url" => "https://c.example.com/mcp" },
      expires_at: 1.hour.from_now
    )

    assert_no_enqueued_jobs do
      assert_equal :partial, McpOauthResumeService.new(@session).call
    end
    assert @session.reload.failed?
  end

  test "an expired pending flow does not block resume" do
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")

    flow = McpOauthPendingFlow.new(
      session: @session,
      server_name: "abandoned",
      server_url: "https://abandoned.example.com/mcp",
      state: "abandoned-state",
      code_verifier: "d" * 43,
      authorization_endpoint: "https://abandoned.example.com/oauth/authorize",
      token_endpoint: "https://abandoned.example.com/oauth/token",
      client_id: "test-client",
      redirect_uri: "http://localhost:3000/mcp_oauth/callback",
      mcp_server_config: { "type" => "http", "url" => "https://abandoned.example.com/mcp" },
      expires_at: 1.hour.ago
    )
    flow.save!(validate: false)

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
    end
  end

  # --- edge cases ----------------------------------------------------------

  test "an expired credential does not count as authorized" do
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b", expires_at: 1.hour.ago)

    assert_no_enqueued_jobs do
      assert_equal :partial, McpOauthResumeService.new(@session).call
    end
    assert_equal [ "server-b" ], @session.reload.metadata["oauth_required_servers"].map { |s| s["server_name"] }
  end

  test "a server already authorized in a prior session is treated as satisfied" do
    # server-a was authorized elsewhere before this session ever blocked.
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
    end
  end

  test "a session that is not blocked is left untouched" do
    running = Session.create!(
      prompt: "running work",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {}
    )

    assert_no_enqueued_jobs do
      assert_equal :not_blocked, McpOauthResumeService.new(running).call
    end
    assert running.reload.running?
  end

  test "a waiting session still listing required servers is blocked and resumes when authorized" do
    @session.update!(status: :waiting)
    authorize(KEY_A, server_name: "server-a")
    authorize(KEY_B, server_name: "server-b")

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
    end
    assert @session.reload.waiting?
    assert_nil @session.metadata["oauth_required_servers"]
  end

  # --- credential_key fallback (entries recorded without a key) ------------

  test "resolves credential via catalog when the recorded entry has no credential_key" do
    @session.update!(
      metadata: @session.metadata.merge(
        "oauth_required_servers" => [
          { "server_name" => "keyless", "server_url" => "https://keyless.example.com/mcp" }
        ]
      )
    )

    config = { type: "http", url: "https://keyless.example.com/mcp" }
    derived_key = McpOauthCredential.compute_credential_key("keyless", config)
    authorize(derived_key, server_name: "keyless")

    ServersConfig.stub(:credential_config, config) do
      assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
        assert_equal :resumed, McpOauthResumeService.new(@session).call
      end
    end
  end

  test "falls back to server_url when the catalog has no entry for a keyless server" do
    @session.update!(
      metadata: @session.metadata.merge(
        "oauth_required_servers" => [
          { "server_name" => "keyless", "server_url" => "https://keyless.example.com/mcp" }
        ]
      )
    )

    derived_key = McpOauthCredential.compute_credential_key(
      "keyless", { type: "http", url: "https://keyless.example.com/mcp" }
    )
    authorize(derived_key, server_name: "keyless")

    ServersConfig.stub(:credential_config, nil) do
      assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
        assert_equal :resumed, McpOauthResumeService.new(@session).call
      end
    end
  end

  test "a keyless entry with no catalog match and no server_url keeps the session blocked" do
    # The post-spawn MCP-failure path can record a required server with no
    # credential_key and a nil server_url (catalog miss at record time). We
    # can't evaluate authorization, so the session must stay blocked rather
    # than resume prematurely.
    @session.update!(
      metadata: @session.metadata.merge(
        "oauth_required_servers" => [
          { "server_name" => "unresolvable", "server_url" => nil }
        ]
      )
    )

    ServersConfig.stub(:credential_config, nil) do
      assert_no_enqueued_jobs do
        assert_equal :partial, McpOauthResumeService.new(@session).call
      end
    end
    assert @session.reload.failed?, "session stays blocked when no credential key can be derived"
  end

  # --- the replayed turn carries what the turn was created with -----------
  #
  # AgentSessionJob reads attachments ONLY out of its job arguments, so a resume
  # that enqueues a bare new-session job replays "here is the screenshot, fix
  # this" with the prompt and without the screenshot (#789).

  test "the replayed first turn carries the images the session was created with" do
    image = store_image_for(@session)
    authorize_everything

    assert_equal :resumed, McpOauthResumeService.new(@session).call

    assert_equal [ { path: image[:path], media_type: "image/png" } ],
      enqueued_agent_session_args.dig(2, :images)
  end

  test "the replayed first turn carries the files the session was created with" do
    stored = store_file_for(@session, filename: "notes.txt", content: "read me")
    authorize_everything

    assert_equal :resumed, McpOauthResumeService.new(@session).call

    files = enqueued_agent_session_args.dig(2, :files)
    assert_equal [ stored[:path] ], files.map { |f| f[:path] }
    assert_equal [ "notes.txt" ], files.map { |f| f[:original_filename] }
  end

  # The ordinary case, unchanged: nothing on disk, so the job is enqueued
  # exactly as it was before.
  test "a session with no stored attachments resumes with no attachment arguments" do
    authorize_everything

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
    end
  end

  # An attachment a queued follow-up owns belongs to that follow-up's turn, not
  # to the one being replayed.
  test "an attachment a queued follow-up owns is not smuggled onto the replayed turn" do
    first_turn = store_image_for(@session)
    follow_up = store_image_for(@session)
    @session.enqueued_messages.create!(
      content: "and now this one", position: 1,
      images: [ { "path" => follow_up[:path], "media_type" => "image/png" } ]
    )
    authorize_everything

    assert_equal :resumed, McpOauthResumeService.new(@session).call

    assert_equal [ { path: first_turn[:path], media_type: "image/png" } ],
      enqueued_agent_session_args.dig(2, :images)
  end

  # --- and only when there IS a first turn left to replay ------------------
  #
  # `oauth_required` is not exclusively a first-turn failure. #update_mcp_servers
  # and #update_catalog_plugins set it when a human adds a server to a session
  # mid-run, and AgentSessionJob's follow-up branch sets it under
  # "Follow-up blocked: OAuth authorization required for MCP servers". A session
  # that has already produced a transcript has had its first turn delivered, and
  # everything on its volume includes attachments earlier turns already
  # consumed — replaying those would re-deliver them onto the wrong turn.

  test "a session blocked after it had already run does not have its attachments replayed" do
    store_image_for(@session)
    @session.update!(transcript: { "type" => "user", "message" => { "content" => "already ran" } }.to_json)
    authorize_everything

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      assert_equal :resumed, McpOauthResumeService.new(@session).call
    end
  end
end
