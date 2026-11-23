# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# SessionUid's decisions, without switching uid. The boundary itself — that a process
# started through SessionUid.wrap really cannot read the worker's environment or the
# app's credentials — is test/services/session_uid_boundary_test.rb, which needs a
# container to be root in.
class SessionUidTest < ActiveSupport::TestCase
  include FixtureHelpers

  FLAG_ON = { "ZIMMER_SESSION_UID" => "1" }.freeze

  def with_env(values)
    keys = values.keys
    previous = ENV.to_h.slice(*keys)
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    keys.each { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  def status_file(cap_eff:, cap_amb: "0000000000000000")
    file = Tempfile.new("status")
    file.write("Name:\truby\nCapInh:\t0000000000000000\nCapPrm:\t#{cap_eff}\nCapEff:\t#{cap_eff}\nCapAmb:\t#{cap_amb}\n")
    file.flush
    file
  end

  # --- The flag and its scope ---------------------------------------------------------

  test "the flag is off unless it is exactly 1" do
    refute SessionUid.enabled?({})
    refute SessionUid.enabled?("ZIMMER_SESSION_UID" => "0")
    refute SessionUid.enabled?("ZIMMER_SESSION_UID" => "true")
    assert SessionUid.enabled?("ZIMMER_SESSION_UID" => "1")
  end

  test "a session is in scope only with the flag on, on a covered runtime, in a listed root" do
    session = create_session(metadata: { "agent_root_key" => "canary" })
    codex = create_session(agent_runtime: "codex", metadata: { "agent_root_key" => "canary" })

    refute SessionUid.applies_to?(session, {})
    assert SessionUid.applies_to?(session, FLAG_ON)
    refute SessionUid.applies_to?(codex, FLAG_ON), "codex keeps one CODEX_HOME for every session"
    assert SessionUid.applies_to?(session, FLAG_ON.merge("ZIMMER_SESSION_UID_ROOTS" => "other, canary"))
    refute SessionUid.applies_to?(session, FLAG_ON.merge("ZIMMER_SESSION_UID_ROOTS" => "other"))
  end

  test "the uid range defaults inside a 65536-id user namespace and never reaches the app's uid" do
    assert_equal 20_000..49_999, SessionUid.range({})
    assert SessionUid.range({}).last < 65_536
    assert_equal 20_000..49_999, SessionUid.range("ZIMMER_SESSION_UID_MIN" => "500")
    assert_equal 30_000..30_009, SessionUid.range("ZIMMER_SESSION_UID_MIN" => "30000", "ZIMMER_SESSION_UID_MAX" => "30009")
  end

  test "the entrypoint's default range is the module's" do
    entrypoint = Rails.root.join("bin/docker-entrypoint").read

    assert_includes entrypoint, %(zimmer_session_uid_min="${ZIMMER_SESSION_UID_MIN:-#{SessionUid::DEFAULT_MIN}}")
    assert_includes entrypoint, %(zimmer_session_uid_max="${ZIMMER_SESSION_UID_MAX:-#{SessionUid::DEFAULT_MAX}}")
  end

  test "the entrypoint grants the app exactly the capabilities the module checks for" do
    caps = Rails.root.join("bin/docker-entrypoint").read[/zimmer_caps="([^"]+)"/, 1]

    assert caps, "the entrypoint no longer names its capability set"
    assert_equal SessionUid::APP_CAPABILITIES.keys.sort, caps.split(",").map { |c| c.delete_prefix("+") }.sort
  end

  # --- Capabilities -------------------------------------------------------------------

  test "capable? needs every capability the app keeps" do
    all_bits = SessionUid::APP_CAPABILITIES.values.sum { |bit| 1 << bit }
    full = status_file(cap_eff: format("%016x", all_bits))
    missing_kill = status_file(cap_eff: format("%016x", all_bits & ~(1 << 5)))

    assert SessionUid.capable?(status_path: full.path)
    refute SessionUid.capable?(status_path: missing_kill.path)
    refute SessionUid.capable?(status_path: "/nonexistent/status")
  end

  test "an unprivileged test process is not capable" do
    refute SessionUid.capable? unless Process.uid.zero?
  end

  # --- Allocation ---------------------------------------------------------------------

  test "allocation hands distinct sessions distinct uids and is stable for one session" do
    env = FLAG_ON.merge("ZIMMER_SESSION_UID_MIN" => "30000", "ZIMMER_SESSION_UID_MAX" => "30002")
    a = create_session
    b = create_session

    uid_a = SessionUid.allocate!(a, env)
    uid_b = SessionUid.allocate!(b, env)

    assert_includes 30_000..30_002, uid_a
    assert_includes 30_000..30_002, uid_b
    refute_equal uid_a, uid_b
    assert_equal uid_a, SessionUid.allocate!(a.reload, env)
    assert_equal uid_a, a.reload.agent_uid
  end

  test "allocation refuses when the range is exhausted, and a released uid can be reused" do
    env = FLAG_ON.merge("ZIMMER_SESSION_UID_MIN" => "30000", "ZIMMER_SESSION_UID_MAX" => "30000")
    a = create_session
    b = create_session

    assert_equal 30_000, SessionUid.allocate!(a, env)
    assert_raises(SessionUid::Unavailable) { SessionUid.allocate!(b, env) }

    calls = []
    SessionUid.stub(:capable?, true) do
      SessionUid.stub(:system, ->(*argv, **) { calls << argv; true }) do
        with_env(env) { SessionUid.release!(a) }
      end
    end
    assert_nil a.reload.agent_uid
    assert_includes calls, [ "pkill", "-KILL", "-U", "30000" ], "a detached process kept the uid"
    assert(calls.any? { |argv| argv.first == "find" && argv.include?("/tmp") && argv.include?("-delete") })
    assert_equal 30_000, SessionUid.allocate!(b, env)
  end

  test "a uid is not freed by a process that cannot clear what it left behind" do
    a = create_session
    a.update_columns(agent_uid: 30_200)

    SessionUid.stub(:capable?, false) { SessionUid.release!(a) }
    assert_equal 30_200, a.reload.agent_uid
  end

  test "the database refuses two sessions on one uid" do
    a = create_session
    b = create_session
    a.update_columns(agent_uid: 30_100)

    assert_raises(ActiveRecord::RecordNotUnique) { b.update_columns(agent_uid: 30_100) }
  end

  # --- The argv -----------------------------------------------------------------------

  test "wrap drops to the uid, clears groups and capabilities, and sets no_new_privs" do
    argv = SessionUid.wrap([ "claude", "-p" ], uid: 20_001, env: {})

    assert_equal "setpriv", argv.first
    assert_includes argv, "--reuid=20001"
    assert_includes argv, "--regid=20001"
    assert_includes argv, "--clear-groups"
    assert_includes argv, "--inh-caps=-all"
    assert_includes argv, "--ambient-caps=-all"
    assert_includes argv, "--no-new-privs"
    assert_equal [ "claude", "-p" ], argv.last(2)
    assert_includes argv.join(" "), "umask 077"
  end

  test "wrap hands over the Docker socket group only when told to" do
    argv = SessionUid.wrap([ "claude" ], uid: 20_001, env: { "ZIMMER_SESSION_UID_DOCKER" => "1" })

    assert_includes argv, "--groups=1000"
    refute_includes argv, "--clear-groups"
  end

  test "strip_capabilities is the identity without the flag" do
    with_env("ZIMMER_SESSION_UID" => nil) do
      assert_equal [ "claude" ], SessionUid.strip_capabilities([ "claude" ])
    end
  end

  test "the isolated environment replaces HOME and drops the operator SSH key" do
    context = SessionUid::Context.new(session_id: 1, uid: 20_001, home: "/h/1")
    env = SessionUid.apply_env({ "HOME" => "/home/rails", "SSH_PRIVATE_KEY_PATH" => "/home/rails/.ssh/k" }, context)

    assert_equal "/h/1", env["HOME"]
    assert_equal "/h/1/.config/gh", env["GH_CONFIG_DIR"]
    assert env.key?("SSH_PRIVATE_KEY_PATH")
    assert_nil env["SSH_PRIVATE_KEY_PATH"]
  end

  # --- Flag off is today ---------------------------------------------------------------

  test "without the flag no session gets a context and no subprocess changes" do
    session = create_session

    with_env("ZIMMER_SESSION_UID" => nil) do
      assert_nil SessionUid.context_for(session.id, working_dir: Dir.pwd)
      assert_equal [ [ "git", "status" ], { "A" => "1" }, {} ],
        SessionUid.as_owner_of(Dir.pwd, [ "git", "status" ], { "A" => "1" })
      assert_nil SessionUid.owner_uid_for(Dir.pwd)
    end
    assert_nil session.reload.agent_uid
  end

  test "with the flag on but no capabilities an in-scope spawn refuses rather than run as the app" do
    session = create_session

    with_env("ZIMMER_SESSION_UID" => "1", "ZIMMER_SESSION_UID_ROOTS" => nil) do
      SessionUid.stub(:capable?, false) do
        error = assert_raises(SessionUid::Unavailable) { SessionUid.context_for(session.id, working_dir: Dir.pwd) }
        assert_match(/must start as root/, error.message)
      end
    end
  end

  test "git_target_dir reads -C before cwd" do
    assert_equal "/c", SessionUid.git_target_dir([ "git", "-C", "/c", "status" ], "/cwd")
    assert_equal "/cwd", SessionUid.git_target_dir([ "git", "status" ], "/cwd")
    assert_equal "/cwd", SessionUid.git_target_dir([ "bundle", "-C", "/c" ], "/cwd")
  end
end
