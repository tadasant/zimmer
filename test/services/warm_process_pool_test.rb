# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "open3"

# WarmProcessPool against real child processes and real git repositories.
#
# The process is test/fixtures/files/fake_stream_json_cli.rb: it answers control
# requests the way `claude -p --input-format stream-json` does and records every
# line it is sent, so these tests can say exactly what a warm process was told
# and in what order. That the real CLI makes no API call while idle and takes
# the prompt as its first turn is proven at runtime (the PR's Verification).
class WarmProcessPoolTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FAKE_CLI = Rails.root.join("test/fixtures/files/fake_stream_json_cli.rb").to_s
  ROUTER = "zimmer-orchestrator"

  setup do
    @test_dir = Rails.root.join("tmp", "test_warm_processes_#{SecureRandom.hex(8)}").to_s
    @clones_base = File.join(@test_dir, "clones")
    FileUtils.mkdir_p(@clones_base)
    ClonesDirectory.stubs(:base).returns(@clones_base)

    @saved_env = ENV.to_h.slice("WARM_ROUTER_PROCESSES", "CLAUDE_SESSION_CONFIG_DIR", "AGENT_SCRATCH_DIR", "ZIMMER_SESSION_CGROUP_ROOT")
    ENV.delete("WARM_ROUTER_PROCESSES")
    ENV["CLAUDE_SESSION_CONFIG_DIR"] = File.join(@test_dir, "claude-config")
    ENV["AGENT_SCRATCH_DIR"] = File.join(@test_dir, "session-scratch")
    ENV["ZIMMER_SESSION_CGROUP_ROOT"] = File.join(@test_dir, "no-cgroups")
    ClaudeTranscriptSource.stubs(:projects_root).returns(File.join(@test_dir, "projects"))

    # The health report reads what the worker published to the cache.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    AppSetting.editable.update!(warm_router_process_enabled: true)
    @origin = create_origin
    @processes = []
  end

  teardown do
    WarmProcessPool.reset!
    @processes.each { |entry| entry.terminate! }
    @saved_env.each_key { |key| ENV.delete(key) }
    @saved_env.each { |key, value| ENV[key] = value }
    FileUtils.rm_rf(@test_dir)
  end

  # == Configuration

  test "one process by default, clamped to two, and zero turns the pool off" do
    assert_equal 1, WarmProcessPool.size
    ENV["WARM_ROUTER_PROCESSES"] = "9"
    assert_equal 2, WarmProcessPool.size
    ENV["WARM_ROUTER_PROCESSES"] = "lots"
    assert_equal 1, WarmProcessPool.size
    ENV["WARM_ROUTER_PROCESSES"] = "0"
    assert_not WarmProcessPool.enabled?
  end

  test "the pool is off until the experimental setting is on" do
    AppSetting.editable.update!(warm_router_process_enabled: false)
    assert_not WarmProcessPool.enabled?
    assert_not WarmProcessPool.serves?(router_session)
  end

  test "only router sessions are served" do
    assert WarmProcessPool.serves?(router_session)
    assert WarmProcessPool.serves?(router_session(root: "zimmer-router"))
    assert_not WarmProcessPool.serves?(router_session(root: "zimmer"))
  end

  test "a session's configuration matches the template's unless it differs in something a live process cannot change" do
    session = router_session
    signature = WarmProcessPool.config_signature(session)

    session.config = { "model" => "sonnet" }
    assert_equal signature, WarmProcessPool.config_signature(session), "the model is patched at claim time"

    session.config = { "effort" => "max" }
    assert_not_equal signature, WarmProcessPool.config_signature(session), "a non-default effort starts cold"

    other = router_session
    other.catalog_skills = [ "open-pr" ]
    assert_not_equal signature, WarmProcessPool.config_signature(other)
  end

  # == The claim

  test "an empty pool is a miss, recorded on the session, and asks for a refill" do
    session = router_session

    assert_enqueued_with(job: WarmProcessPoolReplenishJob) do
      assert_nil WarmProcessPool.claim(session)
    end
    assert_equal "missed", session.reload.metadata["warm_process"]
  end

  test "a ready process whose configuration differs from the session's is left for the next one" do
    entry = WarmProcessPool.register(start_entry(signature: { "different" => true }))
    session = router_session

    assert_nil WarmProcessPool.claim(session)
    assert_equal "config_mismatch", session.reload.metadata["warm_process"]
    assert_includes WarmProcessPool.entries, entry
    assert entry.alive?
  end

  test "a claim takes the process and brings its clone to the branch tip" do
    entry = WarmProcessPool.register(start_entry)
    tip = commit_upstream("app/models/thing.rb" => "class Thing; end\n")

    claimed = WarmProcessPool.claim(router_session)

    assert_same entry, claimed
    assert_equal :claimed, claimed.state
    assert_empty WarmProcessPool.entries
    assert_equal tip, git(entry.clone_path, "rev-parse", "HEAD")
  end

  test "a claim refuses a process whose CLAUDE.md moved upstream, since the CLI read it at boot" do
    entry = WarmProcessPool.register(start_entry)
    commit_upstream("CLAUDE.md" => "# changed\n")
    session = router_session

    assert_nil WarmProcessPool.claim(session)
    assert_equal "boot_context_changed", session.reload.metadata["warm_process"]
    assert_not entry.alive?
    assert_not File.exist?(entry.clone_path), "a refused claim's clone is never the session's"
  end

  test "a process that has exited is discarded rather than claimed" do
    entry = WarmProcessPool.register(start_entry)
    entry.terminate!
    wait_until { !entry.alive? }
    session = router_session

    assert_nil WarmProcessPool.claim(session)
    assert_equal "stale", session.reload.metadata["warm_process"]
  end

  test "what the CLI read at boot: memory files above the working directory, .claude/, and the root's own subtree" do
    changed = ->(*paths, sub: nil) { WarmProcessPool.boot_context_changed?(paths, sub) }

    assert changed.call("CLAUDE.md")
    assert changed.call(".claude/settings.json")
    assert changed.call(".mcp.json")
    assert_not changed.call("app/models/session.rb")
    assert_not changed.call("docs/CLAUDE.md"), "a nested CLAUDE.md is read when its files are, not at boot"

    sub = "artifacts/agent-roots/router"
    assert changed.call("artifacts/agent-roots/router/skills/x/SKILL.md", sub: sub)
    assert changed.call("artifacts/CLAUDE.md", sub: sub)
    assert changed.call("AGENTS.md", sub: sub)
    assert changed.call("artifacts/.claude/settings.json", sub: sub)
    assert_not changed.call("artifacts/agent-roots/other/CLAUDE.md", sub: sub)
    assert_not changed.call("app/models/session.rb", sub: sub)
  end

  # == Delivery

  test "a delivery sends the system prompt, the session's servers and the prompt, and nothing before it" do
    entry = start_entry(model: "opus", boot_servers: { "zimmer" => { "url" => "https://z/mcp" } })
    session = router_session(config: { "model" => "sonnet" })
    write_mcp_json(entry, "zimmer" => { "url" => "https://z/mcp?session_id=#{session.id}" },
                          "zimmer-self-session" => { "url" => "https://z/mcp?tool_groups=self_session" })
    message = { type: "user", message: { role: "user", content: [ { type: "text", text: "route this" } ] } }.to_json

    WarmProcessPool.deliver!(entry, session: session, working_directory: entry.working_directory,
                                    append_system_prompt: "You are session #{session.id}", message_json: message)

    lines = received(entry)
    assert_equal %w[initialize mcp_set_servers set_model], lines.select { |l| l["type"] == "control_request" }.map { |l| l.dig("request", "subtype") }
    assert_equal "You are session #{session.id}", lines.first.dig("request", "appendSystemPrompt")
    assert_equal %w[zimmer zimmer-self-session], lines.second.dig("request", "servers").keys.sort
    assert_equal "sonnet", lines.third.dig("request", "model")

    users = lines.reject { |l| l["type"] == "control_request" }
    assert_equal 1, users.size, "the prompt is the only message the process is ever sent"
    assert_equal "route this", users.first.dig("message", "content", 0, "text")
    assert_equal "user", lines.last["type"], "nothing follows the prompt"

    wait_until { !entry.alive? }
    assert_not entry.alive?, "stdin closes after the prompt, so the process ends its turn and exits"
    env_file = File.read(entry.env_file_path)
    assert_includes env_file, "export AO_SESSION_SCRATCH_DIR=#{SessionScratchDirectory.path_for(session.id)}"
    assert_includes env_file, "export ELICITATION_SESSION_ID=#{session.id}"
    assert_equal "claimed", session.reload.metadata["warm_process"]
  end

  test "the model is left alone when the session wants the one the process booted with" do
    entry = start_entry(model: "opus")
    session = router_session(config: { "model" => "opus" })
    write_mcp_json(entry, {})

    deliver(entry, session)

    assert_not_includes received(entry).map { |l| l.dig("request", "subtype") }, "set_model"
  end

  test "a workspace that differs from the one the process booted in refuses before the prompt" do
    entry = start_entry
    write_mcp_json(entry, {})
    File.write(File.join(entry.working_directory, EnvFile::FILENAME), "SECRET=different\n")

    error = assert_raises(WarmProcessPool::Entry::Mismatch) { deliver(entry, router_session) }
    assert_equal "workspace_changed", error.reason
    assert_empty received(entry)
  end

  test "a session without a server the process booted with refuses before the prompt" do
    entry = start_entry(boot_servers: { "zimmer" => {}, "extra" => {} })
    write_mcp_json(entry, "zimmer" => {})

    error = assert_raises(WarmProcessPool::Entry::Mismatch) { deliver(entry, router_session) }
    assert_equal "mcp_servers_removed", error.reason
    assert_empty received(entry)
  end

  test "an account or token change since boot refuses before the prompt" do
    entry = start_entry(environment_key: "booted-on-another-account")
    write_mcp_json(entry, {})

    error = assert_raises(WarmProcessPool::Entry::Mismatch) { deliver(entry, router_session) }
    assert_equal "environment_changed", error.reason
  end

  test "a server that fails to connect, or a refused control request, refuses before the prompt" do
    entry = start_entry(env: { "FAKE_CLI_SET_SERVERS_ERROR" => "1" })
    write_mcp_json(entry, "zimmer" => {})
    error = assert_raises(WarmProcessPool::Entry::Mismatch) { deliver(entry, router_session) }
    assert_equal "mcp_set_servers_failed", error.reason
    assert(received(entry).none? { |l| l["type"] == "user" })

    refused = start_entry(env: { "FAKE_CLI_REFUSE" => "initialize" })
    write_mcp_json(refused, {})
    assert_raises(WarmProcessPool::Entry::ControlError) { deliver(refused, router_session) }
    assert(received(refused).none? { |l| l["type"] == "user" })
  end

  # == Directories

  test "the process's config and scratch directories move onto the session, and its old paths still reach them" do
    entry = start_entry
    session = router_session
    config_dir = ClaudeSessionConfigDirectory.ensure_for(entry.id)
    File.write(File.join(config_dir, ".claude.json"), "{}")
    SessionScratchDirectory.ensure_for(entry.id)

    WarmProcessPool.adopt_directories!(entry, session)

    assert File.directory?(ClaudeSessionConfigDirectory.path_for(session.id))
    assert_not File.symlink?(ClaudeSessionConfigDirectory.path_for(session.id))
    assert File.symlink?(ClaudeSessionConfigDirectory.path_for(entry.id))
    assert File.exist?(File.join(ClaudeSessionConfigDirectory.path_for(entry.id), ".claude.json"))
    assert File.symlink?(SessionScratchDirectory.path_for(entry.id))
    assert_equal File.realpath(SessionScratchDirectory.path_for(session.id)), File.realpath(SessionScratchDirectory.path_for(entry.id))
  end

  test "a session that already has a config directory keeps it, and refuses the process" do
    entry = start_entry
    session = router_session
    ClaudeSessionConfigDirectory.ensure_for(entry.id)
    ClaudeSessionConfigDirectory.ensure_for(session.id)

    error = assert_raises(WarmProcessPool::Entry::Mismatch) { WarmProcessPool.adopt_directories!(entry, session) }
    assert_equal "session_config_dir_exists", error.reason
  end

  test "abandoning a claimed process stops it and leaves the clone with the session" do
    entry = start_entry
    session = router_session

    WarmProcessPool.abandon!(entry, session: session, reason: "workspace_changed")

    wait_until { !entry.alive? }
    assert_not entry.alive?
    assert File.directory?(entry.clone_path)
    assert_not File.exist?(entry.dir)
    assert_equal "workspace_changed", session.reload.metadata["warm_process"]
  end

  test "finishing a claim that never delivered abandons it; finishing a delivered one only forgets it" do
    pending_entry = start_entry
    WarmProcessPool.finish!(pending_entry, session: router_session)
    wait_until { !pending_entry.alive? }
    assert_not pending_entry.alive?

    delivered = start_entry
    delivered.state = :delivered
    WarmProcessPool.finish!(delivered, session: router_session)
    assert delivered.alive?, "a delivered process is the session's turn"
  end

  # == The refill

  test "the refill replaces a process past its age and builds up to size" do
    old = WarmProcessPool.register(start_entry(created_at: 61.minutes.ago))
    stub_refill_environment(old)
    WarmProcessPool.expects(:build!).once.with { |template| template.is_a?(Session) }

    result = WarmProcessPool.replenish!

    assert_equal [ "aged_out" ], result[:recycled_reasons]
    assert_equal 1, result[:built]
    wait_until { !old.alive? }
    assert_not old.alive?
    assert_not File.exist?(old.clone_path)
  end

  test "turning the setting off recycles every process and builds none" do
    entry = WarmProcessPool.register(start_entry)
    AppSetting.editable.update!(warm_router_process_enabled: false)
    WarmProcessPool.expects(:build!).never

    result = WarmProcessPool.replenish!

    assert_equal [ "disabled" ], result[:recycled_reasons]
    assert_empty WarmProcessPool.entries
    assert_empty Rails.cache.read(WarmProcessPool::STATE_CACHE_KEY)[:entries]
  end

  test "a fresh, healthy process survives a refill untouched" do
    entry = WarmProcessPool.register(start_entry)
    stub_refill_environment(entry)
    WarmProcessPool.expects(:build!).never

    result = WarmProcessPool.replenish!

    assert_equal 0, result[:recycled]
    assert_equal [ entry ], WarmProcessPool.entries
    assert_equal [ "mcp_status" ], received(entry).map { |l| l.dig("request", "subtype") }
  end

  test "a process whose MCP server failed is recycled" do
    entry = WarmProcessPool.register(start_entry(env: { "FAKE_CLI_MCP_STATUS" => "failed" }))
    stub_refill_environment(entry)
    WarmProcessPool.stubs(:build!)

    assert_equal [ "mcp_failed" ], WarmProcessPool.replenish![:recycled_reasons]
  end

  test "the sweep removes what a previous worker left, and leaves a live process it does not know alone" do
    dead = start_entry
    dead.terminate!
    wait_until { !dead.alive? }
    write_state(dead)

    live = start_entry
    write_state(live)

    WarmProcessPool.send(:sweep_orphans!)

    assert_not File.exist?(dead.dir)
    assert_not File.exist?(dead.clone_path)
    assert File.exist?(live.dir), "a live process unknown here may be a claim in flight"
    assert live.alive?
  end

  test "the sweep drops an adopted process's symlinks once it has exited" do
    entry = start_entry
    session = router_session
    ClaudeSessionConfigDirectory.ensure_for(entry.id)
    SessionScratchDirectory.ensure_for(entry.id)
    WarmProcessPool.adopt_directories!(entry, session)
    write_state(entry, "adopted_session_id" => session.id)
    entry.terminate!
    wait_until { !entry.alive? }

    WarmProcessPool.send(:sweep_orphans!)

    assert_not File.symlink?(ClaudeSessionConfigDirectory.path_for(entry.id))
    assert_not File.symlink?(SessionScratchDirectory.path_for(entry.id))
    assert File.directory?(ClaudeSessionConfigDirectory.path_for(session.id)), "the session's own directory stays"
    assert File.directory?(entry.clone_path), "the clone is the session's"
  end

  # == The report

  test "the report counts router starts by outcome and carries the published state" do
    router_session.merge_metadata!("warm_process" => "claimed")
    router_session.merge_metadata!("warm_process" => "claimed")
    router_session.merge_metadata!("warm_process" => "missed")
    router_session.merge_metadata!("warm_process" => "config_mismatch")
    WarmProcessPool.register(start_entry)
    WarmProcessPool.send(:publish_state!)

    report = WarmProcessPool.report

    assert report[:enabled]
    assert_equal({ "claimed" => 2, "missed" => 1, "config_mismatch" => 1 }, report[:outcomes])
    assert_equal 1, report[:entries].size
    assert_equal "ready", report[:entries].first[:state]
  end

  private

  def router_session(root: ROUTER, config: nil)
    Session.create!(
      prompt: "route this",
      agent_runtime: "claude_code",
      status: :waiting,
      git_root: @origin,
      branch: "main",
      config: config,
      metadata: { "agent_root_key" => root }
    )
  end

  # A process the pool could hold: a fake CLI on a real pipe, in a real clone.
  def start_entry(signature: nil, model: "opus", boot_servers: {}, environment_key: nil, created_at: Time.current, env: {})
    id = "#{WarmProcessPool::ID_PREFIX}#{Time.now.to_i}-#{SecureRandom.hex(4)}"
    dir = File.join(WarmProcessPool.root_dir, id)
    FileUtils.mkdir_p(dir)
    clone_path = File.join(@clones_base, "repo-main-#{Time.now.to_i}-#{SecureRandom.hex(4)}")
    git(nil, "clone", "--quiet", @origin, clone_path)
    File.write(File.join(clone_path, EnvFile::FILENAME), "SECRET=one\n")

    stdout_path = File.join(dir, "stdout.jsonl")
    reader, writer = IO.pipe
    out = File.open(stdout_path, "w")
    pid = Process.spawn(env, RbConfig.ruby, FAKE_CLI, File.join(dir, "received.jsonl"), in: reader, out: out, pgroup: true)
    reader.close
    out.close

    entry = WarmProcessPool::Entry.new(
      id: id, pid: pid, stdin: writer, dir: dir, clone_path: clone_path, working_directory: clone_path,
      subdirectory: nil, claude_session_id: SecureRandom.uuid, model: model,
      config_signature: signature || WarmProcessPool.config_signature(router_session),
      environment_key: environment_key || WarmProcessPool.environment_key, account: nil,
      boot_servers: boot_servers, env_digest: Digest::SHA256.file(File.join(clone_path, EnvFile::FILENAME)).hexdigest,
      claude_dir_digest: WarmProcessPool.claude_dir_digest(clone_path), catalog_digest: "catalog",
      head: git(clone_path, "rev-parse", "HEAD"), stdout_path: stdout_path,
      stderr_log_path: File.join(clone_path, "claude_stderr.log"), created_at: created_at
    )
    @processes << entry
    entry
  end

  def deliver(entry, session)
    WarmProcessPool.deliver!(entry, session: session, working_directory: entry.working_directory,
                                    append_system_prompt: "prompt", message_json: { type: "user" }.to_json)
  end

  def write_mcp_json(entry, servers)
    File.write(File.join(entry.working_directory, McpJsonConfigFormat::MCP_CONFIG_FILENAME),
               JSON.generate(McpJsonConfigFormat::SERVERS_KEY => servers))
  end

  def write_state(entry, extra = {})
    File.write(File.join(entry.dir, "state.json"),
               JSON.generate({ "id" => entry.id, "created_at" => entry.created_at.iso8601, "clone_path" => entry.clone_path,
                               "pid" => entry.pid, "identity" => entry.identity }.merge(extra)))
  end

  def received(entry)
    path = File.join(entry.dir, "received.jsonl")
    wait_until { File.exist?(path) }
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  # Make the refill see the world the entry booted in.
  def stub_refill_environment(entry)
    WarmProcessPool.stubs(:template_session).returns(Session.new)
    WarmProcessPool.stubs(:config_signature).returns(entry.config_signature)
    WarmProcessPool.stubs(:environment_key).returns(entry.environment_key)
    WarmProcessPool.stubs(:catalog_digest).returns(entry.catalog_digest)
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Kernel.sleep(0.02)
    end
  end

  def create_origin
    work = File.join(@test_dir, "origin-work")
    bare = File.join(@test_dir, "origin.git")
    FileUtils.mkdir_p(work)
    git(work, "init", "--quiet", "--initial-branch=main")
    File.write(File.join(work, "CLAUDE.md"), "# router\n")
    git(work, "add", ".")
    git(work, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--quiet", "-m", "initial")
    git(nil, "clone", "--quiet", "--bare", work, bare)
    @work = work
    bare
  end

  def commit_upstream(files)
    files.each do |path, content|
      full = File.join(@work, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    git(@work, "add", ".")
    git(@work, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--quiet", "-m", "upstream")
    git(@work, "push", "--quiet", @origin, "main")
    git(@work, "rev-parse", "HEAD")
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, **(dir ? { chdir: dir } : {}))
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end
end
