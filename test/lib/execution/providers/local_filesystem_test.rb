# frozen_string_literal: true

require "test_helper"
require "open3"

module Execution
  module Providers
    # Note: nothing in app/ calls Execution:: — the live clone path is
    # AgentSessionJob -> GitCloneService. These tests cover the provider on its
    # own terms so the layer is not a black box, and in particular so the
    # pre-clone disk guard it shares with GitCloneService is exercised from both
    # call sites.
    #
    # The clone tests clone from a git repository created in a temp directory, so
    # they touch neither the network nor the real clones volume.
    class LocalFilesystemTest < ActiveSupport::TestCase
      setup do
        @tmp_root = File.join(Dir.tmpdir, "local-fs-provider-#{SecureRandom.hex(4)}")
        @clones_base = File.join(@tmp_root, "clones")
        FileUtils.mkdir_p(@clones_base)
        ClonesDirectory.stubs(:base).returns(@clones_base)

        # The guard shells out to df/du. The two tests below that care about it
        # override this stub; the rest should not depend on how much room the CI
        # host happens to have under /tmp.
        CloneDiskGuard.stubs(:ensure_space!)
      end

      teardown do
        FileUtils.rm_rf(@tmp_root) if @tmp_root && File.directory?(@tmp_root)
      end

      test "provider_type returns local_filesystem" do
        assert_equal :local_filesystem, build_provider.provider_type
      end

      test "provider responds to required interface methods" do
        provider = build_provider

        assert_respond_to provider, :setup
        assert_respond_to provider, :execute
        assert_respond_to provider, :cleanup
        assert_respond_to provider, :status
        assert_respond_to provider, :provider_type
      end

      test "status returns expected structure" do
        status = build_provider.status

        assert_kind_of Hash, status
        assert status.key?(:ready)
        assert status.key?(:provider)
        assert_equal :local_filesystem, status[:provider]
      end

      test "provider accepts context with all optional parameters" do
        context = Context.new(
          session: sessions(:active_session),
          working_dir: "/custom/dir",
          branch: "feature-branch",
          options: { timeout: 600, model: "claude-sonnet" }
        )
        provider = LocalFilesystem.new(context)

        assert_equal context, provider.context
        assert_equal "/custom/dir", provider.context.working_dir
        assert_equal "feature-branch", provider.context.branch
        assert_equal 600, provider.context.options[:timeout]
      end

      test "provider inherits from Base" do
        assert LocalFilesystem < Base
      end

      test "provider uses correct logger" do
        custom_logger = Logger.new(File::NULL)
        provider = LocalFilesystem.new(build_context, logger: custom_logger)

        assert_equal custom_logger, provider.logger
      end

      # --- setup ---------------------------------------------------------

      test "setup clones the repository into the clones directory" do
        provider = build_provider(git_root: local_repo)
        stub_air_prepare

        result = provider.setup

        assert result.success?, "expected setup to succeed, got: #{result.error}"
        assert File.directory?(provider.clone_path), "clone directory should exist"
        assert_equal "hello\n", File.read(File.join(provider.clone_path, "README.md"))
        assert provider.clone_path.to_s.start_with?(@clones_base),
          "clone should live under the configured clones base"
        assert_equal provider.clone_path.to_s, result.metadata[:clone_path]
      end

      test "setup checks disk space before cloning" do
        provider = build_provider(git_root: local_repo)
        stub_air_prepare
        CloneDiskGuard.expects(:ensure_space!)
          .with(repository_url: local_repo, base: @clones_base)
          .once

        assert provider.setup.success?
      end

      test "setup fails with the guard's message when the disk is full" do
        provider = build_provider(git_root: local_repo)
        CloneDiskGuard.stubs(:ensure_space!)
          .raises(CloneDiskGuard::InsufficientDiskSpaceError, "Not enough disk space to clone into /clones")

        result = provider.setup

        assert result.failure?
        assert_includes result.error, "Not enough disk space to clone into /clones"
        assert_empty Dir.children(@clones_base), "no clone directory should be left behind"
      end

      test "setup fails when the branch does not exist" do
        provider = build_provider(git_root: local_repo, branch: "no-such-branch")
        stub_air_prepare

        result = provider.setup

        assert result.failure?
        assert_includes result.error, "Failed to clone repository"
      end

      test "setup reports failure when MCP config generation raises" do
        provider = build_provider(git_root: local_repo)
        AirPrepareService.any_instance.stubs(:prepare!).raises(StandardError, "air blew up")

        result = provider.setup

        assert result.failure?
        assert_includes result.error, "air blew up"
      end

      test "status is ready only after setup wrote both the clone and the config" do
        provider = build_provider(git_root: local_repo)
        stub_air_prepare

        assert_not provider.status[:ready]

        provider.setup
        assert_not provider.status[:ready], "no .mcp.json on disk yet"

        FileUtils.touch(File.join(provider.clone_path, ".mcp.json"))
        assert provider.status[:ready]
      end

      # --- execute -------------------------------------------------------

      test "execute refuses to run before setup" do
        result = build_provider.execute

        assert result.failure?
        assert_equal "Clone not set up. Call setup first.", result.error
      end

      test "execute returns success with captured output" do
        provider = setup_provider
        provider.stubs(:run_claude_code_command).returns([ "all done", "", exit_status(0) ])

        result = provider.execute

        assert result.success?
        assert_equal "all done", result.output
        assert_equal 0, result.metadata[:exit_status]
        assert_equal provider.clone_path.to_s, result.metadata[:working_directory]
      end

      test "execute returns failure carrying the exit status and stderr" do
        provider = setup_provider
        provider.stubs(:run_claude_code_command).returns([ "partial", "boom", exit_status(3) ])

        result = provider.execute

        assert result.failure?
        assert_equal "boom", result.error
        assert_equal "partial", result.output
        assert_equal 3, result.exit_status
      end

      test "execute treats an unknown exit status as failure with a nil exit status" do
        provider = setup_provider
        provider.stubs(:run_claude_code_command).returns([ "", "", nil ])

        result = provider.execute

        assert result.failure?
        assert_nil result.exit_status
      end

      test "execute rescues exceptions from the subprocess" do
        provider = setup_provider
        provider.stubs(:run_claude_code_command).raises(Errno::ENOENT, "claude")

        result = provider.execute

        assert result.failure?
        assert_includes result.error, "Execution error:"
      end

      # --- cleanup -------------------------------------------------------

      test "cleanup removes the clone" do
        provider = setup_provider
        clone_path = provider.clone_path
        assert File.directory?(clone_path)

        result = provider.cleanup

        assert result.success?
        assert_not File.exist?(clone_path), "clone directory should be gone"
      end

      test "cleanup is a no-op when nothing was set up" do
        result = build_provider.cleanup

        assert result.success?
      end

      test "cleanup reports failure when removal raises" do
        provider = setup_provider
        provider.stubs(:remove_clone).raises(Errno::EACCES, "denied")

        result = provider.cleanup

        assert result.failure?
        assert_includes result.error, "Cleanup failed:"
      end

      private

      def build_context(git_root: nil, branch: nil)
        Context.new(
          session: sessions(:active_session),
          git_root: git_root,
          branch: branch
        )
      end

      def build_provider(git_root: nil, branch: nil)
        LocalFilesystem.new(build_context(git_root: git_root, branch: branch), logger: Logger.new(File::NULL))
      end

      # A provider whose setup has already run against the local fixture repo.
      def setup_provider
        provider = build_provider(git_root: local_repo)
        stub_air_prepare
        assert provider.setup.success?
        provider
      end

      # AirPrepareService shells out to `air prepare`, which clones the catalog
      # repo over the network. Out of scope here.
      def stub_air_prepare
        AirPrepareService.any_instance.stubs(:prepare!)
      end

      # A real git repository on disk with one commit on `main`, used as the
      # clone source so these tests never touch the network.
      def local_repo
        @local_repo ||= begin
          path = File.join(@tmp_root, "source-repo")
          FileUtils.mkdir_p(path)
          File.write(File.join(path, "README.md"), "hello\n")
          run!("git", "init", "--initial-branch=main", cwd: path)
          run!("git", "config", "user.email", "test@example.com", cwd: path)
          run!("git", "config", "user.name", "Test", cwd: path)
          run!("git", "add", "README.md", cwd: path)
          run!("git", "commit", "-m", "initial", cwd: path)
          path
        end
      end

      def run!(*command, cwd:)
        stdout, stderr, status = Open3.capture3(*command, chdir: cwd)
        raise "#{command.join(' ')} failed: #{stdout}#{stderr}" unless status.success?
      end

      # A real Process::Status with the given exit code, so SubprocessStatus is
      # exercised rather than stubbed.
      def exit_status(code)
        _pid, status = Process.wait2(Process.spawn("/bin/sh", "-c", "exit #{code}"))
        status
      end
    end
  end
end
