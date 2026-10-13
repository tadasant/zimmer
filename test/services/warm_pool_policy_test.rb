# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Which keys WarmClonePool keeps clones of: the router's alone under `router`,
# and the ranked active keys under `active`. WarmClonePoolTest covers what the
# pool does with the answer.
class WarmPoolPolicyTest < ActiveSupport::TestCase
  ROUTER = "https://github.com/acme/internal.git"
  APP = "https://github.com/acme/app.git"
  SITE = "https://github.com/acme/site.git"
  DOCS = "https://github.com/acme/docs.git"

  setup do
    @previous_max = ENV["WARM_CLONE_POOL_MAX_CLONES"]
    ENV["WARM_CLONE_POOL_MAX_CLONES"] = nil
    AgentRootsConfig.stubs(:router_root_name).returns("zimmer-orchestrator")
    stub_roots(
      "zimmer-orchestrator" => ROUTER,
      "zimmer-router" => ROUTER,
      "fleet-maintenance" => ROUTER,
      "zimmer" => APP,
      "zimmer-production" => APP,
      "wedding-website" => SITE,
      "obs" => DOCS
    )
  end

  teardown do
    ENV["WARM_CLONE_POOL_MAX_CLONES"] = @previous_max
  end

  test "the router scope is the router's key alone, at the base size, whatever else is busy" do
    record_starts("zimmer", 40)

    plan = WarmPoolPolicy.plan(base_size: 1)

    assert_equal "router", plan[:scope]
    assert_equal [ [ ROUTER, "main", 1 ] ], plan[:targets].map { |t| t.values_at(:repo_url, :branch, :size) }
    assert_equal({ "zimmer-orchestrator" => 0 }, plan[:targets].first[:roots])
    assert_equal [ APP ], plan[:passed_over].map { |t| t[:repo_url] }
    assert_equal "pooled only under the active scope", plan[:passed_over].first[:reason]
  end

  test "the active scope ranks keys by recency-weighted starts, router first" do
    activate!
    record_starts("obs", 20, at: 6.days.ago)
    record_starts("wedding-website", 14, at: 1.hour.ago)
    record_starts("zimmer", 8, at: 1.hour.ago)
    record_starts("zimmer-production", 4, at: 1.hour.ago)

    targets = WarmPoolPolicy.plan(base_size: 1)[:targets]

    assert_equal [ ROUTER, SITE, APP, DOCS ], targets.map { |t| t[:repo_url] },
      "twenty starts six days ago weigh less than twelve an hour ago; the router leads regardless"
    app = targets.find { |t| t[:repo_url] == APP }
    assert_equal 12, app[:starts]
    assert_equal({ "zimmer" => 8, "zimmer-production" => 4 }, app[:roots], "roots on one key are summed")
  end

  test "a deprecated router alias counts toward the router, and roots on its repository share its key" do
    activate!
    record_starts("zimmer-router", 5)
    record_starts("zimmer-orchestrator", 3)
    record_starts("fleet-maintenance", 9)

    targets = WarmPoolPolicy.plan(base_size: 1)[:targets]

    router = targets.sole
    assert_equal ROUTER, router[:repo_url]
    assert_equal 17, router[:starts]
    assert_equal({ "fleet-maintenance" => 9, "zimmer-orchestrator" => 8 }, router[:roots])
  end

  test "a root no longer in the catalog counts toward nothing" do
    activate!
    record_starts("retired-root", 50)

    plan = WarmPoolPolicy.plan(base_size: 1)

    assert_equal [ ROUTER ], plan[:targets].map { |t| t[:repo_url] }
    assert_empty plan[:passed_over]
  end

  test "a key below MIN_STARTS is passed over" do
    activate!
    record_starts("zimmer", WarmPoolPolicy::MIN_STARTS - 1)

    plan = WarmPoolPolicy.plan(base_size: 1)

    assert_equal [ ROUTER ], plan[:targets].map { |t| t[:repo_url] }
    assert_match(/fewer than #{WarmPoolPolicy::MIN_STARTS} starts/, plan[:passed_over].sole[:reason])
  end

  test "a busy key gets a second clone, and the global cap counts clones, not keys" do
    activate!
    ENV["WARM_CLONE_POOL_MAX_CLONES"] = "3"
    record_starts("fleet-maintenance", WarmPoolPolicy::BUSY_STARTS)
    record_starts("wedding-website", 30)
    record_starts("zimmer", 20)

    plan = WarmPoolPolicy.plan(base_size: 1)

    assert_equal [ [ ROUTER, 2 ], [ SITE, 1 ] ], plan[:targets].map { |t| t.values_at(:repo_url, :size) }
    assert_equal [ APP ], plan[:passed_over].map { |t| t[:repo_url] }
    assert_equal "over the 3-clone cap", plan[:passed_over].sole[:reason]
  end

  test "a base size above MAX_PER_KEY is kept, never lowered" do
    activate!
    record_starts("zimmer", 20)

    targets = WarmPoolPolicy.plan(base_size: 3)[:targets]

    assert_equal [ 3, 3 ], targets.map { |t| t[:size] }
  end

  test "targets are empty when the pool is off" do
    assert_empty WarmPoolPolicy.targets(base_size: 0)
  end

  test "targets wraps each planned key as a Target" do
    target = WarmPoolPolicy.targets(base_size: 1).sole

    assert_kind_of WarmPoolPolicy::Target, target
    assert_equal [ ROUTER, "main", 1 ], [ target.repo_url, target.branch, target.size ]
  end

  test "no router root in the catalog leaves the router key out and keeps the rest" do
    activate!
    stub_roots("zimmer" => APP)
    record_starts("zimmer", 20)

    assert_equal [ APP ], WarmPoolPolicy.plan(base_size: 1)[:targets].map { |t| t[:repo_url] }
  end

  test "starts older than the window do not count" do
    activate!
    record_starts("zimmer", 20, at: (WarmPoolPolicy::WINDOW + 1.hour).ago)

    assert_empty WarmPoolPolicy.plan(base_size: 1)[:passed_over]
  end

  test "max_clones reads its override, clamped, and falls back on garbage" do
    assert_equal WarmPoolPolicy::DEFAULT_MAX_CLONES, WarmPoolPolicy.max_clones
    ENV["WARM_CLONE_POOL_MAX_CLONES"] = "100"
    assert_equal 30, WarmPoolPolicy.max_clones
    ENV["WARM_CLONE_POOL_MAX_CLONES"] = "many"
    assert_equal WarmPoolPolicy::DEFAULT_MAX_CLONES, WarmPoolPolicy.max_clones
  end

  private

  def activate!
    AppSetting.editable.update!(warm_clone_pool_active_roots_enabled: true)
  end

  def stub_roots(urls_by_name)
    roots = urls_by_name.map do |name, url|
      AgentRootsConfig::AgentRoot.new(name, { "url" => url, "default_branch" => "main" },
                                      app_setting: AppSetting::NULL, model_ids_by_runtime: {})
    end
    AgentRootsConfig.stubs(:all).returns(roots)
  end

  def record_starts(root_name, count, at: 1.hour.ago)
    rows = Array.new(count) do
      { prompt: nil, agent_runtime: "claude_code", status: "archived", git_root: "unused", branch: "main",
        metadata: { "agent_root_key" => root_name }, created_at: at, updated_at: at }
    end
    Session.insert_all!(rows)
  end
end
