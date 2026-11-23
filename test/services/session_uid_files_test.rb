# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The file-side halves of SessionUid that need no uid switch: the read guard, the boot
# lockdown, the per-spawn handover, and the spawn argv with the flag off.
class SessionUidFilesTest < ActiveSupport::TestCase
  include FixtureHelpers

  AGENT = 20_001
  OTHER = 20_002

  def with_env(values)
    previous = ENV.to_h.slice(*values.keys)
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    values.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  def mode(path)
    File.lstat(path).mode & 0o7777
  end

  # --- PathGuard ---------------------------------------------------------------------

  # A sessions base with one isolated session root (s1, "owned" by AGENT), a transcript
  # link base, and a secret outside both. Ownership is stubbed by path, because a test
  # process cannot create files owned by other uids.
  def with_guard_tree
    Dir.mktmpdir do |dir|
      sessions = File.join(dir, "sessions")
      root = File.join(sessions, "s1")
      other = File.join(sessions, "s2")
      projects = File.join(dir, "projects")
      FileUtils.mkdir_p([ root, other, projects ])
      File.write(File.join(root, "agent.jsonl"), "agent line\n")
      File.write(File.join(root, "app-wrote.json"), "{}")
      File.write(File.join(other, "private"), "other session\n")
      File.write(File.join(dir, "secret"), "SECRET\n")

      owners = {
        root => AGENT, other => OTHER,
        File.join(root, "agent.jsonl") => AGENT,
        File.join(root, "app-wrote.json") => SessionUid::APP_UID,
        File.join(other, "private") => OTHER,
        File.join(dir, "secret") => SessionUid::APP_UID
      }
      owner_of = ->(path) { owners.fetch(File.realpath(path), SessionUid::APP_UID) }

      with_env("ZIMMER_SESSION_UID" => "1") do
        SessionUid::Lockdown.stub(:per_session_bases, [ sessions ]) do
          SessionUid::PathGuard.stub(:link_bases, [ projects ]) do
            SessionUid::PathGuard.stub(:owner, owner_of) do
              SessionUid::PathGuard.stub(:opened_owner, ->(io) { owner_of.call(File.readlink("/proc/self/fd/#{io.fileno}")) }) do
                yield dir, root, projects
              end
            end
          end
        end
      end
    end
  end

  test "the guard reads a session's own files and the app's files inside its root" do
    with_guard_tree do |_dir, root, _projects|
      assert_equal "agent line\n", SessionUid::PathGuard.read(File.join(root, "agent.jsonl"))
      assert_equal "{}", SessionUid::PathGuard.read(File.join(root, "app-wrote.json"))
    end
  end

  test "the guard refuses a session's symlink to an app secret" do
    with_guard_tree do |dir, root, _projects|
      File.symlink(File.join(dir, "secret"), File.join(root, "transcript.jsonl"))

      assert_raises(Errno::EACCES) { SessionUid::PathGuard.read(File.join(root, "transcript.jsonl")) }
      assert_raises(Errno::EACCES) { RealFileSystemAdapter.new.read(File.join(root, "transcript.jsonl")) }
      assert_equal({}, ClaudeCredentialStore.read(File.join(root, "transcript.jsonl")))
    end
  end

  test "the guard refuses a session's symlink to another session's file" do
    with_guard_tree do |dir, root, _projects|
      File.symlink(File.join(dir, "sessions", "s2", "private"), File.join(root, "stolen"))

      assert_raises(Errno::EACCES) { SessionUid::PathGuard.read(File.join(root, "stolen")) }
    end
  end

  test "the guard follows the app's transcript link into the session root and checks there" do
    with_guard_tree do |dir, root, projects|
      private_dir = File.join(root, "projects", "key")
      FileUtils.mkdir_p(private_dir)
      File.write(File.join(private_dir, "t.jsonl"), "line\n")
      File.symlink(File.join(dir, "secret"), File.join(private_dir, "evil.jsonl"))
      File.symlink(private_dir, File.join(projects, "key"))

      assert_equal "line\n", SessionUid::PathGuard.read(File.join(projects, "key", "t.jsonl"))
      assert_raises(Errno::EACCES) { SessionUid::PathGuard.read(File.join(projects, "key", "evil.jsonl")) }
    end
  end

  test "the guard leaves a root no session uid owns alone, and everything with the flag off" do
    with_guard_tree do |dir, _root, _projects|
      app_root = File.join(dir, "sessions", "s3")
      FileUtils.mkdir_p(app_root)
      File.symlink(File.join(dir, "secret"), File.join(app_root, "link"))

      assert_equal "SECRET\n", SessionUid::PathGuard.read(File.join(app_root, "link"))
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "f"), "x")
      with_env("ZIMMER_SESSION_UID" => nil) { assert_equal "x", RealFileSystemAdapter.new.read(File.join(dir, "f")) }
      # Blockless, as File.foreach: an Enumerator that still reads after the call returns.
      [ nil, "1" ].each do |flag|
        with_env("ZIMMER_SESSION_UID" => flag) { assert_equal [ "x" ], RealFileSystemAdapter.new.each_line(File.join(dir, "f")).to_a }
      end
    end
  end

  test "the guard refuses a FIFO instead of hanging on it" do
    with_guard_tree do |_dir, root, _projects|
      File.mkfifo(File.join(root, "pipe.jsonl"))

      assert_raises(Errno::EACCES) { SessionUid::PathGuard.read(File.join(root, "pipe.jsonl")) }
    end
  end

  test "writes below an isolated root never follow a symlink the session planted" do
    with_guard_tree do |dir, root, _projects|
      flags = File::WRONLY | File::CREAT | File::TRUNC
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(File.join(dir, "secret"), File.join(root, "stderr.log"))
      File.symlink(outside, File.join(root, ".bundle"))

      assert_raises(Errno::ELOOP) { SessionUid::PathGuard.open_for_write(File.join(root, "stderr.log"), flags) { |f| f.write("x") } }
      assert_raises(Errno::ELOOP, Errno::ENOTDIR) do
        SessionUid::PathGuard.open_for_write(File.join(root, ".bundle", "config"), flags) { |f| f.write("x") }
      end
      assert_equal "SECRET\n", File.read(File.join(dir, "secret")), "the app's file was overwritten"
      refute File.exist?(File.join(outside, "config")), "the write landed outside the session"

      File.mkfifo(File.join(root, "fifo.log"))
      assert_raises(Errno::EACCES, Errno::ENXIO) { SessionUid::PathGuard.open_for_write(File.join(root, "fifo.log"), flags) { |f| f.write("x") } }

      FileUtils.mkdir_p(File.join(root, "sub"))
      SessionUid::PathGuard.open_for_write(File.join(root, "sub", "ok"), flags) { |f| f.write("fine") }
      assert_equal "fine", File.read(File.join(root, "sub", "ok"))
    end
  end

  test "the credential store writes and locks without following a planted symlink" do
    with_guard_tree do |dir, root, _projects|
      File.symlink(File.join(dir, "secret"), File.join(root, ".credentials.json.#{Process.pid}.tmp"))

      assert_raises(Errno::ELOOP) { ClaudeCredentialStore.write_atomically(File.join(root, ".credentials.json"), { "a" => 1 }) }
      assert_equal "SECRET\n", File.read(File.join(dir, "secret"))
    end
  end

  # --- Lockdown ----------------------------------------------------------------------

  test "the lockdown leaves HOME traverse-only, the app's files private and the runtime reachable" do
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      rails_root = File.join(dir, "rails")
      clones = File.join(home, ".zimmer", "clones")
      old_clone = File.join(clones, "repo-main-1")
      claude = File.join(home, ".local", "share", "claude", "versions", "2.1.0")
      FileUtils.mkdir_p([ old_clone, File.join(home, ".ssh"), File.join(home, ".local", "state"),
                          File.dirname(claude), File.join(home, ".zimmer", "artifacts"), File.join(rails_root, "log") ])
      File.write(claude, "#!/bin/sh\n")
      File.write(File.join(home, ".claude.json"), "{}")
      [ home, old_clone, File.join(home, ".ssh"), File.join(home, ".local", "state"), File.join(rails_root, "log") ]
        .each { |path| File.chmod(0o755, path) }
      File.chmod(0o644, File.join(home, ".claude.json"))
      File.chmod(0o700, claude)

      SessionUid::Lockdown.stub(:per_session_bases, [ clones ]) do
        SessionUid::Lockdown.stub(:tool_paths, [ claude ]) do
          SessionUid::Lockdown.apply!(home: home, rails_root: rails_root)
          SessionUid::Lockdown.expose_tools!(home: home)
        end
      end

      assert_equal 0o711, mode(home)
      assert_equal 0o711, mode(File.join(home, ".zimmer"))
      assert_equal 0o711, mode(clones)
      assert_equal 0o700, mode(old_clone), "a clone from before the flag stayed readable to other users"
      assert_equal 0o700, mode(File.join(home, ".ssh"))
      assert_equal 0o600, mode(File.join(home, ".claude.json"))
      assert_equal 0o700, mode(File.join(home, ".local", "state"))
      assert_equal 0o700, mode(File.join(home, ".zimmer", "artifacts"))
      assert_equal 0o700, mode(File.join(rails_root, "log"))
      assert_equal 0o011, mode(File.join(home, ".local")) & 0o077
      assert_equal 0o011, mode(File.dirname(claude)) & 0o077
      assert_equal 0o005, mode(claude) & 0o005, "the claude binary is not executable by a session"
    end
  end

  # --- Sandbox -----------------------------------------------------------------------

  test "the handover moves a session's transcripts into its config dir, links them back, and chowns every root" do
    Dir.mktmpdir do |dir|
      clone = File.join(dir, "clones", "repo-main-1")
      shared_projects = File.join(dir, "shared-projects")
      cache = File.join(dir, "cache", "claude-cli-nodejs")
      FileUtils.mkdir_p([ clone, shared_projects ])
      key = PathSanitizer.sanitize(clone)
      FileUtils.mkdir_p(File.join(shared_projects, key))
      File.write(File.join(shared_projects, key, "abc.jsonl"), "old turn\n")

      env = { "CLAUDE_SESSION_CONFIG_DIR" => File.join(dir, "claude-config"),
              "AGENT_SCRATCH_DIR" => File.join(dir, "scratch"),
              "AGENT_SESSION_HOME_DIR" => File.join(dir, "homes") }
      session = create_session(metadata: { "clone_path" => clone })
      commands = []
      ok = Struct.new(:success?).new(true)

      with_env(env) do
        ClaudeTranscriptSource.stub(:projects_root, shared_projects) do
          PathSanitizer.stub(:cache_base, cache) do
            SessionUid::Lockdown.stub(:expose_tools!, nil) do
              Open3.stub(:capture3, ->(*argv) { commands << argv; [ "", "", ok ] }) do
                @home = SessionUid::Sandbox.new(session: session, uid: AGENT, working_dir: clone).prepare!
              end
            end
          end
        end

        config_dir = ClaudeSessionConfigDirectory.path_for(session.id)
        private_dir = File.join(config_dir, "projects", key)
        refute File.symlink?(File.join(config_dir, "projects")), "projects is still the shared symlink"
        assert_equal "old turn\n", File.read(File.join(private_dir, "abc.jsonl"))
        assert File.symlink?(File.join(shared_projects, key))
        assert_equal private_dir, File.readlink(File.join(shared_projects, key))
        assert_equal File.join(@home, ".cache", "claude-cli-nodejs", key), File.readlink(File.join(cache, key))
        assert_equal SessionHomeDirectory.path_for(session.id), @home

        handed = commands.map(&:last)
        [ clone, config_dir, SessionScratchDirectory.path_for(session.id), @home ].each do |root|
          assert_includes handed, root
          assert_equal 0o700, mode(root)
        end
        assert(commands.all? { |argv| argv.first(5) == [ "chown", "-R", "-P", "--from=1000", "#{AGENT}:#{AGENT}" ] })
      end
    end
  end

  # --- Spawn argv with the flag off ----------------------------------------------------

  class Spawner
    include CliSpawnEnv
    public :confine_session_command, :apply_session_memory_cgroup, :apply_session_uid_env

    def initialize(session_id)
      @zimmer_session_id = session_id
      @logger = Rails.logger
    end
  end

  test "without the flag the spawn argv and environment are exactly what they were" do
    session = create_session
    spawner = Spawner.new(session.id)
    command = [ "claude", "-p", "--output-format", "stream-json" ]

    with_env("ZIMMER_SESSION_UID" => nil) do
      assert_equal spawner.apply_session_memory_cgroup(command), spawner.confine_session_command(command, Dir.pwd)
      env = { "HOME" => "/home/rails", "SSH_PRIVATE_KEY_PATH" => "/k" }
      assert_equal env.dup, spawner.apply_session_uid_env(env, Dir.pwd)
    end
  end

  test "with the flag the uid drop is inside the cgroup wrapper, so the join happens as the app" do
    session = create_session
    spawner = Spawner.new(session.id)
    context = SessionUid::Context.new(session_id: session.id, uid: AGENT, home: "/h")
    cgroup = Object.new
    def cgroup.carved_out? = false
    def cgroup.prepare! = true
    def cgroup.stats = Struct.new(:limit_bytes).new(1)
    def cgroup.path = "/cg"
    def cgroup.enter_command(cmd) = [ "/bin/sh", "-c", "join", "cg", "/cg/cgroup.procs", *cmd ]

    SessionUid.stub(:context_for, context) do
      SessionMemoryCgroup.stub(:for, cgroup) do
        argv = spawner.confine_session_command([ "claude" ], Dir.pwd)

        assert_equal "/bin/sh", argv.first
        assert_equal "setpriv", argv[5]
        assert_includes argv, "--reuid=#{AGENT}"
        assert_equal "claude", argv.last
      end
    end
  end
end
