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

    root = stub(url: @repo, default_branch: @branch)
    AgentRootsConfig.stubs(:router_root_name).returns("zimmer-orchestrator")
    AgentRootsConfig.stubs(:find).with("zimmer-orchestrator").returns(root)
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

  test "serves sessions on either router root name and nothing else" do
    %w[zimmer-orchestrator zimmer-router].each do |name|
      assert WarmClonePool.serves?(Session.new(metadata: { "agent_root_key" => name }))
    end
    assert_not WarmClonePool.serves?(Session.new(metadata: { "agent_root_key" => "zimmer" }))
    assert_not WarmClonePool.serves?(Session.new(metadata: {}))

    ENV["QUICK_ROUTER_WARM_CLONES"] = "0"
    assert_not WarmClonePool.serves?(Session.new(metadata: { "agent_root_key" => "zimmer-orchestrator" }))
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
    root = stub(url: File.join(@test_dir, "no-such-repo"), default_branch: @branch)
    AgentRootsConfig.stubs(:find).with("zimmer-orchestrator").returns(root)

    result = WarmClonePool.replenish!

    assert_equal 0, result[:built]
    assert_match(/Git command failed/, result[:failed])
    dir = WarmClonePool.key_dir(root.url, @branch)
    assert_empty Dir.exist?(dir) ? Dir.children(dir) : []
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

  # --- the job ------------------------------------------------------------------

  test "the replenish job fills the pool" do
    WarmClonePoolReplenishJob.perform_now

    assert_equal 1, WarmClonePool.ready_entries(@repo, @branch).size
  end

  private

  def create_repo
    path = File.join(@test_dir, "router-repo")
    FileUtils.mkdir_p(path)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "test@example.com")
    git(path, "config", "user.name", "Test User")
    commit(path, "README.md", "# router")
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
