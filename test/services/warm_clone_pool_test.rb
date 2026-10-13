require "test_helper"
require "mocha/minitest"
require "open3"

# WarmClonePool against real local git repositories: the claim is a rename and a
# fetch, the refill is a clone, and both are only worth testing on real trees.
class WarmClonePoolTest < ActiveSupport::TestCase
  setup do
    @test_dir = Rails.root.join("tmp", "test_warm_clones_#{SecureRandom.hex(8)}").to_s
    @clones_base = File.join(@test_dir, "clones_base")
    FileUtils.mkdir_p(@clones_base)
    ClonesDirectory.stubs(:base).returns(@clones_base)
    CloneDiskGuard.stubs(:ensure_space!)

    @repo = create_repo
    @branch = "main"
    @previous_size = ENV["QUICK_ROUTER_WARM_CLONES"]
    ENV["QUICK_ROUTER_WARM_CLONES"] = "1"

    AgentRootsConfig.stubs(:router_root_name).returns("zimmer-orchestrator")
    stub_roots("zimmer-orchestrator" => @repo)
  end

  teardown do
    ENV["QUICK_ROUTER_WARM_CLONES"] = @previous_size
    FileUtils.rm_rf(@test_dir)
  end

  # --- size -------------------------------------------------------------------

  test "the pool is off outside deployed environments unless configured" do
    ENV["QUICK_ROUTER_WARM_CLONES"] = nil
    assert_equal 0, WarmClonePool.size
    assert_not WarmClonePool.enabled?

    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
    assert_equal 1, WarmClonePool.size
  end

  test "the configured size is clamped and a garbage value falls back to the default" do
    ENV["QUICK_ROUTER_WARM_CLONES"] = "40"
    assert_equal 5, WarmClonePool.size

    ENV["QUICK_ROUTER_WARM_CLONES"] = "lots"
    assert_equal 0, WarmClonePool.size
  end

  test "under the router scope, serves router sessions on the router's repository and nothing else" do
    %w[zimmer-orchestrator zimmer-router].each do |name|
      assert WarmClonePool.serves?(session_on(@repo, name))
    end
    assert_not WarmClonePool.serves?(session_on(@repo, "zimmer")),
      "a root sharing the router's repository must not take the router's clone under the router scope"
    assert_not WarmClonePool.serves?(session_on(@repo, nil))
    assert_not WarmClonePool.serves?(session_on("https://example.com/other.git", "zimmer-orchestrator"))
    assert_not WarmClonePool.serves?(session_on(@repo, "zimmer-orchestrator", branch: "feature"))

    ENV["QUICK_ROUTER_WARM_CLONES"] = "0"
    assert_not WarmClonePool.serves?(session_on(@repo, "zimmer-orchestrator"))
  end

  test "under the active scope, serves any session whose repository and branch are pooled" do
    other = create_repo("other-repo")
    stub_roots("zimmer-orchestrator" => @repo, "zimmer" => @repo, "general-agent" => other, "artifacts" => create_repo("cold-repo"))
    record_starts("general-agent", WarmPoolPolicy::MIN_STARTS)
    record_starts("artifacts", 1)
    activate!

    assert WarmClonePool.serves?(session_on(@repo, "zimmer")), "the router's key serves every root on it"
    assert WarmClonePool.serves?(session_on(other, "general-agent"))
    assert_not WarmClonePool.serves?(session_on(File.join(@test_dir, "cold-repo"), "artifacts")),
      "a key below MIN_STARTS is not pooled"
  end

  test "serves? answers false rather than raising when the policy cannot be read" do
    WarmPoolPolicy.stubs(:targets).raises(ActiveRecord::ConnectionNotEstablished)

    assert_not WarmClonePool.serves?(session_on(@repo, "zimmer-orchestrator"))
  end

  # --- replenish! -------------------------------------------------------------

  test "replenish builds one ready clone, and a second pass does nothing" do
    result = WarmClonePool.replenish!
    assert_equal 1, result[:built]

    entries = WarmClonePool.ready_entries(@repo, @branch)
    assert_equal 1, entries.size
    assert File.exist?(File.join(entries.first, "README.md"))
    assert entries.first.start_with?(File.join(@clones_base, ".warm-clones")),
      "the pool must live under a dot directory, which the orphan sweep skips"

    assert_equal({ built: 0, recycled: 0, failed: nil }, WarmClonePool.replenish!)
  end

  test "replenish recycles a clone older than MAX_AGE" do
    WarmClonePool.replenish!
    stale = age_entry(WarmClonePool.ready_entries(@repo, @branch).first, WarmClonePool::MAX_AGE + 1.minute)

    result = WarmClonePool.replenish!

    assert_equal 1, result[:recycled]
    assert_equal 1, result[:built]
    assert_not File.exist?(stale)
    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size
  end

  test "replenish removes an abandoned build and leaves a recent one alone" do
    dir = WarmClonePool.key_dir(@repo, @branch)
    FileUtils.mkdir_p(dir)
    abandoned = File.join(dir, ".building-#{(Time.now - 2.hours).to_i}-aaaaaaaa")
    in_flight = File.join(dir, ".building-#{Time.now.to_i}-bbbbbbbb")
    FileUtils.mkdir_p([ abandoned, in_flight ])

    WarmClonePool.replenish!

    assert_not File.exist?(abandoned)
    assert File.exist?(in_flight)
  end

  test "replenish drops the pool of a repository that is no longer a target" do
    old = File.join(WarmClonePool.root_dir, "old-repo-main-0123456789ab", "#{Time.now.to_i}-cccccccc")
    FileUtils.mkdir_p(old)

    WarmClonePool.replenish!

    assert_not File.exist?(File.dirname(old))
  end

  test "replenish with the pool off builds nothing and clears what is there" do
    WarmClonePool.replenish!
    ENV["QUICK_ROUTER_WARM_CLONES"] = "0"

    assert_equal 0, WarmClonePool.replenish![:built]
    assert_empty WarmClonePool.ready_entries(@repo, @branch)
  end

  test "a failed build leaves no half-made clone behind and reports the failure" do
    missing = File.join(@test_dir, "no-such-repo")
    stub_roots("zimmer-orchestrator" => missing)

    result = WarmClonePool.replenish!

    assert_equal 0, result[:built]
    assert_match(/Git command failed/, result[:failed])
    dir = WarmClonePool.key_dir(missing, @branch)
    assert_empty Dir.exist?(dir) ? Dir.children(dir) : []
  end

  test "a clone past RECYCLE_AGE is replaced before it is removed, and stays claimable meanwhile" do
    WarmClonePool.replenish!
    aging = age_entry(WarmClonePool.ready_entries(@repo, @branch).first, WarmClonePool::RECYCLE_AGE + 1.minute)

    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-77777777")
    assert WarmClonePool.claim(@repo, @branch, into: into), "a clone younger than MAX_AGE is still claimable"
    FileUtils.rm_rf(into)

    WarmClonePool.replenish!
    aging = age_entry(WarmClonePool.ready_entries(@repo, @branch).first, WarmClonePool::RECYCLE_AGE + 1.minute)
    result = WarmClonePool.replenish!

    assert_equal({ built: 1, recycled: 1, failed: nil }, result)
    assert_not File.exist?(aging)
    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size
  end

  test "replenish builds nothing when the volume could not also hold an ordinary clone" do
    WarmClonePool.stubs(:room_to_build?).returns(false)

    result = WarmClonePool.replenish!

    assert_equal 0, result[:built]
    assert_match(/not enough free disk/, result[:failed])
    assert_empty WarmClonePool.ready_entries(@repo, @branch)
  end

  test "room_to_build? asks for twice what an ordinary clone needs, and never reclaims" do
    CloneDiskGuard.expects(:reclaim_space).never
    CloneDiskGuard.stubs(:required_bytes).returns(3.gigabytes)

    CloneDiskGuard.stubs(:volume_stats).returns({ total: 100.gigabytes, available: 5.gigabytes })
    assert_not WarmClonePool.room_to_build?(@repo)

    CloneDiskGuard.stubs(:volume_stats).returns({ total: 100.gigabytes, available: 7.gigabytes })
    assert WarmClonePool.room_to_build?(@repo)

    CloneDiskGuard.stubs(:volume_stats).returns(nil)
    assert WarmClonePool.room_to_build?(@repo), "an unmeasurable volume fails open, as CloneDiskGuard does"
  end

  test "dropping an untargeted pool removes it atomically" do
    old = File.join(WarmClonePool.root_dir, "old-repo-main-0123456789ab")
    FileUtils.mkdir_p(File.join(old, "#{Time.now.to_i}-cccccccc"))
    AtomicCloneRemoval.expects(:remove).with(old).returns(true)

    WarmClonePool.replenish!
  end

  test "the orphan clone sweep never sees the pool" do
    WarmClonePool.replenish!
    control = File.join(@clones_base, "repo-main-#{Time.now.to_i}-99999999")
    FileUtils.mkdir_p(control)

    orphans = OrphanCloneFilesystemCleanupJob.new.send(:find_orphan_directories, @clones_base, cutoff: 1.minute.from_now)

    assert_equal [ control ], orphans, "the sweep sees an unowned clone beside the pool, and not the pool"
  end

  # --- claim ------------------------------------------------------------------

  test "claim moves the ready clone onto the session path and catches it up to the branch tip" do
    WarmClonePool.replenish!
    tip = commit(@repo, "later.md", "landed after the pool was built")
    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-dddddddd")

    assert WarmClonePool.claim(@repo, @branch, into: into)

    assert_empty WarmClonePool.ready_entries(@repo, @branch)
    assert File.exist?(File.join(into, "later.md"))
    assert_equal tip, git(into, "rev-parse", "HEAD")
    assert_in_delta Time.now.to_f, File.mtime(into).to_f, 60, "a claimed clone must date from its session"
  end

  test "claim returns false on an empty pool, an expired entry, or a disabled pool" do
    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-eeeeeeee")
    assert_not WarmClonePool.claim(@repo, @branch, into: into)

    WarmClonePool.replenish!
    entry = WarmClonePool.ready_entries(@repo, @branch).first
    expired = age_entry(entry, WarmClonePool::MAX_AGE + 1.minute)
    assert_not WarmClonePool.claim(@repo, @branch, into: into)
    assert File.exist?(expired), "an expired entry is the refill's to recycle, not the claim's"

    WarmClonePool.replenish!
    ENV["QUICK_ROUTER_WARM_CLONES"] = "0"
    assert_not WarmClonePool.claim(@repo, @branch, into: into)
    assert_not File.exist?(into)
  end

  test "two claims on one entry: exactly one wins" do
    WarmClonePool.replenish!
    first = File.join(@clones_base, "repo-main-#{Time.now.to_i}-11111111")
    second = File.join(@clones_base, "repo-main-#{Time.now.to_i}-22222222")

    results = [ first, second ].map { |into| WarmClonePool.claim(@repo, @branch, into: into) }

    assert_equal [ true, false ], results
    assert_not File.exist?(second)
  end

  test "a claim that loses the rename race moves on rather than failing" do
    WarmClonePool.replenish!
    File.stubs(:rename).raises(Errno::ENOENT)
    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-33333333")

    assert_not WarmClonePool.claim(@repo, @branch, into: into)
  end

  test "a catch-up fetch that fails discards the claimed clone so the caller can clone cold" do
    WarmClonePool.replenish!
    GitCloneService.stubs(:run_git_command).raises(GitCloneService::GitError, "fetch failed")
    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-44444444")

    assert_not WarmClonePool.claim(@repo, @branch, into: into)
    assert_not File.exist?(into)
  end

  test "an unexpected error during a claim is swallowed, never raised into the session" do
    WarmClonePool.replenish!
    FileUtils.stubs(:touch).raises(Errno::EACCES)
    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-55555555")

    assert_not WarmClonePool.claim(@repo, @branch, into: into)
    assert_not File.exist?(into)
  end

  test "a claimed directory with no .git is discarded rather than letting git find an enclosing repository" do
    WarmClonePool.replenish!
    FileUtils.rm_rf(File.join(WarmClonePool.ready_entries(@repo, @branch).first, ".git"))
    GitCloneService.expects(:run_git_command).never
    into = File.join(@clones_base, "repo-main-#{Time.now.to_i}-88888888")

    assert_not WarmClonePool.claim(@repo, @branch, into: into)
    assert_not File.exist?(into)
  end

  # --- GitCloneService integration ---------------------------------------------

  test "create_clone with warm: true takes the pooled clone and skips git clone" do
    WarmClonePool.replenish!
    GitCloneService.expects(:run_git_clone_with_retry).never

    result = GitCloneService.create_clone(@repo, branch: @branch, warm: true)

    assert result[:warm]
    assert File.exist?(File.join(result[:clone_path], "README.md"))
    assert_empty WarmClonePool.ready_entries(@repo, @branch)
  end

  test "create_clone with warm: true and an empty pool clones cold" do
    result = GitCloneService.create_clone(@repo, branch: @branch, warm: true)

    assert_not result[:warm]
    assert File.exist?(File.join(result[:clone_path], "README.md"))
  end

  test "create_clone without warm never touches the pool" do
    WarmClonePool.replenish!

    result = GitCloneService.create_clone(@repo, branch: @branch)

    assert_not result[:warm]
    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size
  end

  test "create_clone does not claim for a caller-supplied path" do
    WarmClonePool.replenish!
    path = File.join(@clones_base, "repo-main-#{Time.now.to_i}-66666666")

    result = GitCloneService.create_clone(@repo, branch: @branch, clone_path: path, warm: true)

    assert_not result[:warm]
    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size
  end

  test "create_clone resolves the subdirectory on a claimed clone" do
    commit(@repo, "roots/router/AGENTS.md", "router")
    WarmClonePool.replenish!

    result = GitCloneService.create_clone(@repo, branch: @branch, subdirectory: "roots/router", warm: true)

    assert result[:warm]
    assert_equal File.join(result[:clone_path], "roots/router"), result[:working_directory]
  end

  test "create_clone with warm: true whose catch-up fails clones cold at the same path" do
    WarmClonePool.replenish!
    WarmClonePool.stubs(:catch_up!).raises(GitCloneService::GitError, "fetch failed")

    result = GitCloneService.create_clone(@repo, branch: @branch, warm: true)

    assert_not result[:warm]
    assert File.exist?(File.join(result[:clone_path], "README.md"))
    assert_equal "", git(result[:clone_path], "status", "--porcelain")
  end

  # --- the job ------------------------------------------------------------------

  test "the replenish job fills the pool" do
    WarmClonePoolReplenishJob.perform_now

    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size
  end

  # --- the active scope ---------------------------------------------------------

  test "under the active scope, replenish builds a clone of every pooled key, router first" do
    other = create_repo("other-repo")
    stub_roots("zimmer-orchestrator" => @repo, "general-agent" => other)
    record_starts("general-agent", WarmPoolPolicy::MIN_STARTS)
    activate!

    built = sequence("builds")
    WarmClonePool.expects(:build!).with(@repo, @branch).in_sequence(built).returns(nil)
    WarmClonePool.expects(:build!).with(other, @branch).in_sequence(built).returns(nil)
    WarmClonePool.replenish!
  end

  test "a busy key keeps two clones" do
    stub_roots("zimmer-orchestrator" => @repo)
    record_starts("zimmer-orchestrator", WarmPoolPolicy::BUSY_STARTS)
    activate!

    assert_equal 2, WarmClonePool.replenish![:built]
    assert_equal 2, WarmClonePool.ready_entries(@repo, @branch).size
    assert_equal({ built: 0, recycled: 0, failed: nil }, WarmClonePool.replenish!)
  end

  test "a key that goes cold, or a scope switched back to router, has its pool dropped" do
    other = create_repo("other-repo")
    stub_roots("zimmer-orchestrator" => @repo, "general-agent" => other)
    record_starts("general-agent", WarmPoolPolicy::MIN_STARTS)
    activate!
    WarmClonePool.replenish!
    assert_equal 1, WarmClonePool.ready_entries(other, @branch).size

    AppSetting.editable.update!(warm_clone_pool_active_roots_enabled: false)
    WarmClonePool.replenish!

    assert_not Dir.exist?(WarmClonePool.key_dir(other, @branch))
    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size, "the router's pool is untouched"
  end

  test "one key that cannot build does not stop the next, and the failure is kept per key" do
    missing = File.join(@test_dir, "no-such-repo")
    other = create_repo("other-repo")
    stub_roots("zimmer-orchestrator" => missing, "general-agent" => other)
    record_starts("general-agent", WarmPoolPolicy::MIN_STARTS)
    activate!
    with_memory_cache do
      result = WarmClonePool.replenish!

      assert_equal 1, result[:built]
      assert_match(/Git command failed/, result[:failed])
      assert_equal 1, WarmClonePool.ready_entries(other, @branch).size

      errors = WarmClonePool.last_pass[:errors]
      assert_equal [ WarmClonePool.key(missing, @branch) ], errors.keys
    end
  end

  test "the disk guard skips a key the volume cannot hold and still builds the rest" do
    other = create_repo("other-repo")
    stub_roots("zimmer-orchestrator" => @repo, "general-agent" => other)
    record_starts("general-agent", WarmPoolPolicy::MIN_STARTS)
    activate!
    WarmClonePool.stubs(:room_to_build?).with(@repo).returns(false)
    WarmClonePool.stubs(:room_to_build?).with(other).returns(true)

    result = WarmClonePool.replenish!

    assert_equal 1, result[:built]
    assert_match(/not enough free disk/, result[:failed])
    assert_empty WarmClonePool.ready_entries(@repo, @branch)
  end

  # --- report -------------------------------------------------------------------

  test "the report names each pooled key, its ready clones, the last pass and the claim counts" do
    with_memory_cache do
      WarmClonePool.replenish!
      Session.create!(prompt: nil, agent_runtime: "claude_code", status: :archived, git_root: @repo, branch: @branch,
                      metadata: { "agent_root_key" => "zimmer-orchestrator", "warm_clone" => "claimed" })
      Session.create!(prompt: nil, agent_runtime: "claude_code", status: :archived, git_root: @repo, branch: @branch,
                      metadata: { "agent_root_key" => "zimmer", "warm_clone" => "missed" })

      report = WarmClonePool.report

      assert report[:enabled]
      assert_equal "router", report[:scope]
      target = report[:targets].sole
      assert_equal [ @repo, @branch, 1, 1 ], target.values_at(:repo_url, :branch, :size, :ready)
      assert_equal WarmClonePool.key(@repo, @branch), target[:key]
      assert_operator target[:newest_age_seconds], :<, 60
      assert_equal 1, report[:last_pass][:built]
      assert_equal({ "claimed" => 1, "missed" => 0 }, report[:outcomes][:router])
      assert_equal({ "claimed" => 0, "missed" => 1 }, report[:outcomes][:other])
    end
  end

  test "the report of a disabled pool lists no targets" do
    ENV["QUICK_ROUTER_WARM_CLONES"] = "0"

    report = WarmClonePool.report

    assert_not report[:enabled]
    assert_empty report[:targets]
  end

  private

  def stub_roots(urls_by_name)
    roots = urls_by_name.map do |name, url|
      AgentRootsConfig::AgentRoot.new(name, { "url" => url, "default_branch" => @branch },
                                      app_setting: AppSetting::NULL, model_ids_by_runtime: {})
    end
    AgentRootsConfig.stubs(:all).returns(roots)
  end

  def activate!
    AppSetting.editable.update!(warm_clone_pool_active_roots_enabled: true)
  end

  def record_starts(root_name, count)
    rows = Array.new(count) do
      { prompt: nil, agent_runtime: "claude_code", status: "archived", git_root: "unused", branch: @branch,
        metadata: { "agent_root_key" => root_name }, created_at: 1.hour.ago, updated_at: 1.hour.ago }
    end
    Session.insert_all!(rows)
  end

  def session_on(git_root, root_name, branch: @branch)
    Session.new(git_root: git_root, branch: branch, metadata: root_name ? { "agent_root_key" => root_name } : {})
  end

  def with_memory_cache
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    yield
  end

  def create_repo(name = "router-repo")
    path = File.join(@test_dir, name)
    FileUtils.mkdir_p(path)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "test@example.com")
    git(path, "config", "user.name", "Test User")
    commit(path, "README.md", "# #{name}")
    path
  end

  def commit(repo, file, content)
    full = File.join(repo, file)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "add #{file}")
    git(repo, "rev-parse", "HEAD")
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  # Rename an entry so its name dates it `age` ago, which is what the pool ages by.
  def age_entry(entry, age)
    aged = File.join(File.dirname(entry), "#{(Time.now - age).to_i}-#{File.basename(entry).split('-').last}")
    File.rename(entry, aged)
    aged
  end
end
