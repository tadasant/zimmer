require "application_system_test_case"
require "path_sanitizer"
require "mocha/minitest"

class SmokeTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    # Setup mock dependencies for system test
    @mock_process_manager = MockProcessManager.new
    @mock_fs = MockFileSystemAdapter.new

    # Setup test directories in mock file system
    home_dir = File.expand_path("~")
    @mock_fs.mkdir_p(File.join(home_dir, ".agent-orchestrator", "clones"))
    @mock_fs.mkdir_p(File.join(home_dir, ".claude", "projects"))

    # Configure mock process behavior for Claude CLI
    @mock_process_manager.spawn_hook = ->(command, options) do
      # Handle both forms: spawn(*command) and spawn(env, *command)
      # When env vars are provided, first element is a hash
      actual_command = command.first.is_a?(Hash) ? command[1..-1] : command

      if actual_command.first == "claude"
        # Extract session ID from command
        session_id_index = actual_command.index("--session-id") || actual_command.index("--resume")
        session_id = actual_command[session_id_index + 1] if session_id_index
        working_directory = options[:chdir]

        # Create fake transcript
        create_fake_transcript(session_id, working_directory) if session_id && working_directory

        # Create stderr log file if it's being redirected
        if options[:err] && options[:err].respond_to?(:path)
          # For mock testing, we just need to ensure the file exists
          stderr_path = File.join(working_directory, "claude_stderr.log")
          @mock_fs.write(stderr_path, "")
        end
      end
    end

    # Configure process wait behavior - return success immediately
    @mock_process_manager.wait_hook = ->(pid, flags) do
      status = MockProcessManager::MockStatus.new(0)
      [ pid, status ]
    end

    # Stub AoEventTriggerJob to a no-op. The fixtures include enabled
    # ao_event triggers; running this job inside perform_enqueued_jobs
    # cascades into creating new sessions, which exhausts the request
    # budget and prevents the form-submit redirect from arriving in time.
    # The smoke test isn't exercising trigger semantics — that's covered
    # by AoEventTriggerJob's own tests.
    AoEventTriggerJob.stubs(:perform_later)
  end

  teardown do
    # Reset to real implementations
    GitCloneService.file_system = nil
  end

  test "complete session creation and execution flow" do
    # Store mocks in accessible scope
    mock_fs = @mock_fs
    mock_process_manager = @mock_process_manager

    # Create a custom GitCloneService that simulates git clone
    original_create_clone = GitCloneService.method(:create_clone)

    # Override GitCloneService to simulate git without calling real git
    GitCloneService.define_singleton_method(:create_clone) do |repo_url, **options|
      # Use mock file system
      GitCloneService.file_system = mock_fs

      # Generate clone path
      repo_name = File.basename(repo_url, ".git")
      timestamp = Time.now.to_i
      random = SecureRandom.hex(4)
      clone_path = File.expand_path("~/.agent-orchestrator/clones/#{repo_name}-#{options[:branch]}-#{timestamp}-#{random}")

      # Create the clone directory structure in mock FS
      mock_fs.mkdir_p(clone_path)
      mock_fs.write(File.join(clone_path, "README.md"), "# Test Repository")

      working_directory = if options[:subdirectory].present?
        subdir_path = File.join(clone_path, options[:subdirectory])
        mock_fs.mkdir_p(subdir_path)
        subdir_path
      else
        clone_path
      end

      { clone_path: clone_path, working_directory: working_directory }
    end

    begin
      # Override AirPrepareService#prepare! to write a mock .mcp.json
      # (npx/air-cli is not available in system tests)
      original_air_prepare = AirPrepareService.instance_method(:prepare!)
      AirPrepareService.define_method(:prepare!) do
        mcp_config = {
          "mcpServers" => {
            "playwright-custom" => {
              "command" => "npx",
              "args" => [ "--prefix", "/tmp", "-y", "@anthropic/playwright-mcp-server" ]
            }
          }
        }
        mcp_path = File.join(working_directory, ".mcp.json")
        file_system.write(mcp_path, JSON.pretty_generate(mcp_config))
      end

      # Inject mock file system
      GitCloneService.file_system = mock_fs

      # Create a mock job that uses our injected dependencies
      original_job_new = AgentSessionJob.method(:new)
      AgentSessionJob.define_singleton_method(:new) do |*args|
        job = original_job_new.call(*args)
        job.process_manager = mock_process_manager
        job.file_system = mock_fs
        # The CLI adapter is now resolved lazily per-session (so Codex sessions
        # get the codex CLI). cli_adapter_for wires the resolved adapter with the
        # job's injected process_manager/file_system, so the mocks above flow
        # through to it — no need to touch job.cli_adapter directly (it's nil
        # until resolved).
        job
      end

      perform_enqueued_jobs do
        # === STEPS 1-6: Create session via form submission ===
        # Start from sessions index page and click "New Session" button
        visit root_path
        assert_selector "h1", text: "Agent Sessions"
        click_link "New Session"

        assert_selector "h1", text: "Create New Session"

        # Fill in the prompt
        fill_in "Initial Prompt", with: "List the files in the current directory"

        # Select the agents agent root (default selected, but exercise the
        # autocomplete code path explicitly — radios are hidden inputs)
        select_agent_root("agents")

        # Remove any auto-selected default MCP servers from the agent root
        # (e.g. some MCP servers require env vars not available in CI)
        all("[data-mcp-server-select-target='selectedContainer'] button[data-action*='removeServerFromTag']").each(&:click)

        # Select the playwright-custom MCP server using the multi-select dropdown
        # Click on the input to show the dropdown
        find("[data-mcp-server-select-target='input']").click
        # Click on the playwright-custom server in the dropdown
        find(".server-item[data-name='playwright-custom']").click
        # Wait for the selection to be added (look for the tag with title)
        assert_selector "[data-mcp-server-select-target='selectedContainer'] span", text: "Playwright Custom (Non-Stealth)"
        # Click elsewhere to close the dropdown (click on the Initial Prompt label)
        find("label", text: "Initial Prompt").click
        # Wait for dropdown to close
        assert_no_selector "[data-mcp-server-select-target='dropdown']:not(.hidden)"

        # Submit the form
        click_button "Create Session"

        # Should redirect to the session show page
        # Wait for session page to load - check we're on a session page
        assert_current_path(/\/sessions\/\d+/, wait: 10)

        # Get the created session from the URL
        session_id = current_path.match(/\/sessions\/(\d+)/)[1]
        session = Session.find(session_id)

        # Wait for session to complete
        wait_for_session_status(session, "needs_input", max_wait: 15)

        # === STEP 8: Assert filesystem artifacts ===
        clone_path = session.metadata["clone_path"]
        working_directory = session.metadata["working_directory"]

        assert_not_nil clone_path, "Clone path should be set in metadata"
        assert_not_nil working_directory, "Working directory should be set in metadata"
        assert @mock_fs.directory?(clone_path), "Clone directory should exist at #{clone_path}"
        assert @mock_fs.directory?(working_directory), "Working directory should exist at #{working_directory}"

        # Verify .mcp.json in the working directory
        mcp_config_path = File.join(working_directory, ".mcp.json")
        assert @mock_fs.exists?(mcp_config_path), ".mcp.json should exist at #{mcp_config_path}"

        mcp_config = JSON.parse(@mock_fs.read(mcp_config_path))
        assert_equal "npx",
                     mcp_config.dig("mcpServers", "playwright-custom", "command"),
                     "MCP config should have correct command"

        # Hooks generation removed - no longer needed

        # === STEP 7: Assert session state ===
        session.reload
        assert_equal "needs_input", session.status,
                     "Session should transition to needs_input after completion"
        assert session.logs.any?, "Session should have logs"
        assert session.transcript.present?, "Session should have transcript"

        # Verify transcript structure
        parsed_transcript = session.parsed_transcript
        assert parsed_transcript.length > 0, "Transcript should have messages"

        user_messages = parsed_transcript.select { |m| m["type"] == "user" }
        assistant_messages = parsed_transcript.select { |m| m["type"] == "assistant" }
        assert user_messages.any?, "Transcript should have user messages"
        assert assistant_messages.any?, "Transcript should have assistant messages"

        # === STEP 9: Assert UI ===
        # Page should already be showing the session
        assert_text "Model:"
        assert_selector "span", text: "Needs Input"
        assert_text "playwright-custom"

        # Test page reload
        visit session_path(session)
        assert_selector "span", text: "Needs Input"
        assert_text "playwright-custom"

        # === STEP 10: Assert mocked methods were called ===
        assert @mock_process_manager.spawned_processes.any?, "Process.spawn should have been called"
        spawned = @mock_process_manager.spawned_processes.first
        assert spawned[:command].include?("claude"), "spawn should have been called with 'claude' command"
        assert @mock_process_manager.killed_processes.any?, "Process.kill should have been called for cleanup"
      end
    ensure
      # Restore original methods
      GitCloneService.define_singleton_method(:create_clone, &original_create_clone)
      AgentSessionJob.define_singleton_method(:new, &original_job_new)
      AirPrepareService.define_method(:prepare!, original_air_prepare)
      GitCloneService.file_system = nil
    end
  end

  private

  # Wait for a session to reach a specific status
  def wait_for_session_status(session, expected_status, max_wait: 15)
    start_time = Time.now
    loop do
      session.reload
      break if session.status == expected_status
      break if (Time.now - start_time) > max_wait

      sleep 0.5
    end

    # Assert that we actually reached the expected status
    assert_equal expected_status, session.status,
                 "Expected session to reach '#{expected_status}' status within #{max_wait} seconds"
  end

  def create_fake_transcript(session_id, working_directory)
    # Calculate transcript directory the same way as the real service
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize(working_directory)
    transcript_dir = File.join(claude_projects_dir, sanitized_path)
    @mock_fs.mkdir_p(transcript_dir)

    transcript_file = File.join(transcript_dir, "conversation-#{session_id}.jsonl")
    transcript_content = []

    # User message
    transcript_content << {
      "type" => "user",
      "timestamp" => Time.now.iso8601,
      "message" => {
        "role" => "user",
        "content" => "List the files in the current directory"
      }
    }.to_json

    # Assistant message with tool use
    transcript_content << {
      "type" => "assistant",
      "timestamp" => (Time.now + 1.second).iso8601,
      "message" => {
        "role" => "assistant",
        "content" => [
          {
            "type" => "text",
            "text" => "I'll list the files in the current directory for you."
          },
          {
            "type" => "tool_use",
            "id" => "tool_1",
            "name" => "Bash",
            "input" => {
              "command" => "ls -la",
              "description" => "List files"
            }
          }
        ],
        "stop_reason" => "tool_use"
      }
    }.to_json

    # Tool result
    transcript_content << {
      "type" => "tool_result",
      "timestamp" => (Time.now + 2.seconds).iso8601,
      "message" => {
        "role" => "user",
        "content" => [
          {
            "type" => "tool_result",
            "tool_use_id" => "tool_1",
            "content" => "total 24\ndrwxr-xr-x  4 user  staff  128 Nov 16 10:00 .\ndrwxr-xr-x  3 user  staff   96 Nov 16 10:00 ..\n-rw-r--r--  1 user  staff  123 Nov 16 10:00 file1.txt\n-rw-r--r--  1 user  staff  456 Nov 16 10:00 file2.txt"
          }
        ]
      }
    }.to_json

    # Final assistant message
    transcript_content << {
      "type" => "assistant",
      "timestamp" => (Time.now + 3.seconds).iso8601,
      "message" => {
        "role" => "assistant",
        "content" => [
          {
            "type" => "text",
            "text" => "Here are the files in the current directory:\n- file1.txt\n- file2.txt"
          }
        ],
        "stop_reason" => "end_turn"
      }
    }.to_json

    @mock_fs.write(transcript_file, transcript_content.join("\n"))
  end
end
