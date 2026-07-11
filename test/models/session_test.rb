require "test_helper"
require "mocha/minitest"
require "ostruct" # OpenStruct is used to build mock agent roots; not autoloaded when this file runs in isolation

class SessionTest < ActiveSupport::TestCase
  # Test character limit constants
  test "PROMPT_MAX_LENGTH constant should be 500000" do
    assert_equal 500_000, Session::PROMPT_MAX_LENGTH
  end

  test "GOAL_MAX_LENGTH constant should be 50000" do
    assert_equal 50_000, Session::GOAL_MAX_LENGTH
  end

  # Guards the active-PR partial index (index_sessions_on_pr_url_active_id), whose
  # predicate hardcodes the integer enum values for archived/failed as `status NOT
  # IN (3, 4)`. The `Session.with_github_prs` scope relies on `where.not(status:)`
  # emitting those same integers so the planner can use the index. If the enum is
  # ever reordered, this test fails loudly — prompting an update to the migration
  # predicate — instead of silently demoting the poller scan back to a seq scan.
  test "archived and failed status enum integers stay 3 and 4 for the active-PR index" do
    assert_equal 3, Session.statuses["archived"]
    assert_equal 4, Session.statuses["failed"]
    assert_match(/status.+NOT IN \(3, 4\)/, Session.with_github_prs.to_sql)
  end

  # Test clone-only sessions (prompt is optional)
  test "should allow creation without prompt (clone-only session)" do
    session = Session.new(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )
    assert session.valid?, "Session should be valid without a prompt"
  end

  test "should validate prompt length when provided" do
    session = Session.new(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      prompt: "a" * (Session::PROMPT_MAX_LENGTH + 1)  # One character over the limit
    )
    assert_not session.valid?
    assert_includes session.errors[:prompt], "is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)"
  end

  test "should accept prompt at exactly the maximum length" do
    session = Session.new(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      prompt: "a" * Session::PROMPT_MAX_LENGTH
    )
    assert session.valid?
  end

  test "should allow blank prompt" do
    session = Session.new(
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      prompt: ""
    )
    assert session.valid?, "Session should be valid with blank prompt"
  end
  # Test git_root is required
  test "should require git_root" do
    session = Session.new(
      agent_runtime: "claude_code",
      branch: "main",
      prompt: "Test"
    )
    assert_not session.valid?, "Session should be invalid without git_root"
    assert_includes session.errors[:git_root], "can't be blank"
  end

  # Test associations
  test "should have many logs" do
    session = sessions(:running)
    assert_respond_to session, :logs
    assert_kind_of ActiveRecord::Associations::CollectionProxy, session.logs
  end

  test "should destroy dependent logs when session is destroyed" do
    session = sessions(:running)
    log_ids = session.logs.pluck(:id)

    assert_difference "Log.count", -log_ids.count do
      session.destroy
    end

    log_ids.each do |log_id|
      assert_nil Log.find_by(id: log_id)
    end
  end

  # Test enum status
  test "should have status enum with correct values" do
    session = Session.new

    # Test running status
    session.status = :running
    assert session.running?
    assert_equal "running", session.status

    # Test waiting status
    session.status = :waiting
    assert session.waiting?
    assert_equal "waiting", session.status

    # Test needs_input status
    session.status = :needs_input
    assert session.needs_input?
    assert_equal "needs_input", session.status

    # Test archived status
    session.status = :archived
    assert session.archived?
    assert_equal "archived", session.status
  end

  test "should query sessions by status" do
    running_sessions = Session.running
    assert_includes running_sessions, sessions(:running)
    assert_not_includes running_sessions, sessions(:waiting)

    archived_sessions = Session.archived
    assert_includes archived_sessions, sessions(:archived)
    assert_not_includes archived_sessions, sessions(:running)
  end

  # Test default values
  test "should have default agent_runtime" do
    session = Session.new
    assert_equal "claude_code", session.agent_runtime
  end

  test "should have default status of waiting" do
    session = Session.new
    assert_equal "waiting", session.status
    assert session.waiting?
  end

  # Test attribute persistence
  test "should persist prompt attribute" do
    # Using create_session helper from FixtureHelpers
    session = create_session(prompt: "Test prompt", status: :waiting)
    session.reload
    assert_equal "Test prompt", session.prompt
  end

  test "should persist mcp_servers as JSON array" do
    servers = [ "playwright-custom", "twist-wolfbot", "context7" ]
    # Using create_session helper from FixtureHelpers
    session = create_session(
      prompt: "Test",
      status: :waiting,
      mcp_servers: servers
    )

    session.reload
    assert_equal servers, session.mcp_servers
  end

  test "should persist config as JSON hash" do
    config = { "key1" => "value1", "key2" => "value2" }
    # Using create_session helper from FixtureHelpers
    session = create_session(
      prompt: "Test",
      status: :waiting,
      config: config
    )

    session.reload
    assert_equal config, session.config
  end

  # Test creating sessions with different statuses
  test "should create session with running status" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :running)
    assert session.running?
  end

  test "should create session with waiting status" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :waiting)
    assert session.waiting?
  end

  test "should create session with needs_input status" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :needs_input)
    assert session.needs_input?
  end

  test "should create session with archived status" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :archived)
    assert session.archived?
  end

  # Scope: not_in_frozen_category
  test "not_in_frozen_category excludes sessions in a frozen category but keeps others" do
    frozen = Category.create!(name: "Frozen backlog", is_frozen: true)
    active = Category.create!(name: "Active work")

    frozen_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", category: frozen)
    active_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", category: active)
    uncategorized_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")

    result = Session.not_in_frozen_category

    assert_not_includes result, frozen_session
    assert_includes result, active_session
    # A LEFT JOIN keeps NULL-category (Uncategorized) sessions — they must not be dropped.
    assert_includes result, uncategorized_session
  end

  # Test status transitions
  test "should allow status transitions" do
    session = sessions(:waiting)

    session.status = :running
    assert session.save
    assert session.running?

    session.status = :needs_input
    assert session.save
    assert session.needs_input?

    session.status = :archived
    assert session.save
    assert session.archived?
  end

  # Test timestamps
  test "should have created_at timestamp" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :waiting)
    assert_not_nil session.created_at
    assert_kind_of Time, session.created_at
  end

  test "should have updated_at timestamp" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :waiting)
    assert_not_nil session.updated_at
    assert_kind_of Time, session.updated_at
  end

  test "should update updated_at when modified" do
    session = sessions(:running)
    original_updated_at = session.updated_at

    sleep 0.01 # Ensure time difference
    session.update!(prompt: "Updated prompt")

    assert session.updated_at > original_updated_at
  end

  # Test validations
  test "should allow empty prompt for clone-only sessions" do
    session = Session.new(status: :waiting, agent_runtime: "claude_code", git_root: "https://github.com/test/repo.git", branch: "main")
    # Prompt is now optional - sessions can be created without it
    assert session.valid?
    assert_empty session.errors[:prompt]
  end

  test "should validate agent_runtime inclusion" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "invalid_agent")
    assert_not session.valid?
    assert_includes session.errors[:agent_runtime], "invalid_agent is not a valid agent runtime"
  end

  test "should accept valid agent_runtime" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    assert session.valid?
  end

  test "should validate mcp_servers is an array" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.mcp_servers = "not_an_array"
    assert_not session.valid?
    assert_includes session.errors[:mcp_servers], "must be an array"
  end

  test "should accept nil mcp_servers" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.mcp_servers = nil
    assert session.valid?
  end

  test "should accept array mcp_servers" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.mcp_servers = [ "playwright-custom", "twist-wolfbot" ]
    assert session.valid?
  end

  test "should have failed status" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.status = :failed
    assert session.failed?
    assert_equal "failed", session.status
  end

  test "should query sessions by failed status" do
    # Create a failed session for testing
    failed_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :failed)

    failed_sessions = Session.failed
    assert_includes failed_sessions, failed_session
    assert_not_includes failed_sessions, sessions(:running)
  end

  # Test transcript parsing
  test "parsed_transcript should return empty array when transcript is nil" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = nil
    assert_equal [], session.parsed_transcript
  end

  test "parsed_transcript should return empty array when transcript is empty string" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = ""
    assert_equal [], session.parsed_transcript
  end

  test "parsed_transcript should return array as-is when transcript is already an array" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript_array = [
      { "role" => "user", "content" => "Hello", "timestamp" => "2025-11-12T12:00:00Z" },
      { "role" => "assistant", "content" => "Hi there!", "timestamp" => "2025-11-12T12:00:05Z" }
    ]
    session.transcript = transcript_array
    assert_equal transcript_array, session.parsed_transcript
  end

  test "parsed_transcript should parse JSONL format correctly" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = '{"role":"user","content":"Hello","timestamp":"2025-11-12T12:00:00Z"}' + "\n" +
            '{"role":"assistant","content":"Hi there!","timestamp":"2025-11-12T12:00:05Z"}'
    session.transcript = jsonl

    result = session.parsed_transcript
    assert_equal 2, result.length
    assert_equal "user", result[0]["role"]
    assert_equal "Hello", result[0]["content"]
    assert_equal "assistant", result[1]["role"]
    assert_equal "Hi there!", result[1]["content"]
  end

  test "parsed_transcript should handle invalid JSONL lines gracefully" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = '{"role":"user","content":"Hello"}' + "\n" +
            "invalid json line" + "\n" +
            '{"role":"assistant","content":"Hi"}'
    session.transcript = jsonl

    result = session.parsed_transcript
    assert_equal 2, result.length # Should skip the invalid line
    assert_equal "user", result[0]["role"]
    assert_equal "assistant", result[1]["role"]
  end

  test "parsed_transcript should handle empty lines in JSONL" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = '{"role":"user","content":"Hello"}' + "\n" +
            "\n" +
            '{"role":"assistant","content":"Hi"}'
    session.transcript = jsonl

    result = session.parsed_transcript
    assert_equal 2, result.length
  end

  # Test agent_root_name method
  test "agent_root_name should extract name from GitHub URL with .git" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/anthropics/anthropic-cookbook.git"
    )

    assert_equal "anthropic-cookbook", session.agent_root_name
  end

  test "agent_root_name should extract name from GitHub URL without .git" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/user/repo"
    )

    assert_equal "repo", session.agent_root_name
  end

  test "agent_root_name should extract name from GitLab URL" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://gitlab.com/user/project.git"
    )

    assert_equal "project", session.agent_root_name
  end

  test "agent_root_name should extract name from Bitbucket URL" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://bitbucket.org/user/repo.git"
    )

    assert_equal "repo", session.agent_root_name
  end

  test "agent_root_name should extract name from local path" do
    session = Session.new(
      prompt: "Test",
      git_root: "/path/to/local/repo"
    )

    assert_equal "repo", session.agent_root_name
  end

  test "agent_root_name should return nil for blank URL" do
    # Create and save a session first
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    # Use update_column to bypass git_root presence validation (testing edge case)
    session.update_column(:git_root, nil)
    session.reload
    assert_nil session.agent_root_name

    session.update_column(:git_root, "")
    session.reload
    assert_nil session.agent_root_name
  end

  # Test agent_root_path method
  test "agent_root_path should return agent root name when subdirectory is nil" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/user/agents.git",
      subdirectory: nil
    )

    assert_equal "agents", session.agent_root_path
  end

  test "agent_root_path should return agent root name when subdirectory is blank" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/user/agents.git",
      subdirectory: ""
    )

    assert_equal "agents", session.agent_root_path
  end

  test "agent_root_path should combine agent root name and subdirectory with slash" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/user/agents.git",
      subdirectory: "agent-orchestrator"
    )

    assert_equal "agents/agent-orchestrator", session.agent_root_path
  end

  test "agent_root_path should handle subdirectory with local git root" do
    session = Session.new(
      prompt: "Test",
      git_root: "/path/to/agents",
      subdirectory: "agent-orchestrator"
    )

    assert_equal "agents/agent-orchestrator", session.agent_root_path
  end

  test "agent_root_path should return nil when agent_root_name is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    session.update_column(:git_root, nil)
    session.reload

    assert_nil session.agent_root_path
  end

  test "agent_root_path should handle nested subdirectories" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/user/monorepo.git",
      subdirectory: "apps/backend/api"
    )

    assert_equal "monorepo/apps/backend/api", session.agent_root_path
  end

  # Test agent_root_key method
  test "agent_root_key returns the key stored in metadata" do
    session = sessions(:running)
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => "agent-orchestrator"))

    assert_equal "agent-orchestrator", session.agent_root_key
  end

  test "agent_root_key returns nil when session cannot be resolved to a catalog entry" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/unknown/repo.git"
    )

    assert_nil session.agent_root_key
  end

  # Test resolved_agent_root + inherited agent-root default accessors. These power
  # the detail UI fallback that surfaces a root's current defaults when a session's
  # own (frozen) catalog columns are blank.
  test "resolved_agent_root resolves the root through the catalog" do
    session = sessions(:running)
    mock_root = OpenStruct.new(name: "agent-orchestrator")
    AgentRootsConfig.stubs(:find_for_session).with(session).returns(mock_root)

    assert_same mock_root, session.resolved_agent_root
    assert_equal "agent-orchestrator", session.agent_root_key
  end

  # Resolution must NOT be memoized: it keys off mutable attributes, so a value
  # cached before those are set (e.g. agent_root_key assigned after build) would
  # go stale. Each call must reflect the session's current state.
  test "resolved_agent_root re-resolves and is not cached across attribute changes" do
    session = sessions(:running)
    AgentRootsConfig.stubs(:find_for_session).with(session).returns(nil).then.returns(OpenStruct.new(name: "agent-orchestrator"))

    assert_nil session.resolved_agent_root
    assert_equal "agent-orchestrator", session.resolved_agent_root&.name
  end

  test "agent_root_default_* expose the resolved root's current defaults" do
    session = sessions(:running)
    mock_root = OpenStruct.new(
      default_mcp_servers: [ "server-a" ],
      default_skills: [ "skill-a", "skill-b" ],
      default_hooks: [ "hook-a" ],
      default_plugins: [ "plugin-a" ]
    )
    AgentRootsConfig.stubs(:find_for_session).with(session).returns(mock_root)

    assert_equal [ "server-a" ], session.agent_root_default_mcp_servers
    assert_equal [ "skill-a", "skill-b" ], session.agent_root_default_skills
    assert_equal [ "hook-a" ], session.agent_root_default_hooks
    assert_equal [ "plugin-a" ], session.agent_root_default_plugins
  end

  test "agent_root_default_* return [] when the agent root cannot be resolved" do
    session = Session.new(prompt: "Test", git_root: "https://github.com/unknown/repo.git")
    AgentRootsConfig.stubs(:find_for_session).with(session).returns(nil)

    assert_equal [], session.agent_root_default_mcp_servers
    assert_equal [], session.agent_root_default_skills
    assert_equal [], session.agent_root_default_hooks
    assert_equal [], session.agent_root_default_plugins
  end

  # Test Turbo Stream broadcasts for sessions index page
  test "render_index_card_html renders archive_session_path for non-archived sessions" do
    session = sessions(:running) # Running session should show archive button

    rendered_html = session.send(:render_index_card_html)

    # Verify archive_session_path route helper works - should contain archive path
    # Non-archived sessions display a "Trash" button with this path
    assert_match(/archive/, rendered_html)
    assert_match(/\/sessions\/#{session.id}\/archive/, rendered_html)
  end

  test "render_index_card_html renders session_card partial wrapped in turbo frame" do
    session = sessions(:running)

    rendered_html = session.send(:render_index_card_html)

    # Verify the rendered HTML contains a turbo-frame tag with correct ID
    assert_match(/<turbo-frame/, rendered_html)
    assert_match(/id="#{ActionView::RecordIdentifier.dom_id(session)}"/, rendered_html)
    # Verify it contains session card content (prompt text)
    assert_match(/#{Regexp.escape(session.prompt)}/, rendered_html)
    # Verify status badge is present
    assert_match(/Running|Waiting|Needs Input|Trashed|Failed/i, rendered_html)
    # Verify route helpers work
    assert_match(/href="\/sessions\//, rendered_html)
  end

  test "broadcast_update broadcasts to the individual channel" do
    session = sessions(:running)

    individual_replaced = false

    original_broadcast_replace_to = session.method(:broadcast_replace_to)
    session.define_singleton_method(:broadcast_replace_to) do |channel, **opts|
      individual_replaced = true if channel == "sessions_index_individual"
      original_broadcast_replace_to.call(channel, **opts)
    end

    session.send(:broadcast_update_to_sessions_index)

    assert individual_replaced, "Expected broadcast to sessions_index_individual channel"
  end

  test "broadcast_create broadcasts to the individual channel" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Individual channel create test", title: "Individual channel", status: :waiting)
    session.save!

    individual_prepended = false

    original_broadcast_prepend_to = session.method(:broadcast_prepend_to)
    session.define_singleton_method(:broadcast_prepend_to) do |channel, **opts|
      individual_prepended = true if channel == "sessions_index_individual"
      original_broadcast_prepend_to.call(channel, **opts)
    end

    session.send(:broadcast_create_to_sessions_index)

    assert individual_prepended, "Expected broadcast to sessions_index_individual channel on create"
  end

  test "child session update broadcasts individual card to sessions_index_individual" do
    parent = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Parent", status: :running)
    child = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Child", parent_session_id: parent.id, status: :running)

    individual_replaced = false

    original_broadcast_replace_to = child.method(:broadcast_replace_to)
    child.define_singleton_method(:broadcast_replace_to) do |channel, **opts|
      individual_replaced = true if channel == "sessions_index_individual"
      original_broadcast_replace_to.call(channel, **opts)
    end

    child.send(:broadcast_update_to_sessions_index)

    assert individual_replaced, "Expected child session to broadcast its own card to sessions_index_individual"
  end

  test "status update triggers broadcast callback" do
    session = sessions(:running)
    original_status = session.status

    # Update status
    session.update!(status: :needs_input)

    # Verify the status changed (confirms the callback would have fired)
    assert_not_equal original_status, session.status
    assert_equal "needs_input", session.status
  end

  test "session creation triggers broadcast callback" do
    # Create a session and verify it persists (confirms after_create_commit would fire)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test broadcast on create", status: :waiting)

    assert session.persisted?
    assert_not_nil session.id
  end

  test "session destruction triggers broadcast callback" do
    session = sessions(:running)
    session_id = session.id

    # Destroy and verify it's gone (confirms after_destroy_commit would fire)
    session.destroy

    assert_nil Session.find_by(id: session_id)
  end


  # Test broadcast filtering - only broadcast when visible attributes change
  test "should_broadcast_to_index? returns true when status changes" do
    session = sessions(:running)
    session.status = :needs_input
    session.save!

    # The callback would have been called since status changed
    assert session.previous_changes.key?("status")
  end

  test "should_broadcast_to_index? returns true when title changes" do
    session = sessions(:running)
    session.title = "New Title"
    session.save!

    # The callback would have been called since title changed
    assert session.previous_changes.key?("title")
  end

  test "should_broadcast_to_index? returns true when slug changes" do
    session = sessions(:running)
    session.slug = "new-slug-#{Time.now.to_i}"
    session.save!

    # The callback would have been called since slug changed
    assert session.previous_changes.key?("slug")
  end

  test "should_broadcast_to_index? returns true when git_root changes" do
    session = sessions(:running)
    session.git_root = "https://github.com/different/repo.git"
    session.save!

    # The callback would have been called since git_root changed
    assert session.previous_changes.key?("git_root")
  end

  test "should_broadcast_to_index? returns true when prompt changes" do
    session = sessions(:running)
    session.prompt = "Updated prompt text"
    session.save!

    # The callback would have been called since prompt changed
    assert session.previous_changes.key?("prompt")
  end

  test "should_broadcast_to_index? returns true when mcp_servers changes" do
    session = sessions(:running)
    original_servers = session.mcp_servers.dup
    # Change to different servers
    session.mcp_servers = [ "playwright-custom", "context7", "twist-wolfbot" ]
    session.save!

    # Verify mcp_servers changed
    assert_not_equal original_servers, session.mcp_servers
    # The callback would have been called since mcp_servers changed
    assert session.previous_changes.key?("mcp_servers")
  end

  test "should NOT broadcast when only transcript changes" do
    session = sessions(:running)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update only transcript (not a visible attribute)
    session.update!(transcript: '{"role":"user","content":"Hello"}')

    # Broadcast should NOT have been called
    assert_not broadcast_called, "Expected broadcast to NOT be called when only transcript changes"
  end

  test "should broadcast when metadata changes" do
    session = sessions(:running)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update metadata (which is now visible in the UI via broadcast_message_count)
    session.update!(metadata: { "broadcast_message_count" => 42 })

    # Broadcast should have been called since metadata is now displayed in session cards
    assert broadcast_called, "Expected broadcast to be called when metadata changes"
  end

  test "should broadcast when title changes along with transcript" do
    session = sessions(:running)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update both title (visible) and transcript (not visible)
    session.update!(
      title: "New title",
      transcript: '{"role":"user","content":"Hello"}'
    )

    # Broadcast SHOULD have been called because title changed
    assert broadcast_called, "Expected broadcast to be called when title changes even if transcript also changes"
  end

  # Test broadcast_remove when session is archived (Issue #701)
  # When a session is archived, the index page filters it out by default,
  # so we need to broadcast a REMOVE action instead of REPLACE
  test "should broadcast remove when session is archived" do
    session = sessions(:running)

    # Track which broadcast method was called for the sessions_index channel
    remove_called = false
    sessions_index_replace_called = false

    session.define_singleton_method(:broadcast_remove_from_sessions_index) do
      remove_called = true
    end

    # Track the original method to call later
    original_broadcast_replace_to = session.method(:broadcast_replace_to)

    # Override broadcast_replace_to to detect if REPLACE was called for sessions_index channels
    session.define_singleton_method(:broadcast_replace_to) do |channel, **opts|
      if channel.start_with?("sessions_index_")
        sessions_index_replace_called = true
      end
      # Call original for other channels (e.g., session detail page broadcasts)
      original_broadcast_replace_to.call(channel, **opts)
    end

    # Archive the session - this should trigger broadcast_update_to_sessions_index
    # which should call broadcast_remove_from_sessions_index instead of broadcast_replace_to
    session.update!(status: :archived)

    # Verify remove was called, not replace for sessions_index
    assert remove_called, "Expected broadcast_remove_from_sessions_index to be called when session is archived"
    assert_not sessions_index_replace_called, "Expected broadcast_replace_to NOT to be called for sessions_index when session is archived"
  end

  test "should broadcast replace when session status changes to non-archived status" do
    session = sessions(:needs_input)

    # Track which broadcast method was called for the sessions_index channel
    remove_called = false
    sessions_index_replace_called = false

    session.define_singleton_method(:broadcast_remove_from_sessions_index) do
      remove_called = true
    end

    # Track the original method to call later
    original_broadcast_replace_to = session.method(:broadcast_replace_to)

    # Override broadcast_replace_to to detect if REPLACE was called for sessions_index channels
    session.define_singleton_method(:broadcast_replace_to) do |channel, **opts|
      if channel.start_with?("sessions_index_")
        sessions_index_replace_called = true
      end
      # Call original for other channels
      original_broadcast_replace_to.call(channel, **opts)
    end

    # Change to running status - should trigger broadcast_replace_to, not remove
    session.update!(status: :running)

    # Verify replace was called for sessions_index, not remove
    assert sessions_index_replace_called, "Expected broadcast_replace_to to be called for sessions_index channels when session status changes to non-archived"
    assert_not remove_called, "Expected broadcast_remove_from_sessions_index NOT to be called for non-archived status"
  end

  # Test git_root validations
  test "git_root should accept valid HTTPS URL with .git" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "https://github.com/user/repo.git"
    assert session.valid?
  end

  test "git_root should accept valid HTTPS URL without .git" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "https://github.com/user/repo"
    assert session.valid?
  end

  test "git_root should accept valid HTTP URL" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "http://github.com/user/repo.git"
    assert session.valid?
  end

  test "git_root should accept SSH URL with .git extension" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@github.com:user/repo.git"
    assert session.valid?
  end

  test "git_root should accept SSH URL without .git extension" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@github.com:user/repo"
    assert session.valid?
  end

  test "git_root should accept SSH URL with nested path" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@github.com:organization/user/repo.git"
    assert session.valid?
  end

  test "git_root should accept SSH URL with underscores" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git_user@github.com:org_name/repo_name.git"
    assert session.valid?
  end

  test "git_root should accept SSH URL with dots in username" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git.user@github.com:user/repo.git"
    assert session.valid?
  end

  test "git_root should accept local absolute path" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "/path/to/local/repo"
    assert session.valid?
  end

  test "git_root should reject SSH URL with multiple @ symbols" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@user@github.com:user/repo.git"
    assert_not session.valid?
    assert_includes session.errors[:git_root], "must be a valid URL or git path"
  end

  test "git_root should reject SSH URL without colon after hostname" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@github.com/user/repo.git"
    assert_not session.valid?
    assert_includes session.errors[:git_root], "must be a valid URL or git path"
  end

  test "git_root should reject SSH URL with invalid characters in username" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git user@github.com:user/repo.git"
    assert_not session.valid?
    assert_includes session.errors[:git_root], "must be a valid URL or git path"
  end

  test "git_root should reject SSH URL with invalid characters in hostname" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@git hub.com:user/repo.git"
    assert_not session.valid?
    assert_includes session.errors[:git_root], "must be a valid URL or git path"
  end

  test "git_root should reject SSH URL with special characters in path" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.git_root = "git@github.com:user/repo!@#.git"
    assert_not session.valid?
    assert_includes session.errors[:git_root], "must be a valid URL or git path"
  end

  # Test goal validations
  test "should accept nil goal" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.goal = nil
    assert session.valid?
  end

  test "should accept valid goal" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.goal = "All tests pass"
    assert session.valid?
  end

  test "should reject goal longer than maximum" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.goal = "a" * (Session::GOAL_MAX_LENGTH + 1)
    assert_not session.valid?
    assert_includes session.errors[:goal], "is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)"
  end

  test "should accept goal at exactly maximum length" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.goal = "a" * Session::GOAL_MAX_LENGTH
    assert session.valid?
  end

  test "should persist goal attribute" do
    goal = "PR is open and CI is green"
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      status: :waiting,
      goal: goal
    )

    session.reload
    assert_equal goal, session.goal
  end

  # === Session notes validation tests ===
  test "should accept valid session_notes" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.session_notes = "Some notes about this session"
    assert session.valid?
  end

  test "should reject session_notes longer than maximum" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.session_notes = "a" * 50_001
    assert_not session.valid?
    assert_includes session.errors[:session_notes], "is too long (maximum 50,000 characters)"
  end

  test "should accept session_notes at exactly maximum length" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.session_notes = "a" * 50_000
    assert session.valid?
  end

  test "should allow nil session_notes" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code", status: :waiting)
    session.session_notes = nil
    assert session.valid?
  end

  test "should persist session_notes attribute" do
    notes = "Important context about this task"
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      status: :waiting,
      session_notes: notes,
      session_notes_updated_at: Time.current
    )

    session.reload
    assert_equal notes, session.session_notes
    assert_not_nil session.session_notes_updated_at
  end

  # === Comprehensive tests for parsed_transcript method ===
  test "parsed_transcript should handle JSONL with newlines in strings" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = '{"role":"user","content":"Line 1\nLine 2\nLine 3"}'
    session.transcript = jsonl

    parsed = session.parsed_transcript
    assert_equal 1, parsed.length
    assert_includes parsed[0]["content"], "\n"
    assert_equal "Line 1\nLine 2\nLine 3", parsed[0]["content"]
  end

  test "parsed_transcript should handle complex tool messages" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = <<~JSONL.strip
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll read the file"},{"type":"tool_use","id":"tool1","name":"Read","input":{"file_path":"/path/to/file.rb"}}]}}
      {"type":"tool_result","tool_use_id":"tool1","content":"file contents here"}
    JSONL
    session.transcript = jsonl

    parsed = session.parsed_transcript
    assert_equal 2, parsed.length
    assert_equal "assistant", parsed[0]["type"]
    assert_equal "tool_result", parsed[1]["type"]
    assert_equal "tool1", parsed[1]["tool_use_id"]
  end

  test "parsed_transcript should handle multiple malformed lines gracefully" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = <<~JSONL.strip
      {"role":"user","content":"Good line 1"}
      {invalid json}
      not even json
      {"role":"assistant","content":"Good line 2"}
      {"incomplete":
    JSONL
    session.transcript = jsonl

    parsed = session.parsed_transcript
    assert_equal 2, parsed.length
    assert_equal "Good line 1", parsed[0]["content"]
    assert_equal "Good line 2", parsed[1]["content"]
  end

  test "parsed_transcript should handle whitespace-only lines" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    jsonl = <<~JSONL
      {"role":"user","content":"First"}

      \t
      {"role":"assistant","content":"Second"}
    JSONL
    session.transcript = jsonl

    parsed = session.parsed_transcript
    assert_equal 2, parsed.length
  end

  # === Tests for parsed_transcript_tail ===
  test "parsed_transcript_tail returns last N entries from JSONL transcript" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    lines = 10.times.map { |i| { "role" => "user", "content" => "Message #{i}", "timestamp" => "2025-11-12T12:00:#{i.to_s.rjust(2, '0')}Z" }.to_json }
    session.transcript = lines.join("\n")

    entries, total = session.parsed_transcript_tail(3)
    assert_equal 10, total
    assert_equal 3, entries.length
    assert_equal "Message 7", entries[0]["content"]
    assert_equal "Message 9", entries[2]["content"]
  end

  test "parsed_transcript_tail returns all entries when N exceeds total" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    lines = 3.times.map { |i| { "role" => "user", "content" => "Message #{i}" }.to_json }
    session.transcript = lines.join("\n")

    entries, total = session.parsed_transcript_tail(100)
    assert_equal 3, total
    assert_equal 3, entries.length
  end

  test "parsed_transcript_tail returns empty array when transcript is nil" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = nil

    entries, total = session.parsed_transcript_tail(10)
    assert_equal [], entries
    assert_equal 0, total
  end

  test "parsed_transcript_tail handles array transcript format" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = 5.times.map { |i| { "role" => "user", "content" => "Message #{i}" } }

    entries, total = session.parsed_transcript_tail(2)
    assert_equal 5, total
    assert_equal 2, entries.length
    assert_equal "Message 3", entries[0]["content"]
    assert_equal "Message 4", entries[1]["content"]
  end

  test "parsed_transcript_tail includes _transcript_index for JSONL" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    lines = 5.times.map { |i| { "role" => "user", "content" => "Message #{i}" }.to_json }
    session.transcript = lines.join("\n")

    entries, _total = session.parsed_transcript_tail(2)
    assert_equal 3, entries[0]["_transcript_index"]
    assert_equal 4, entries[1]["_transcript_index"]
  end

  # === Tests for transcript_line_count ===
  test "transcript_line_count returns 0 for nil transcript" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = nil
    assert_equal 0, session.transcript_line_count
  end

  test "transcript_line_count counts array transcript size" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = [ { "a" => 1 }, { "b" => 2 }, { "c" => 3 } ]
    assert_equal 3, session.transcript_line_count
  end

  test "transcript_line_count counts JSONL lines correctly" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}"
    assert_equal 3, session.transcript_line_count
  end

  test "transcript_line_count handles trailing newline" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"
    assert_equal 3, session.transcript_line_count
  end

  test "transcript_line_count handles single line" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = "{\"a\":1}"
    assert_equal 1, session.transcript_line_count
  end

  # === Tests for transcript regression guard ===
  test "Session.transcript_line_count counts arbitrary transcript values" do
    assert_equal 0, Session.transcript_line_count(nil)
    assert_equal 0, Session.transcript_line_count("")
    assert_equal 3, Session.transcript_line_count("{\"a\":1}\n{\"b\":2}\n{\"c\":3}")
    assert_equal 3, Session.transcript_line_count("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n")
    assert_equal 2, Session.transcript_line_count([ { "a" => 1 }, { "b" => 2 } ])
  end

  test "transcript_regression? is true only when incoming has fewer lines than stored" do
    stored = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}"
    shorter = "{\"a\":1}\n{\"b\":2}"
    longer = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}"
    same_count_different_content = "{\"x\":1}\n{\"y\":2}\n{\"z\":3}"

    assert Session.transcript_regression?(stored, shorter), "shrinking should be a regression"
    refute Session.transcript_regression?(stored, longer), "growth is not a regression"
    refute Session.transcript_regression?(stored, same_count_different_content), "same line count is not a regression"
    refute Session.transcript_regression?(stored, stored), "identical content is not a regression"
  end

  test "transcript_regression? treats blank stored as never a regression but shrinking to blank as one" do
    refute Session.transcript_regression?(nil, "{\"a\":1}"), "growing from blank is fine"
    refute Session.transcript_regression?("", ""), "blank to blank is fine"
    assert Session.transcript_regression?("{\"a\":1}\n{\"b\":2}", ""), "non-empty to blank loses history"
    assert Session.transcript_regression?("{\"a\":1}\n{\"b\":2}", nil), "non-empty to nil loses history"
  end

  # === Tests for parsed_transcript_range ===
  test "parsed_transcript_range returns entries in specified range" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    lines = 10.times.map { |i| { "role" => "user", "content" => "Message #{i}" }.to_json }
    session.transcript = lines.join("\n")

    entries = session.parsed_transcript_range(3, 6)
    assert_equal 3, entries.length
    assert_equal "Message 3", entries[0]["content"]
    assert_equal "Message 5", entries[2]["content"]
    assert_equal 3, entries[0]["_transcript_index"]
    assert_equal 5, entries[2]["_transcript_index"]
  end

  test "parsed_transcript_range returns empty array for nil transcript" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = nil
    assert_equal [], session.parsed_transcript_range(0, 5)
  end

  # === Comprehensive tests for formatted_conversation method ===
  test "formatted_conversation should handle user messages" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" }, "timestamp" => "2025-11-20T10:00:00Z" }
    ]
    session.transcript = transcript

    formatted = session.formatted_conversation
    assert_equal 1, formatted.length
    assert_equal "user", formatted[0][:role]
    assert_equal "Hello", formatted[0][:content]
    assert_equal "2025-11-20T10:00:00Z", formatted[0][:timestamp]
  end

  test "formatted_conversation should handle assistant messages with text" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [ { "type" => "text", "text" => "I can help with that" } ]
        },
        "timestamp" => "2025-11-20T10:00:05Z"
      }
    ]
    session.transcript = transcript

    formatted = session.formatted_conversation
    assert_equal 1, formatted.length
    assert_equal "assistant", formatted[0][:role]
    assert_equal "I can help with that", formatted[0][:content]
  end

  test "formatted_conversation should handle tool use messages" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "tool_use", "name" => "Read", "input" => { "description" => "Read test file", "command" => "cat test.rb" } }
          ]
        },
        "timestamp" => "2025-11-20T10:00:10Z"
      }
    ]
    session.transcript = transcript

    formatted = session.formatted_conversation
    assert_equal 1, formatted.length
    assert formatted[0][:has_tool_use]
    assert_includes formatted[0][:content], "**Using tool: Read**"
    assert_includes formatted[0][:content], "Read test file"
    assert_includes formatted[0][:content], "cat test.rb"
  end

  test "formatted_conversation should handle tool results" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "tool_result", "content" => "Result output here" }
          ]
        },
        "timestamp" => "2025-11-20T10:00:15Z"
      }
    ]
    session.transcript = transcript

    formatted = session.formatted_conversation
    assert_equal 1, formatted.length
    assert formatted[0][:has_tool_result]
    assert_includes formatted[0][:content], "**Tool Result:**"
    assert_includes formatted[0][:content], "Result output here"
  end

  test "formatted_conversation should handle mixed content (text + tool use)" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript = [
      {
        "type" => "assistant",
        "message" => {
          "role" => "assistant",
          "content" => [
            { "type" => "text", "text" => "Let me read that file" },
            { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/test.rb" } }
          ]
        },
        "timestamp" => "2025-11-20T10:00:20Z"
      }
    ]
    session.transcript = transcript

    formatted = session.formatted_conversation
    assert_equal 1, formatted.length
    assert_includes formatted[0][:content], "Let me read that file"
    assert_includes formatted[0][:content], "**Using tool: Read**"
    assert formatted[0][:has_tool_use]
  end

  test "formatted_conversation should skip empty content messages" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    transcript = [
      { "type" => "user", "message" => { "role" => "user", "content" => "" }, "timestamp" => "2025-11-20T10:00:00Z" },
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => [] }, "timestamp" => "2025-11-20T10:00:05Z" },
      { "type" => "user", "message" => { "role" => "user", "content" => "Valid message" }, "timestamp" => "2025-11-20T10:00:10Z" }
    ]
    session.transcript = transcript

    formatted = session.formatted_conversation
    assert_equal 1, formatted.length
    assert_equal "Valid message", formatted[0][:content]
  end

  test "formatted_conversation should handle empty transcript array" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    session.transcript = []

    assert_equal [], session.formatted_conversation
  end

  # === Additional agent_root_name tests ===
  test "agent_root_name should handle SSH URL with complex names" do
    session = Session.new(
      prompt: "Test",
      git_root: "git@github.com:org/my-awesome_repo-v2.git"
    )

    assert_equal "my-awesome_repo-v2", session.agent_root_name
  end

  test "agent_root_name should handle URLs with multiple trailing slashes" do
    session = Session.new(
      prompt: "Test",
      git_root: "https://github.com/user/repo///"
    )

    assert_equal "repo", session.agent_root_name
  end

  test "agent_root_name should handle local paths with trailing slashes" do
    session = Session.new(
      prompt: "Test",
      git_root: "/path/to/repo/"
    )

    assert_equal "repo", session.agent_root_name
  end

  test "agent_root_name should handle GitLab SSH URLs" do
    session = Session.new(
      prompt: "Test",
      git_root: "git@gitlab.com:group/project.git"
    )

    assert_equal "project", session.agent_root_name
  end

  test "agent_root_name should handle nested SSH URLs" do
    session = Session.new(
      prompt: "Test",
      git_root: "git@github.com:org/team/repo.git"
    )

    assert_equal "repo", session.agent_root_name
  end

  # === Additional generate_slug_from_title! tests ===
  test "generate_slug_from_title! should handle special characters" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      title: "Fix: API & Database Issues!"
    )

    session.generate_slug_from_title!

    assert_not_nil session.slug
    assert_match(/^fix-api-database-issues-\d{8}-\d{4}$/, session.slug)
  end

  # Regression for issue #4379: String#parameterize preserves underscores, but the
  # slug validation only permits /\A[a-z0-9-]+\z/. An underscore-bearing title used
  # to produce an invalid slug, raising RecordInvalid and logging a noisy .error.
  test "generate_slug_from_title! folds underscores in title into hyphens" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      title: "Debug audit_registry_data_freshness CI failure"
    )

    session.generate_slug_from_title!

    assert_not_nil session.slug
    assert_not_includes session.slug, "_", "slug must not contain underscores"
    assert_match(/\A[a-z0-9-]+\z/, session.slug, "slug must satisfy the validation regex")
    assert_match(/^debug-audit-registry-data-freshness-ci-failure-\d{8}-\d{4}$/, session.slug)
  end

  test "generate_slug_from_title! should ensure uniqueness with counter" do
    # Freeze time to ensure the manually-set slug and the generated slug share the same timestamp,
    # otherwise a minute boundary crossing makes this test flaky.
    travel_to Time.zone.local(2025, 6, 15, 14, 30) do
      first_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Same Title", slug: "same-title-20250615-1430")

      # Create second session with same title
      second_session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Same Title")
      second_session.generate_slug_from_title!

      assert_not_equal first_session.slug, second_session.slug
      assert_match(/^same-title-20250615-1430-\d+$/, second_session.slug)
    end
  end

  test "generate_slug_from_title! should handle Unicode characters" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Add support for emoji 🚀 and unicode ñ")

    session.generate_slug_from_title!

    assert_not_nil session.slug
    # Parameterize converts unicode to ASCII equivalents
    assert_match(/^add-support-for-emoji-and-unicode-n-\d{8}-\d{4}$/, session.slug)
  end

  test "generate_slug_from_title! should not regenerate if slug already exists" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Original Title", slug: "custom-slug")
    original_slug = session.slug

    session.generate_slug_from_title!

    assert_equal original_slug, session.slug
  end

  test "generate_slug_from_title! should not generate slug when title is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    session.update_columns(title: nil, slug: nil) # Force nil title and slug

    session.generate_slug_from_title!

    assert_nil session.slug
  end

  test "generate_slug_from_title! should not generate slug when title is blank" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    session.update_columns(title: "", slug: nil) # Force blank title and nil slug

    session.generate_slug_from_title!

    assert_nil session.slug
  end

  test "generate_slug_from_title! should include timestamp in slug" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Test Title")

    session.generate_slug_from_title!

    # Verify slug includes timestamp in format YYYYMMDD-HHMM
    assert_match(/test-title-\d{8}-\d{4}/, session.slug)
  end

  # === Comprehensive tests for to_param method ===
  test "to_param should return slug when slug is present" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Test", slug: "my-custom-slug")

    assert_equal "my-custom-slug", session.to_param
  end

  test "to_param should return id when slug is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    session.update_columns(slug: nil)

    assert_equal session.id.to_s, session.to_param
  end

  test "to_param should return id when slug is empty string" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    session.update_columns(slug: "")

    assert_equal session.id.to_s, session.to_param
  end

  test "to_param should prefer slug over id when both exist" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", slug: "my-slug")

    assert_equal "my-slug", session.to_param
    assert_not_equal session.id.to_s, session.to_param
  end

  # === Additional git_root_format validation tests ===
  test "git_root_format should accept SSH URLs with hyphens and underscores" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "git@github.com:my-org/my_project.git"
    )

    assert session.valid?
  end

  test "git_root_format should accept HTTP URLs" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "http://github.com/user/repo.git"
    )

    assert session.valid?
  end

  test "git_root_format should accept HTTPS URLs" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "https://github.com/user/repo.git"
    )

    assert session.valid?
  end

  test "git_root_format should accept local absolute paths" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "/Users/admin/projects/repo"
    )

    assert session.valid?
  end

  test "git_root_format should reject invalid URLs" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "not a valid url or path"
    )

    assert_not session.valid?
    assert_includes session.errors[:git_root], "must be a valid URL or git path"
  end

  test "git_root_format should accept SSH URLs with dots in hostname" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "git@git.example.com:user/repo.git"
    )

    assert session.valid?
  end

  test "git_root_format should accept SSH URLs with nested paths" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: "git@github.com:org/team/repo.git"
    )

    assert session.valid?
  end

  # === Tests for broadcast_status_change error handling ===
  # Issue #321: Ensure broadcast failures don't prevent session updates from background jobs

  test "broadcast_status_change has error handling that logs and does not raise" do
    session = sessions(:running)

    # Capture log output
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    begin
      # Directly test the broadcast_status_change method by mocking broadcast_replace_to to raise
      # This simulates the case where rendering fails
      session.stubs(:broadcast_replace_to).raises(StandardError, "Test broadcast failure")

      # Manually call the method (since we can't easily trigger it through update with stubbed broadcast_replace_to)
      # Should not raise - error should be caught and logged
      assert_nothing_raised do
        session.send(:broadcast_status_change)
      end

      # Check that error was logged (now logged per-component)
      log_content = log_output.string
      assert_match(/Broadcast status badge failed/, log_content)
      assert_match(/Test broadcast failure/, log_content)
    ensure
      Rails.logger = original_logger
    end
  end

  test "broadcast_status_change uses SessionsController render for follow_up_form" do
    session = sessions(:running)

    # Track what's passed to SessionsController.render
    render_calls = []
    original_render = SessionsController.method(:render)

    # Replace render with tracking version that also calls original
    SessionsController.define_singleton_method(:render) do |**args|
      render_calls << args
      # Return dummy HTML for follow_up_form partial to avoid route helper issues
      if args[:partial]&.include?("follow_up_form")
        "<div>stub html</div>"
      else
        original_render.call(**args)
      end
    end

    begin
      session.update!(status: :needs_input)

      # Verify SessionsController.render was called with the follow_up_form partial
      follow_up_render = render_calls.find { |c| c[:partial]&.include?("follow_up_form") }
      assert_not_nil follow_up_render, "Expected SessionsController.render to be called with follow_up_form partial"
      assert_equal session, follow_up_render[:locals][:agent_session]
    ensure
      SessionsController.define_singleton_method(:render, original_render)
    end
  end

  # Test that status broadcasts work correctly when multiple saves occur in a transaction.
  # This is a regression test for a bug where status changes were not broadcast when
  # session.resume! was followed by session.update!(metadata: ...) in the same transaction.
  # The saved_changes hash was reset after the metadata update, causing saved_change_to_status?
  # to return false when the after_update_commit callback ran.
  test "broadcast_status_change fires correctly when status change is followed by metadata update in transaction" do
    session = sessions(:needs_input)

    # Track if broadcast_status_change was called
    broadcast_called = false
    original_method = session.method(:broadcast_status_change)
    session.define_singleton_method(:broadcast_status_change) do
      broadcast_called = true
      original_method.call
    end

    # Stub the actual Turbo broadcast to avoid view rendering issues
    session.stubs(:broadcast_replace_to)

    # Simulate the pattern from GithubCommentPollerJob#send_prompt_immediately:
    # 1. Status changes (via resume!)
    # 2. Followed by metadata update
    # All within a transaction
    ActiveRecord::Base.transaction do
      session.status = :running
      session.save!
      session.update!(metadata: (session.metadata || {}).merge("pending_follow_up_prompt" => "test prompt"))
    end

    assert broadcast_called, "broadcast_status_change should have been called even after metadata update in same transaction"
    assert_equal "running", session.reload.status
  end

  # Test that the tracking flag is properly cleared after the callback runs
  test "status_changed_in_transaction tracking is cleared after callback" do
    session = sessions(:running)
    session.stubs(:broadcast_replace_to)

    # First update with status change
    session.update!(status: :needs_input)

    # Verify tracking was cleared
    assert_nil session.instance_variable_get(:@status_changed_in_transaction),
      "Tracking flag should be nil after callback runs"

    # Second update without status change should NOT trigger status broadcast
    broadcast_called = false
    original_method = session.method(:broadcast_status_change)
    session.define_singleton_method(:broadcast_status_change) do
      broadcast_called = true
      original_method.call
    end

    session.update!(metadata: { "foo" => "bar" })
    refute broadcast_called, "broadcast_status_change should NOT be called when status didn't change"
  end

  # === Tests for broadcast_metadata_change ===
  # Broadcasts clone_path to session detail page when it's first set

  test "should_broadcast_metadata_change? returns true when clone_path is newly set" do
    session = sessions(:running)
    # Ensure no clone_path initially
    session.update_column(:metadata, { "auto_generated_title" => true })

    # Set clone_path for the first time
    session.metadata = session.metadata.merge("clone_path" => "/path/to/clone")
    session.save!

    # Verify the condition would have been true
    session.reload
    old_metadata = { "auto_generated_title" => true }
    new_metadata = { "auto_generated_title" => true, "clone_path" => "/path/to/clone" }

    # Simulate the saved_change check
    assert old_metadata.dig("clone_path").blank?
    assert new_metadata.dig("clone_path").present?
  end

  test "should_broadcast_metadata_change? returns false when clone_path already exists" do
    session = sessions(:running)
    # Set initial clone_path
    session.update_column(:metadata, { "clone_path" => "/old/path" })

    # Update clone_path to new value
    session.metadata = session.metadata.merge("clone_path" => "/new/path")
    session.save!

    # The condition should be false because clone_path already existed
    old_clone_path = "/old/path"
    new_clone_path = "/new/path"
    assert_not(old_clone_path.blank? && new_clone_path.present?)
  end

  test "should_broadcast_metadata_change? returns false when clone_path is not set" do
    session = sessions(:running)
    session.update_column(:metadata, { "auto_generated_title" => true })

    # Update metadata without clone_path
    session.metadata = session.metadata.merge("some_key" => "value")
    session.save!

    # The condition should be false because new clone_path is not present
    old_clone_path = nil
    new_clone_path = nil
    assert_not(old_clone_path.blank? && new_clone_path.present?)
  end

  test "should_broadcast_metadata_change? returns false when metadata changes but clone_path remains the same" do
    session = sessions(:running)
    # Set initial clone_path
    session.update_column(:metadata, { "clone_path" => "/path/to/clone", "auto_generated_title" => true })

    # Update metadata without changing clone_path
    session.metadata = session.metadata.merge("some_other_key" => "value")
    session.save!

    # The condition should be false because clone_path already existed (old is not blank)
    old_clone_path = "/path/to/clone"
    new_clone_path = "/path/to/clone"
    assert_not(old_clone_path.blank? && new_clone_path.present?)
  end

  # --- live_clone_paths: the GC "never reap a live session's clone" set ---

  test "live_clone_paths includes clones for running, waiting, and needs_input sessions" do
    running = sessions(:running)
    waiting = sessions(:waiting)
    idle = sessions(:needs_input)
    running.update_column(:metadata, { "clone_path" => "/clones/running-1" })
    waiting.update_column(:metadata, { "clone_path" => "/clones/waiting-1" })
    idle.update_column(:metadata, { "clone_path" => "/clones/idle-1" })

    paths = Session.live_clone_paths

    assert_includes paths, "/clones/running-1"
    assert_includes paths, "/clones/waiting-1"
    assert_includes paths, "/clones/idle-1"
  end

  test "live_clone_paths excludes clones for archived and failed sessions" do
    archived = sessions(:archived)
    failed = sessions(:failed)
    archived.update_column(:metadata, { "clone_path" => "/clones/archived-1" })
    failed.update_column(:metadata, { "clone_path" => "/clones/failed-1" })

    paths = Session.live_clone_paths

    assert_not_includes paths, "/clones/archived-1"
    assert_not_includes paths, "/clones/failed-1"
  end

  test "live_clone_paths normalizes non-canonical clone paths" do
    running = sessions(:running)
    running.update_column(:metadata, { "clone_path" => "/clones/foo/../foo/bar/" })

    paths = Session.live_clone_paths

    assert_includes paths, "/clones/foo/bar"
  end

  test "live_clone_paths ignores live sessions without a clone_path" do
    sessions(:running).update_column(:metadata, { "auto_generated_title" => true })
    sessions(:waiting).update_column(:metadata, {})

    paths = Session.live_clone_paths

    assert_kind_of Set, paths
    assert_not paths.include?(nil)
  end

  test "broadcast_metadata_change has error handling that logs and does not raise" do
    session = sessions(:running)

    # Capture log output
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    begin
      # Mock broadcast_replace_to to raise an error
      session.stubs(:broadcast_replace_to).raises(StandardError, "Test metadata broadcast failure")

      # Should not raise - error should be caught and logged
      assert_nothing_raised do
        session.send(:broadcast_metadata_change)
      end

      # Check that error was logged
      log_content = log_output.string
      assert_match(/Broadcast metadata change failed/, log_content)
      assert_match(/Test metadata broadcast failure/, log_content)
    ensure
      Rails.logger = original_logger
    end
  end

  test "broadcast_metadata_change uses SessionsController render for session_metadata partial" do
    session = sessions(:running)
    session.metadata = (session.metadata || {}).merge("clone_path" => "/test/clone/path")

    # Track what's passed to SessionsController.render
    render_calls = []
    original_render = SessionsController.method(:render)

    SessionsController.define_singleton_method(:render) do |**args|
      render_calls << args
      "<div>stub html</div>"
    end

    begin
      session.send(:broadcast_metadata_change)

      # Verify SessionsController.render was called with the session_metadata partial
      metadata_render = render_calls.find { |c| c[:partial]&.include?("session_metadata") }
      assert_not_nil metadata_render, "Expected SessionsController.render to be called with session_metadata partial"
      assert_equal session, metadata_render[:locals][:agent_session]

      # Verify broadcast includes select data so edit buttons render correctly
      assert metadata_render[:locals].key?(:servers_for_select), "Expected locals to include servers_for_select for edit buttons"
      assert metadata_render[:locals].key?(:catalog_skills_for_select), "Expected locals to include catalog_skills_for_select for edit buttons"
      assert metadata_render[:locals].key?(:available_models), "Expected locals to include available_models for edit buttons"
      assert metadata_render[:locals].key?(:goals_for_select), "Expected locals to include goals_for_select for edit buttons"
    ensure
      SessionsController.define_singleton_method(:render, original_render)
    end
  end

  # === Tests for recently_recovered? method ===
  # Issue #275: Auto-refresh Turbo Streams after session recovery

  test "recently_recovered? returns true when recovery log exists within 5 seconds" do
    session = sessions(:running)

    # Create a recovery log within the time window (5 seconds)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: abc123) - monitoring will resume in 5 seconds",
      created_at: 2.seconds.ago
    )

    assert session.recently_recovered?
  end

  test "recently_recovered? returns false when recovery log is older than 5 seconds" do
    session = sessions(:running)

    # Create a recovery log outside the time window (5 seconds)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: abc123) - monitoring will resume in 5 seconds",
      created_at: 10.seconds.ago
    )

    assert_not session.recently_recovered?
  end

  test "recently_recovered? returns false when no recovery logs exist" do
    session = sessions(:running)

    # Create a non-recovery log
    session.logs.create!(
      level: "info",
      content: "Some other log message",
      created_at: 2.seconds.ago
    )

    assert_not session.recently_recovered?
  end

  test "recently_recovered? returns false when recovery log is not info level" do
    session = sessions(:running)

    # Create a recovery log with wrong level
    session.logs.create!(
      level: "debug",
      content: "Recovery job enqueued (ActiveJob ID: abc123)",
      created_at: 2.seconds.ago
    )

    assert_not session.recently_recovered?
  end

  test "recently_recovered? returns false for session with no logs" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :running)

    assert_not session.recently_recovered?
  end

  test "recently_recovered? only matches content containing 'Recovery job enqueued'" do
    session = sessions(:running)

    # Create logs with similar but not matching content (within time window)
    session.logs.create!(
      level: "info",
      content: "Recovery complete",
      created_at: 2.seconds.ago
    )
    session.logs.create!(
      level: "info",
      content: "Job enqueued for processing",
      created_at: 2.seconds.ago
    )

    assert_not session.recently_recovered?
  end

  test "recently_recovered? returns true at boundary (4 seconds ago)" do
    session = sessions(:running)

    # Create a recovery log at 4 seconds ago (should be included since window is 5 seconds)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: xyz789)",
      created_at: 4.seconds.ago
    )

    assert session.recently_recovered?
  end

  test "recently_recovered? returns false just outside boundary (6 seconds ago)" do
    session = sessions(:running)

    # Create a recovery log at 6 seconds ago (should NOT be included since window is 5 seconds)
    session.logs.create!(
      level: "info",
      content: "Recovery job enqueued (ActiveJob ID: xyz789)",
      created_at: 6.seconds.ago
    )

    assert_not session.recently_recovered?
  end

  # === Tests for throttled last_timeline_entry_at broadcasts ===
  # Issue #499: Session cards should update last_timeline_entry_at with throttling

  test "should_broadcast_to_index? returns true when last_timeline_entry_at changes and no previous broadcast" do
    session = sessions(:running)

    # Ensure no previous broadcast timestamp
    session.update_column(:last_broadcast_to_index_at, nil)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update last_timeline_entry_at
    session.update!(last_timeline_entry_at: Time.current)

    # Broadcast should have been called
    assert broadcast_called, "Expected broadcast when last_timeline_entry_at changes and no previous broadcast"
  end

  test "should_broadcast_to_index? returns true when last_timeline_entry_at changes and last broadcast was >30s ago" do
    session = sessions(:running)

    # Set last broadcast to 31 seconds ago
    session.update_column(:last_broadcast_to_index_at, 31.seconds.ago)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update last_timeline_entry_at
    session.update!(last_timeline_entry_at: Time.current)

    # Broadcast should have been called
    assert broadcast_called, "Expected broadcast when last_timeline_entry_at changes and last broadcast was >30s ago"
  end

  test "should_broadcast_to_index? returns false when last_timeline_entry_at changes but last broadcast was <30s ago" do
    session = sessions(:running)

    # Set last broadcast to 29 seconds ago
    session.update_column(:last_broadcast_to_index_at, 29.seconds.ago)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update last_timeline_entry_at
    session.update!(last_timeline_entry_at: Time.current)

    # Broadcast should NOT have been called
    assert_not broadcast_called, "Expected no broadcast when last_timeline_entry_at changes but last broadcast was <30s ago"
  end

  test "should_broadcast_to_index? returns true when last_timeline_entry_at changes and last broadcast was exactly 30s ago" do
    session = sessions(:running)

    # Set last broadcast to exactly 30 seconds ago (boundary condition)
    session.update_column(:last_broadcast_to_index_at, 30.seconds.ago)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update last_timeline_entry_at
    session.update!(last_timeline_entry_at: Time.current)

    # Broadcast should have been called (>= 30 seconds)
    assert broadcast_called, "Expected broadcast when last_timeline_entry_at changes and last broadcast was exactly 30s ago"
  end

  test "broadcast_update_to_sessions_index records last_broadcast_to_index_at when last_timeline_entry_at changes" do
    session = sessions(:running)

    # Clear previous broadcast timestamp
    session.update_column(:last_broadcast_to_index_at, nil)

    # Update last_timeline_entry_at to trigger broadcast
    session.update!(last_timeline_entry_at: Time.current)

    # Verify broadcast timestamp was recorded
    session.reload
    assert_not_nil session.last_broadcast_to_index_at
    assert session.last_broadcast_to_index_at >= 1.second.ago
  end

  test "broadcast_update_to_sessions_index does not record timestamp when other attributes change" do
    session = sessions(:running)

    # Clear previous broadcast timestamp
    session.update_column(:last_broadcast_to_index_at, nil)

    # Update a different visible attribute (not last_timeline_entry_at)
    session.update!(title: "New Title")

    # Verify broadcast timestamp was NOT recorded (only tracks for last_timeline_entry_at throttling)
    session.reload
    assert_nil session.last_broadcast_to_index_at
  end

  test "status change broadcasts immediately even if last_timeline_entry_at broadcast was recent" do
    session = sessions(:running)

    # Set last broadcast to 5 seconds ago (within throttle window)
    session.update_column(:last_broadcast_to_index_at, 5.seconds.ago)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update status (should bypass throttle)
    session.update!(status: :needs_input)

    # Broadcast should have been called immediately
    assert broadcast_called, "Expected immediate broadcast for status change regardless of throttle"
  end

  test "BROADCAST_THROTTLE_INTERVAL is 30 seconds" do
    assert_equal 30.seconds, Session::BROADCAST_THROTTLE_INTERVAL
  end

  # === Tests for favorited attribute ===
  test "favorited should default to false" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    assert_equal false, session.favorited
  end

  test "favorited should be persistable" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :waiting)
    session.update!(favorited: true)
    session.reload
    assert_equal true, session.favorited
  end

  test "favorited change should trigger broadcast to index" do
    session = sessions(:running)

    # Track broadcast calls
    broadcast_called = false
    session.define_singleton_method(:broadcast_update_to_sessions_index) do
      broadcast_called = true
    end

    # Update favorited
    session.update!(favorited: true)

    # Broadcast should have been called
    assert broadcast_called, "Expected broadcast when favorited changes"
  end

  # === Tests for push_notifications_enabled attribute ===
  test "push_notifications_enabled should default to false" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test", agent_runtime: "claude_code")
    assert_equal false, session.push_notifications_enabled
  end

  test "push_notifications_enabled should be persistable" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :waiting)
    session.update!(push_notifications_enabled: true)
    session.reload
    assert_equal true, session.push_notifications_enabled
  end

  # Test process_next_enqueued_message! atomic claiming
  test "process_next_enqueued_message! returns nil when no pending messages exist" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )

    ActiveRecord::Base.transaction do
      result = session.process_next_enqueued_message!
      assert_nil result
    end
  end

  test "process_next_enqueued_message! claims and marks message as processing" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )
    session.enqueued_messages.create!(content: "First message", position: 1)
    session.enqueued_messages.create!(content: "Second message", position: 2)

    ActiveRecord::Base.transaction do
      message = session.process_next_enqueued_message!

      assert_not_nil message
      assert_equal "First message", message.content
      assert_equal "processing", message.status
    end
  end

  test "process_next_enqueued_message! claims messages in position order" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )
    # Create out of order to verify ordering works
    session.enqueued_messages.create!(content: "Third message", position: 3)
    session.enqueued_messages.create!(content: "First message", position: 1)
    session.enqueued_messages.create!(content: "Second message", position: 2)

    ActiveRecord::Base.transaction do
      message = session.process_next_enqueued_message!
      assert_equal "First message", message.content
      assert_equal 1, message.position
    end
  end

  test "process_next_enqueued_message! skips non-pending messages" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )
    # First message is already being processed
    session.enqueued_messages.create!(content: "First message", position: 1, status: "processing")
    session.enqueued_messages.create!(content: "Second message", position: 2, status: "pending")

    ActiveRecord::Base.transaction do
      message = session.process_next_enqueued_message!
      assert_equal "Second message", message.content
    end
  end

  test "process_next_enqueued_message! uses FOR UPDATE SKIP LOCKED for atomic claiming" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )
    session.enqueued_messages.create!(content: "Message 1", position: 1)
    session.enqueued_messages.create!(content: "Message 2", position: 2)

    # Simulate concurrent access by having two threads try to claim messages
    # The first thread should get Message 1, the second should get Message 2
    # due to SKIP LOCKED behavior
    messages_claimed = []
    threads = []

    2.times do
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            message = session.process_next_enqueued_message!
            if message
              messages_claimed << message.content
              # Hold the lock briefly to ensure the other thread sees it
              sleep 0.1
            end
          end
        end
      end
    end

    threads.each(&:join)

    # Both messages should have been claimed (no duplicates)
    assert_equal 2, messages_claimed.uniq.size
    assert_includes messages_claimed, "Message 1"
    assert_includes messages_claimed, "Message 2"
  end

  # ----- Session.with_session_lock advisory lock primitive -----
  #
  # The interrupt-race fix wraps the controller-side critical section in a
  # per-session Postgres advisory lock so that two interrupt requests on the
  # same session serialize, while interrupts on *different* sessions remain
  # parallel. These tests cover the primitive directly.

  test "with_session_lock requires a session_id" do
    assert_raises(ArgumentError) do
      Session.with_session_lock(nil) { :unreachable }
    end
  end

  test "with_session_lock yields and returns the block's value" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )

    result = Session.with_session_lock(session.id) { :ok }
    assert_equal :ok, result
  end

  test "with_session_lock serializes concurrent holders on the same session" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )

    # Use an atomic counter and a barrier-like sleep to detect overlap.
    # If the lock works, only one thread holds the critical section at a time,
    # so `inside` never exceeds 1.
    inside = Concurrent::AtomicFixnum.new(0)
    max_observed = Concurrent::AtomicFixnum.new(0)

    threads = 4.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Session.with_session_lock(session.id) do
            current = inside.increment
            max_observed.update { |old| [ old, current ].max }
            sleep 0.05 # hold the lock long enough that overlap would be visible
            inside.decrement
          end
        end
      end
    end

    Timeout.timeout(10) { threads.each(&:join) }

    assert_equal 1, max_observed.value,
      "Advisory lock should serialize holders — observed #{max_observed.value} concurrent holders"
  end

  # Note: cross-session non-blocking parallelism cannot be unit-tested under
  # Rails' transactional test framework (all threads share a single connection),
  # so threads inside `with_session_lock` serialize on the connection regardless
  # of which session_id they pass. The cross-session independence guarantee is
  # exercised end-to-end at the service layer in
  # Sessions::InterruptServiceTest#test_concurrent_interrupts_on_different_sessions_do_not_block_each_other,
  # which uses Timeout.timeout to fail loudly if the lock granularity were global.

  test "with_session_lock releases the lock on exception" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input
    )

    # Raise inside the block; the advisory lock is transaction-scoped, so the
    # transaction rolls back and the lock is released. A subsequent acquire
    # must succeed without blocking.
    assert_raises(RuntimeError) do
      Session.with_session_lock(session.id) { raise "boom" }
    end

    completed = false
    Timeout.timeout(5) do
      Session.with_session_lock(session.id) { completed = true }
    end
    assert completed, "Lock must be reacquirable after a prior holder raised"
  end

  # === Tests for enqueue_session_inference callback ===
  # SessionTitleJob now does BOTH title generation and category inference from a
  # single inference over the early transcript, so one job covers both pieces of
  # work. It is enqueued (with a 2-minute delay to let a transcript accumulate)
  # whenever the title is still the auto-generated placeholder OR the session is
  # uncategorized and a non-frozen category exists.
  include ActiveJob::TestHelper

  test "enqueue_session_inference enqueues SessionTitleJob for sessions with prompt" do
    assert_enqueued_with(job: SessionTitleJob) do
      Session.create!(
        prompt: "Fix the login bug",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :waiting
      )
    end
  end

  test "enqueue_session_inference schedules SessionTitleJob with a 2-minute delay" do
    Session.create!(
      prompt: "Fix the login bug",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :waiting
    )

    enqueued = enqueued_jobs.find { |j| j[:job] == SessionTitleJob }
    assert enqueued, "expected SessionTitleJob to be enqueued"
    assert enqueued[:at].present?, "expected the job to be scheduled in the future"
  end

  test "enqueue_session_inference does not enqueue SessionTitleJob for clone-only sessions" do
    assert_no_enqueued_jobs(only: SessionTitleJob) do
      Session.create!(
        prompt: nil,
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :needs_input
      )
    end
  end

  test "enqueue_session_inference still enqueues for title work when there are no categories" do
    # Auto-generated title is pending even with no category targets.
    assert_enqueued_with(job: SessionTitleJob) do
      Session.create!(
        prompt: "Fix the login bug",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :waiting
      )
    end
  end

  test "enqueue_session_inference enqueues for category work even when the title is explicitly set" do
    # An explicit title means no title work is pending, but an uncategorized
    # session with a non-frozen category still needs the inference for sorting.
    Category.create!(name: "Research")

    assert_enqueued_with(job: SessionTitleJob) do
      Session.create!(
        prompt: "Fix the login bug",
        title: "My Custom Title",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :waiting
      )
    end
  end

  test "enqueue_session_inference does not enqueue when title is explicit and no categories exist" do
    # No title work (explicit title) and no category targets: nothing to do.
    assert_no_enqueued_jobs(only: SessionTitleJob) do
      Session.create!(
        prompt: "Fix the login bug",
        title: "My Custom Title",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :waiting
      )
    end
  end

  test "enqueue_session_inference does not enqueue when title is explicit and every category is frozen" do
    Category.create!(name: "Backlog", is_frozen: true)

    assert_no_enqueued_jobs(only: SessionTitleJob) do
      Session.create!(
        prompt: "Fix the login bug",
        title: "My Custom Title",
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :waiting
      )
    end
  end

  test "enqueue_session_inference does not enqueue when title is explicit and the session is already categorized" do
    category = Category.create!(name: "Research")

    assert_no_enqueued_jobs(only: SessionTitleJob) do
      Session.create!(
        prompt: "Fix the login bug",
        title: "My Custom Title",
        category: category,
        agent_runtime: "claude_code",
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        status: :waiting
      )
    end
  end

  # create_from_agent_root!
  test "create_from_agent_root! creates session with agent root config" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: "my-subdir",
      default_mcp_servers: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_difference("Session.count", 1) do
      session = Session.create_from_agent_root!(
        agent_root_name: "test-root",
        prompt: "Do something"
      )

      assert_equal "Do something", session.prompt
      assert_equal "claude_code", session.agent_runtime
      assert_equal "https://github.com/test/repo.git", session.git_root
      assert_equal "main", session.branch
      assert_equal "my-subdir", session.subdirectory
      assert_equal [], session.mcp_servers
    end
  end

  test "create_from_agent_root! uses agent root default mcp_servers when none provided" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "slack-workspace" ]
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )

    assert_equal [ "slack-workspace" ], session.mcp_servers
  end

  test "create_from_agent_root! overrides mcp_servers when explicitly provided" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "slack-workspace" ]
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      mcp_servers: [ "playwright-custom" ]
    )

    assert_equal [ "playwright-custom" ], session.mcp_servers
  end

  test "create_from_agent_root! falls back to default mcp_servers when columns are empty arrays" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "agent-orchestrator-prod-sessions" ],
      default_skills: [ "zimmer-run-tests" ],
      default_hooks: [ "git-push-ci-reminder" ],
      default_plugins: [ "screenshots-videos" ]
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)
    ServersConfig.stubs(:exists?).with("agent-orchestrator-prod-sessions").returns(true)
    SkillsConfig.stubs(:exists?).returns(true)
    HooksConfig.stubs(:exists?).returns(true)
    PluginsConfig.stubs(:exists?).returns(true)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      mcp_servers: [],
      catalog_skills: [],
      catalog_hooks: [],
      catalog_plugins: []
    )

    assert_equal [ "agent-orchestrator-prod-sessions" ], session.mcp_servers
    assert_equal [ "zimmer-run-tests" ], session.catalog_skills
    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
    # Plugins must be persisted from default_plugins so a later --without-defaults
    # AIR prepare! can reconstruct the plugin-derived MCP servers.
    assert_equal [ "screenshots-videos" ], session.catalog_plugins
  end

  test "create_from_agent_root! can preserve an explicit empty mcp_servers override" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "agent-orchestrator-prod-sessions" ],
      default_skills: [],
      default_hooks: [],
      default_plugins: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      mcp_servers: [],
      preserve_empty_mcp_servers: true
    )

    assert_equal [], session.mcp_servers
  end

  test "create_from_agent_root! falls back to defaults for all columns when omitted" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "agent-orchestrator-prod-sessions" ],
      default_skills: [ "zimmer-run-tests" ],
      default_hooks: [ "git-push-ci-reminder" ],
      default_plugins: [ "screenshots-videos" ]
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )

    assert_equal [ "agent-orchestrator-prod-sessions" ], session.mcp_servers
    assert_equal [ "zimmer-run-tests" ], session.catalog_skills
    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
    assert_equal [ "screenshots-videos" ], session.catalog_plugins
  end

  test "create_from_agent_root! self-heals a model that is incompatible with the resolved runtime" do
    # Root pins codex but carries a Claude model — the model must be replaced with
    # codex's catalog default rather than persisted as an invalid pairing.
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_runtime: "codex",
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )

    assert_equal "codex", session.agent_runtime
    assert_equal ModelCatalog.default_for("codex"), session.config["model"]
  end

  test "create_from_agent_root! honors an explicit agent_runtime override and heals the model" do
    # Root defaults to claude_code/opus, but the caller forces codex; opus is invalid
    # for codex, so the model self-heals to codex's catalog default.
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_runtime: "claude_code",
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      agent_runtime: "codex"
    )

    assert_equal "codex", session.agent_runtime
    assert_equal ModelCatalog.default_for("codex"), session.config["model"]
  end

  # Non-empty explicit values still win over defaults for every column. mcp_servers,
  # catalog_skills, and catalog_plugins override a DIFFERENT non-empty default;
  # catalog_hooks overrides an empty default (only one non-excluded hook exists in
  # the catalog, so a distinct override value isn't available for that column).
  test "create_from_agent_root! explicit non-empty values override defaults for all columns" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "agent-orchestrator-prod-sessions" ],
      default_skills: [ "zimmer-run-tests" ],
      default_hooks: [],
      default_plugins: [ "screenshots-videos" ]
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      mcp_servers: [ "slack-workspace" ],
      catalog_skills: [ "zimmer-change-ai-artifact" ],
      catalog_hooks: [ "git-push-ci-reminder" ],
      catalog_plugins: [ "meeting-wrangling" ]
    )

    assert_equal [ "slack-workspace" ], session.mcp_servers
    assert_equal [ "zimmer-change-ai-artifact" ], session.catalog_skills
    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
    assert_equal [ "meeting-wrangling" ], session.catalog_plugins
  end

  test "create_from_agent_root! stores metadata" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      metadata: { source: "quick_prompt" }
    )

    assert_equal "quick_prompt", session.metadata["source"]
  end

  test "create_from_agent_root! stores custom_metadata" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      custom_metadata: { "parent_session_id" => 42 }
    )

    assert_equal 42, session.custom_metadata["parent_session_id"]
  end

  test "create_from_agent_root! enqueues AgentSessionJob" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.expects(:enqueue_new_session).once

    Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )
  end

  test "create_from_agent_root! raises when agent root not found" do
    AgentRootsConfig.stubs(:find!).raises(AgentRootsConfig::AgentRootNotFoundError.new("Not found"))

    assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      Session.create_from_agent_root!(
        agent_root_name: "nonexistent",
        prompt: "Test"
      )
    end
  end

  test "create_from_agent_root! sets goal when provided" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      goal: "PR is merged"
    )

    assert_equal "PR is merged", session.goal
  end

  # create_from_agent_root! with catalog_hooks
  test "create_from_agent_root! uses agent root default_hooks when none provided" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_skills: [],
      default_hooks: [ "git-push-ci-reminder" ],
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )

    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
  end

  test "create_from_agent_root! overrides catalog_hooks when explicitly provided" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_skills: [],
      default_hooks: [],
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      catalog_hooks: [ "git-push-ci-reminder" ]
    )

    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
  end

  test "create_from_agent_root! defaults catalog_hooks to empty array when root has none" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: []
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )

    assert_equal [], session.catalog_hooks
  end

  # create_from_agent_root! with agent_runtime override (Case B)
  test "create_from_agent_root! adopts the agent root's default_runtime when no override given" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_runtime: "claude_code"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test"
    )

    assert_equal "claude_code", session.agent_runtime
  end

  test "create_from_agent_root! explicit agent_runtime override wins over the root default" do
    # Root declares a runtime that would itself fail to resolve; the explicit
    # override must be used instead (and must NOT consult the root default), so a
    # successful create with the registered override proves precedence.
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_runtime: "would_raise_if_used"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      agent_runtime: "claude_code"
    )

    assert_equal "claude_code", session.agent_runtime
  end

  test "create_from_agent_root! blank agent_runtime override falls back to the root default" do
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_runtime: "claude_code"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    session = Session.create_from_agent_root!(
      agent_root_name: "test-root",
      prompt: "Test",
      agent_runtime: ""
    )

    assert_equal "claude_code", session.agent_runtime
  end

  test "create_from_agent_root! raises for an unregistered agent_runtime override" do
    # Proves the override is actually consumed and routed through RuntimeRegistry:
    # if the param were ignored, this would silently fall back to the root default
    # and succeed rather than raising.
    mock_agent_root = OpenStruct.new(
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [],
      default_runtime: "claude_code"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(mock_agent_root)
    AgentSessionJob.stubs(:enqueue_new_session)

    assert_raises(KeyError) do
      Session.create_from_agent_root!(
        agent_root_name: "test-root",
        prompt: "Test",
        agent_runtime: "no_such_runtime"
      )
    end
  end

  # agent_runtime validation tracks RuntimeRegistry
  test "agent_runtime validation accepts every registered runtime" do
    RuntimeRegistry.registered_runtimes.each do |runtime|
      session = Session.new(
        prompt: "Test",
        agent_runtime: runtime,
        git_root: "https://github.com/test/repo.git",
        branch: "main"
      )
      session.valid?
      assert_empty session.errors[:agent_runtime], "expected #{runtime.inspect} to be a valid agent_runtime"
    end
  end

  test "agent_runtime validation rejects an unregistered runtime" do
    session = Session.new(
      prompt: "Test",
      agent_runtime: "definitely_not_registered",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    assert_not session.valid?
    assert_includes session.errors[:agent_runtime], "definitely_not_registered is not a valid agent runtime"
  end

  # catalog_hooks broadcast
  test "broadcast_metadata_change includes catalog_hooks_for_select in locals" do
    session = sessions(:running)
    session.metadata = (session.metadata || {}).merge("clone_path" => "/test/clone/path")

    render_calls = []
    original_render = SessionsController.method(:render)

    SessionsController.define_singleton_method(:render) do |**args|
      render_calls << args
      "<div>stub html</div>"
    end

    begin
      session.send(:broadcast_metadata_change)

      metadata_render = render_calls.find { |c| c[:partial]&.include?("session_metadata") }
      assert_not_nil metadata_render
      assert metadata_render[:locals].key?(:catalog_hooks_for_select), "Expected locals to include catalog_hooks_for_select for edit buttons"
    ensure
      SessionsController.define_singleton_method(:render, original_render)
    end
  end

  # Tests for failed_before_initial_prompt?

  test "failed_before_initial_prompt? returns true for mcp_connection_failed" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "mcp_connection_failed" })
    assert session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns true for oauth_required" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "oauth_required" })
    assert session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns true for spawn_failed" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "spawn_failed" })
    assert session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns true for git_clone_failed" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "git_clone_failed" })
    assert session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns true for clone_validation_failed" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "clone_validation_failed" })
    assert session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns false for process_failed" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "process_failed" })
    assert_not session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns false for exception" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: { "failure_reason" => "exception" })
    assert_not session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns false when no failure_reason" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed, metadata: {})
    assert_not session.failed_before_initial_prompt?
  end

  test "failed_before_initial_prompt? returns false when metadata is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed)
    assert_not session.failed_before_initial_prompt?
  end

  # Tests for failure_summary / failure_detail

  test "failure_summary names failed MCP servers for mcp_connection_failed" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed,
      metadata: { "failure_reason" => "mcp_connection_failed" },
      custom_metadata: { "mcp_failed_servers" => [ { "name" => "good-eggs", "error" => "spawn ENOENT" }, { "name" => "tally", "error" => "401" } ] }
    )
    assert_equal "MCP server(s) failed to connect: good-eggs, tally", session.failure_summary
    assert_equal "good-eggs: spawn ENOENT; tally: 401", session.failure_detail
  end

  test "failure_summary falls back to generic text when no MCP servers recorded" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed,
      metadata: { "failure_reason" => "mcp_connection_failed" }
    )
    assert_equal "MCP server connection failed", session.failure_summary
    assert_nil session.failure_detail
  end

  test "failure_summary names servers for oauth_required" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed,
      metadata: { "failure_reason" => "oauth_required", "oauth_required_servers" => [ { "server_name" => "tally" } ] }
    )
    assert_equal "OAuth authorization required: tally", session.failure_summary
  end

  test "failure_summary humanizes other failure reasons" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed,
      metadata: { "failure_reason" => "git_clone_failed" }
    )
    assert_equal "Git clone failed", session.failure_summary
  end

  test "failure_summary returns nil when no failure_reason" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", status: :failed)
    assert_nil session.failure_summary
    assert_nil session.failure_detail
  end

  # Tests for setup_complete?

  test "setup_complete? returns true when both session_id and clone_path are present" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", session_id: "test-123", metadata: { "clone_path" => "/tmp/clone" })
    assert session.setup_complete?
  end

  test "setup_complete? returns false when session_id is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", metadata: { "clone_path" => "/tmp/clone" })
    assert_not session.setup_complete?
  end

  test "setup_complete? returns false when clone_path is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", session_id: "test-123", metadata: {})
    assert_not session.setup_complete?
  end

  test "setup_complete? returns false when both session_id and clone_path are nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", metadata: {})
    assert_not session.setup_complete?
  end

  test "setup_complete? returns false when metadata is nil" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    assert_not session.setup_complete?
  end

  # catalog_plugins tests
  test "catalog_plugins defaults to empty array" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
    assert_equal [], session.catalog_plugins
  end

  test "catalog_plugins must be an array" do
    session = Session.new(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      catalog_plugins: "not-an-array"
    )
    assert_not session.valid?
    assert_includes session.errors[:catalog_plugins], "must be an array"
  end

  test "catalog_plugins validates plugin ids exist in catalog" do
    session = Session.new(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      catalog_plugins: [ "nonexistent-plugin" ]
    )
    assert_not session.valid?
    assert session.errors[:catalog_plugins].any? { |msg| msg.include?("nonexistent-plugin") }
  end

  test "catalog_plugins accepts valid plugin ids" do
    session = Session.new(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      catalog_plugins: [ "ci-workflow" ]
    )
    session.valid?
    assert_empty session.errors[:catalog_plugins]
  end

  test "catalog_plugins accepts empty array" do
    session = Session.new(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      catalog_plugins: []
    )
    session.valid?
    assert_empty session.errors[:catalog_plugins]
  end

  # === STALE_RETRY_METADATA_KEYS inclusion tests ===

  test "exit_status is in STALE_RETRY_METADATA_KEYS so it gets cleared on resume" do
    assert_includes Session::STALE_RETRY_METADATA_KEYS, "exit_status",
      "exit_status must be cleared on resume/restart to prevent stale quota error messages from persisting"
  end

  # === all_mcp_servers / injected_mcp_servers tests ===

  test "all_mcp_servers returns configured servers when no injected servers" do
    session = sessions(:active_session)
    session.update!(mcp_servers: [ "playwright-custom", "remote-fs-screenshots" ], custom_metadata: {})

    assert_equal [ "playwright-custom", "remote-fs-screenshots" ], session.all_mcp_servers
  end

  test "all_mcp_servers combines configured and injected servers" do
    session = sessions(:active_session)
    session.update!(
      mcp_servers: [ "playwright-custom" ],
      custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator" ] }
    )

    result = session.all_mcp_servers
    assert_includes result, "playwright-custom"
    assert_includes result, "agent-orchestrator"
    assert_equal 2, result.length
  end

  test "all_mcp_servers includes MCP servers bundled by selected plugins" do
    session = sessions(:active_session)
    session.update!(
      mcp_servers: [ "remote-fs-screenshots" ],
      catalog_plugins: [ "figma-design-workflow" ],
      custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator-staging-self-session" ] }
    )

    result = session.all_mcp_servers
    assert_includes result, "remote-fs-screenshots"
    assert_includes result, "figma"
    assert_includes result, "image-diff"
    assert_includes result, "svg-tracer"
    assert_includes result, "playwright-custom"
    assert_includes result, "agent-orchestrator-staging-self-session"
  end

  test "user_selected_mcp_servers includes direct and plugin bundled servers but not injected servers" do
    session = sessions(:active_session)
    session.update!(
      mcp_servers: [ "remote-fs-screenshots" ],
      catalog_plugins: [ "figma-design-workflow" ],
      custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator-staging-self-session" ] }
    )

    result = session.user_selected_mcp_servers
    assert_includes result, "remote-fs-screenshots"
    assert_includes result, "figma"
    assert_includes result, "image-diff"
    assert_includes result, "svg-tracer"
    assert_includes result, "playwright-custom"
    refute_includes result, "agent-orchestrator-staging-self-session"
  end

  test "plugin_mcp_servers excludes direct servers but not injected servers" do
    session = sessions(:active_session)
    session.update!(
      catalog_plugins: [ "screenshots-videos" ],
      mcp_servers: [ "remote-fs-screenshots" ],
      custom_metadata: { "injected_mcp_servers" => [ "playwright-custom" ] }
    )

    assert_equal [ "playwright-custom" ], session.plugin_mcp_servers
  end

  test "plugin_mcp_servers returns empty array when no plugins are selected" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [], mcp_servers: [], custom_metadata: {})

    assert_equal [], session.plugin_mcp_servers
  end

  test "all_mcp_servers deduplicates servers present in both lists" do
    session = sessions(:active_session)
    session.update!(
      mcp_servers: [ "playwright-custom", "remote-fs-screenshots" ],
      custom_metadata: { "injected_mcp_servers" => [ "remote-fs-screenshots" ] }
    )

    result = session.all_mcp_servers
    assert_equal [ "playwright-custom", "remote-fs-screenshots" ], result
  end

  test "all_mcp_servers returns empty array when no servers configured" do
    session = sessions(:active_session)
    session.update!(mcp_servers: [], custom_metadata: {})

    assert_equal [], session.all_mcp_servers
  end

  test "injected_mcp_servers returns empty array when none injected" do
    session = sessions(:active_session)
    session.update!(custom_metadata: {})

    assert_equal [], session.injected_mcp_servers
  end

  test "injected_mcp_servers returns the injected list from custom_metadata" do
    session = sessions(:active_session)
    session.update!(custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator" ] })

    assert_equal [ "agent-orchestrator" ], session.injected_mcp_servers
  end

  test "injected_mcp_servers handles nil custom_metadata" do
    session = sessions(:active_session)
    session.write_attribute(:custom_metadata, nil)

    assert_equal [], session.injected_mcp_servers
  end

  test "all_mcp_servers handles nil custom_metadata" do
    session = sessions(:active_session)
    session.update!(mcp_servers: [ "playwright-custom" ])
    session.write_attribute(:custom_metadata, nil)

    assert_equal [ "playwright-custom" ], session.all_mcp_servers
  end

  # === plugin_derived_skills / plugin_derived_hooks / plugin_derived_mcp_servers ===

  test "plugin_derived_skills returns empty hash when no plugins selected" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [])

    assert_equal({}, session.plugin_derived_skills)
  end

  test "plugin_derived_skills maps skills to their contributing plugin" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [ "ci-workflow" ], catalog_skills: [])

    assert_equal({ "zimmer-run-tests" => "ci-workflow" }, session.plugin_derived_skills)
  end

  test "plugin_derived_skills excludes skills already directly selected" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [ "ci-workflow" ], catalog_skills: [ "zimmer-run-tests" ])

    assert_equal({}, session.plugin_derived_skills)
  end

  test "plugin_derived_hooks maps hooks to their contributing plugin" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [ "ci-workflow" ], catalog_hooks: [])

    assert_equal({ "git-push-ci-reminder" => "ci-workflow" }, session.plugin_derived_hooks)
  end

  test "plugin_derived_hooks excludes hooks already directly selected" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [ "ci-workflow" ], catalog_hooks: [ "git-push-ci-reminder" ])

    assert_equal({}, session.plugin_derived_hooks)
  end

  test "plugin_derived_mcp_servers maps servers to their contributing plugin" do
    session = sessions(:active_session)
    session.update!(catalog_plugins: [ "screenshots-videos" ], mcp_servers: [], custom_metadata: {})

    derived = session.plugin_derived_mcp_servers
    assert_equal "screenshots-videos", derived["playwright-custom"]
    assert_equal "screenshots-videos", derived["remote-fs-screenshots"]
  end

  test "plugin_derived_mcp_servers excludes servers already directly selected" do
    session = sessions(:active_session)
    session.update!(
      catalog_plugins: [ "screenshots-videos" ],
      mcp_servers: [ "playwright-custom" ],
      custom_metadata: {}
    )

    derived = session.plugin_derived_mcp_servers
    refute_includes derived.keys, "playwright-custom"
    assert_equal "screenshots-videos", derived["remote-fs-screenshots"]
  end

  test "plugin_derived_mcp_servers excludes servers already auto-injected" do
    session = sessions(:active_session)
    session.update!(
      catalog_plugins: [ "screenshots-videos" ],
      mcp_servers: [],
      custom_metadata: { "injected_mcp_servers" => [ "playwright-custom" ] }
    )

    derived = session.plugin_derived_mcp_servers
    refute_includes derived.keys, "playwright-custom"
    assert_equal "screenshots-videos", derived["remote-fs-screenshots"]
  end

  test "plugin_derived_skills first plugin in catalog_plugins wins on duplicate skill" do
    # Both plugins contribute the same skill; the order in catalog_plugins
    # determines which plugin is recorded as the source.
    session = sessions(:active_session)

    # Stub two fake plugins that share a skill
    fake_plugin_a = PluginsConfig::Plugin.new("plugin-a", { "skills" => [ "shared-skill" ] })
    fake_plugin_b = PluginsConfig::Plugin.new("plugin-b", { "skills" => [ "shared-skill" ] })

    PluginsConfig.stub(:find, ->(id) { id == "plugin-a" ? fake_plugin_a : fake_plugin_b }) do
      session.update_columns(catalog_plugins: [ "plugin-a", "plugin-b" ], catalog_skills: [])

      assert_equal({ "shared-skill" => "plugin-a" }, session.plugin_derived_skills)
    end
  end

  test "plugin_derived methods skip unknown plugin ids without raising" do
    session = sessions(:active_session)
    # update_columns bypasses validations so we can test resilience to stale plugin ids
    session.update_columns(catalog_plugins: [ "definitely-not-a-real-plugin" ])

    assert_equal({}, session.plugin_derived_skills)
    assert_equal({}, session.plugin_derived_hooks)
    assert_equal({}, session.plugin_derived_mcp_servers)
  end

  # ---- last_user_activity_at / touch_user_activity! ----

  test "last_user_activity_at falls back to created_at when no metadata stamp" do
    session = sessions(:running)
    assert_equal session.created_at.to_i, session.last_user_activity_at.to_i
  end

  test "last_user_activity_at returns metadata stamp when present" do
    session = sessions(:running)
    stamp = 5.minutes.ago
    session.update!(metadata: (session.metadata || {}).merge("last_user_activity_at" => stamp.iso8601))
    assert_in_delta stamp.to_i, session.last_user_activity_at.to_i, 1
  end

  test "last_user_activity_at handles unparseable timestamp by falling back to created_at" do
    session = sessions(:running)
    session.update!(metadata: (session.metadata || {}).merge("last_user_activity_at" => "not a timestamp"))
    assert_equal session.created_at.to_i, session.last_user_activity_at.to_i
  end

  test "touch_user_activity! writes ISO8601 stamp into metadata" do
    session = sessions(:running)
    freeze_time do
      session.touch_user_activity!
      assert_equal Time.current.iso8601, session.reload.metadata["last_user_activity_at"]
    end
  end

  test "touch_user_activity! preserves other metadata keys" do
    session = sessions(:running)
    session.update!(metadata: (session.metadata || {}).merge("some_other_key" => "preserved"))
    session.touch_user_activity!
    assert_equal "preserved", session.reload.metadata["some_other_key"]
  end

  # ---- touch_user_view! ----

  test "touch_user_view! writes ISO8601 stamp into last_user_activity_at" do
    session = sessions(:running)
    freeze_time do
      session.touch_user_view!
      assert_equal Time.current.iso8601, session.reload.metadata["last_user_activity_at"]
    end
  end

  test "touch_user_view! advances last_user_activity_at" do
    session = sessions(:running)
    session.update!(metadata: (session.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601))
    freeze_time do
      session.touch_user_view!
      assert_in_delta Time.current.to_i, session.reload.last_user_activity_at.to_i, 1
    end
  end

  test "touch_user_view! preserves other metadata keys" do
    session = sessions(:running)
    session.update!(metadata: (session.metadata || {}).merge("some_other_key" => "preserved"))
    session.touch_user_view!
    assert_equal "preserved", session.reload.metadata["some_other_key"]
  end

  test "touch_user_view! does not bump updated_at (uses update_column to avoid rebroadcast)" do
    session = sessions(:running)
    session.update_column(:updated_at, 1.day.ago)
    original_updated_at = session.reload.updated_at
    session.touch_user_view!
    assert_equal original_updated_at.to_i, session.reload.updated_at.to_i,
      "a mere view must not bump updated_at, otherwise it would fire index broadcasts"
  end
end
