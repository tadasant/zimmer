# frozen_string_literal: true

require "test_helper"

module Execution
  class ContextTest < ActiveSupport::TestCase
    setup do
      @session = sessions(:active_session)
    end

    test "creates valid context with required parameters" do
      context = Context.new(session: @session)

      assert_equal @session, context.session
      assert_equal @session.git_root, context.git_root
      assert_equal @session.branch, context.branch
      assert_equal @session.mcp_servers, context.mcp_servers
      assert_equal @session.prompt, context.prompt
    end

    test "can override git_root" do
      custom_url = "https://github.com/test/override.git"
      context = Context.new(session: @session, git_root: custom_url)

      assert_equal custom_url, context.git_root
    end

    test "can override branch" do
      custom_branch = "feature-branch"
      context = Context.new(session: @session, branch: custom_branch)

      assert_equal custom_branch, context.branch
    end

    test "defaults to main branch if session branch is nil" do
      @session.branch = nil
      context = Context.new(session: @session, branch: nil)

      assert_equal "main", context.branch
    end

    test "accepts working_dir parameter" do
      working_dir = "/tmp/test"
      context = Context.new(session: @session, working_dir: working_dir)

      assert_equal working_dir, context.working_dir
    end

    test "accepts and freezes options hash" do
      options = { timeout: 300, model: "claude-sonnet-4" }
      context = Context.new(session: @session, options: options)

      assert_equal 300, context.options[:timeout]
      assert_equal "claude-sonnet-4", context.options[:model]
      assert context.options.frozen?
    end

    test "is frozen after creation" do
      context = Context.new(session: @session)

      assert context.frozen?
    end

    test "converts to hash" do
      context = Context.new(session: @session)
      hash = context.to_h

      assert_equal @session.id, hash[:session_id]
      assert_equal @session.git_root, hash[:git_root]
      assert_equal @session.branch, hash[:branch]
      assert_equal @session.mcp_servers, hash[:mcp_servers]
      assert_equal @session.prompt, hash[:prompt]
    end

    test "returns provider_type from session" do
      @session.execution_provider = "local_filesystem"
      context = Context.new(session: @session)

      assert_equal :local_filesystem, context.provider_type
    end

    test "defaults to local_filesystem if provider not set" do
      @session.execution_provider = nil
      context = Context.new(session: @session)

      assert_equal :local_filesystem, context.provider_type
    end

    test "raises error if session is nil" do
      assert_raises(ArgumentError, "session cannot be nil") do
        Context.new(session: nil)
      end
    end

    test "raises error if prompt is empty" do
      @session.prompt = ""

      assert_raises(ArgumentError, "prompt cannot be empty") do
        Context.new(session: @session)
      end
    end

    test "raises error if git_root is empty" do
      @session.git_root = ""

      assert_raises(ArgumentError, "git_root cannot be empty") do
        Context.new(session: @session)
      end
    end

    test "raises error if branch is empty" do
      @session.branch = ""

      assert_raises(ArgumentError, "branch cannot be empty") do
        Context.new(session: @session, branch: nil)
      end
    end

    test "git_root is accessible from context" do
      context = Context.new(session: @session)

      # git_root should be accessible
      assert_equal @session.git_root, context.git_root
    end

    test "serializes all attributes to hash" do
      options = { timeout: 600, model: "claude-sonnet" }
      working_dir = "/custom/dir"

      context = Context.new(
        session: @session,
        working_dir: working_dir,
        options: options
      )

      hash = context.to_h

      # Verify all expected keys are present
      assert_equal @session.id, hash[:session_id]
      assert_equal @session.git_root, hash[:git_root]
      assert_equal @session.branch, hash[:branch]
      assert_equal @session.mcp_servers, hash[:mcp_servers]
      assert_equal @session.prompt, hash[:prompt]
      assert_equal working_dir, hash[:working_dir]
      assert_equal options, hash[:options]
    end

    test "context is immutable after creation" do
      context = Context.new(session: @session)

      # Verify context itself is frozen
      assert context.frozen?

      # Verify attributes cannot be changed
      assert_raises(FrozenError) do
        context.instance_variable_set(:@session, sessions(:running))
      end
    end

    test "options hash is frozen to prevent modification" do
      options = { timeout: 300, model: "claude-sonnet" }
      context = Context.new(session: @session, options: options)

      assert context.options.frozen?

      # Cannot modify the options hash after creation
      assert_raises(FrozenError) do
        context.options[:new_key] = "value"
      end
    end

    test "handles empty mcp_servers array" do
      @session.mcp_servers = []
      context = Context.new(session: @session)

      assert_equal [], context.mcp_servers
      assert_empty context.mcp_servers
    end

    test "handles complex mcp_servers configuration" do
      @session.mcp_servers = [ "playwright-custom", "twist-wolfbot", "context7" ]
      context = Context.new(session: @session)

      assert_equal 3, context.mcp_servers.length
      assert_includes context.mcp_servers, "playwright-custom"
      assert_includes context.mcp_servers, "twist-wolfbot"
      assert_includes context.mcp_servers, "context7"
    end

    test "validates session is not nil" do
      assert_raises(ArgumentError, "session cannot be nil") do
        Context.new(session: nil)
      end
    end

    test "validates prompt is not nil" do
      @session.prompt = nil

      assert_raises(ArgumentError, "prompt cannot be empty") do
        Context.new(session: @session)
      end
    end

    test "validates git_root is not nil" do
      @session.git_root = nil

      assert_raises(ArgumentError, "git_root cannot be empty") do
        Context.new(session: @session)
      end
    end


    test "defaults options to empty hash if not provided" do
      context = Context.new(session: @session)

      assert_equal({}, context.options)
      assert context.options.frozen?
    end

    test "preserves all session attributes" do
      context = Context.new(session: @session)

      # Verify context preserves all session data
      assert_equal @session.id, context.session.id
      assert_equal @session.agent_runtime, context.session.agent_runtime
      assert_equal @session.status, context.session.status
      assert_equal @session.config, context.session.config
      assert_equal @session.created_at, context.session.created_at
    end

    test "handles provider type conversion properly" do
      # String provider type
      @session.execution_provider = "local_filesystem"
      context = Context.new(session: @session)
      assert_equal :local_filesystem, context.provider_type

      # Symbol provider type (if stored as symbol)
      @session.execution_provider = "remote_sandbox"
      context = Context.new(session: @session)
      assert_equal :remote_sandbox, context.provider_type

      # Nil provider type defaults to local_filesystem
      @session.execution_provider = nil
      context = Context.new(session: @session)
      assert_equal :local_filesystem, context.provider_type

      # Empty string converts to symbol
      @session.execution_provider = ""
      context = Context.new(session: @session)
      assert_equal :"", context.provider_type
    end

    test "branch validation handles different scenarios" do
      # Valid branch from session
      @session.branch = "feature-123"
      context = Context.new(session: @session)
      assert_equal "feature-123", context.branch

      # Override with custom branch
      context = Context.new(session: @session, branch: "hotfix-456")
      assert_equal "hotfix-456", context.branch

      # Nil session branch uses default
      @session.branch = nil
      context = Context.new(session: @session)
      assert_equal "main", context.branch

      # Explicit nil override uses session branch
      @session.branch = "develop"
      context = Context.new(session: @session, branch: nil)
      assert_equal "develop", context.branch
    end
  end
end
