# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct" # OpenStruct is used to build mock agent roots; not autoloaded when this file runs in isolation

class Mcp::Tools::StartSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tool = Mcp::Tools::StartSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    @root = AgentRootsConfig.find!("zimmer")
  end

  test "creates a session from an agent root and queues the agent job" do
    result = nil

    assert_difference "Session.count", 1 do
      assert_enqueued_with(job: AgentSessionJob) do
        result = @tool.call("agent_root" => "zimmer", "prompt" => "Fix the thing", "title" => "Fix the thing")
      end
    end

    session = Session.order(:id).last
    assert_equal "zimmer", session.metadata["agent_root_key"]
    assert_equal @root.url, session.git_root
    assert_equal @root.default_mcp_servers || [], session.mcp_servers
    assert session.config["model"].present?
    assert session.job_id.present?

    assert_includes result, "## Session Started Successfully"
    assert_includes result, "- **ID:** #{session.id}"
    assert_includes result, "- **Job ID:** #{session.job_id}"
    assert_includes result, "The agent job has been queued"
  end

  test "an explicit spot class outranks the genesis a parent would give the spawn" do
    # The motivating case (session 3783): a router whose own genesis is `slack`
    # spawns a long, low-urgency batch. Without this argument the child comes out
    # priority, and the only lever was demoting every slack session at once.
    parent = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::SLACK)

    @tool.call(
      "agent_root" => "zimmer",
      "prompt" => "Run the batch",
      "title" => "Batch",
      "parent_session_id" => parent.id,
      "scheduling_class" => SessionGenesis::SPOT
    )

    session = Session.order(:id).last
    assert_equal SessionGenesis::SLACK, session.genesis, "the line of work is still the parent's"
    assert_equal SessionGenesis::SPOT, session.scheduling_class
    assert session.spot?
    assert parent.reload.priority?, "and no other slack session moved"
  end

  test "omitting scheduling_class leaves the session deriving from its genesis" do
    parent = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", genesis: SessionGenesis::SLACK)

    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go", "parent_session_id" => parent.id)

    session = Session.order(:id).last
    assert_nil session.scheduling_class
    assert session.priority?
  end

  test "an unknown scheduling_class is a tool error, not a silent default" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go", "scheduling_class" => "whenever")
    end
    assert_match(/Unknown scheduling_class/, error.message)
  end

  test "scheduling_class is advertised with both classes" do
    enum = Mcp::Tools::StartSession.input_schema.to_h.dig(:properties, :scheduling_class, :enum)
    assert_equal SessionGenesis::CLASSES, enum
  end

  # --- precedence -------------------------------------------------------------

  test "an explicit precedence ranks the spawned session" do
    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go", "precedence" => 5000)

    assert_equal 5000, Session.order(:id).last.precedence
  end

  # What the tool description tells agents to rely on: omit it and the child
  # lands just above its parent, so a tree of work stays contiguous.
  test "omitting precedence lands the spawn just above its parent" do
    parent = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", precedence: 700)

    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
      "parent_session_id" => parent.id)

    assert_equal 701, Session.order(:id).last.precedence
  end

  test "a non-integer precedence is a tool error" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go", "precedence" => "soon")
    end
    assert_match(/precedence must be an integer/, error.message)
  end

  test "a precedence beyond the accepted range is a tool error" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
        "precedence" => SessionPrecedence::MAX + 1)
    end
    assert_match(/precedence must be between/, error.message)
  end

  # The two things an agent reading the description has to get right.
  test "the precedence description states the absolute scale and the lineage rule" do
    description = Mcp::Tools::StartSession.input_schema.to_h.dig(:properties, :precedence, :description)

    assert_match(/absolute scale/i, description)
    assert_match(/100000 comes before 50/, description)
    assert_match(/slightly higher/i, description)
  end

  test "creates a clone-only session when no prompt is given" do
    result = @tool.call("agent_root" => "zimmer", "title" => "Clone only")

    session = Session.order(:id).last
    assert_nil session.job_id
    assert_includes result, "No prompt was provided"
  end

  test "resolves a goal id to its catalog description" do
    @tool.call("agent_root" => "zimmer", "title" => "Goal test", "goal" => "codebase-question")

    session = Session.order(:id).last
    assert_equal GoalsConfig.find("codebase-question").description, session.goal
  end

  test "explicit skills and mcp_servers override the root defaults" do
    @tool.call(
      "agent_root" => "zimmer",
      "title" => "Explicit config",
      "mcp_servers" => [ "context7" ],
      "config" => { "model" => "fable" }
    )

    session = Session.order(:id).last
    assert_equal [ "context7" ], session.mcp_servers
    assert_equal "fable", session.config["model"]
  end

  test "persists an explicit GPT 5.6 Codex model" do
    @tool.call(
      "agent_root" => "zimmer",
      "agent_runtime" => "codex",
      "title" => "Codex config",
      "config" => { "model" => "gpt-5.6-luna" }
    )

    session = Session.order(:id).last
    assert_equal "codex", session.agent_runtime
    assert_equal "gpt-5.6-luna", session.config["model"]
  end

  test "raises for an unknown agent root" do
    error = assert_raises(Mcp::ToolError) { @tool.call("agent_root" => "nope", "title" => "x") }
    assert_match(/Invalid agent_root/, error.message)
  end

  test "raises when a required attribute is missing" do
    assert_raises(ActiveRecord::RecordInvalid) { @tool.call("title" => "No root, no git_root") }
  end

  test "a restricted connection requires an allowed agent root" do
    tool = restricted_tool

    missing = assert_raises(Mcp::ToolError) { tool.call("title" => "x") }
    assert_match(/agent_root is required/, missing.message)

    forbidden = assert_raises(Mcp::ToolError) { tool.call("agent_root" => "general-agent", "title" => "x") }
    assert_match(/not permitted/, forbidden.message)
  end

  test "a restricted connection must use the root's exact default mcp servers" do
    error = assert_raises(Mcp::ToolError) do
      restricted_tool.call("agent_root" => "zimmer", "title" => "x", "mcp_servers" => [ "context7" ])
    end

    assert_match(/must use its exact default MCP servers/, error.message)
  end

  test "a restricted connection succeeds with the root's default mcp servers" do
    result = restricted_tool.call(
      "agent_root" => "zimmer",
      "title" => "Allowed spawn",
      "mcp_servers" => @root.default_mcp_servers || []
    )

    assert_includes result, "## Session Started Successfully"
  end

  # The tool schema is what an agent reads to decide what to send, so a value it offers has
  # to be one the model accepts and a provider can run. Deriving the enum from the model
  # constant rather than restating it is what holds that true without a second edit.
  test "the execution_provider enum is exactly what the model accepts" do
    enum = Mcp::Tools::StartSession.input_schema.to_h.dig(:properties, :execution_provider, :enum)

    assert_equal Session::EXECUTION_PROVIDERS, enum
    refute_includes enum, "remote_sandbox"
  end

  # A router read "drop servers the task doesn't need" and wrote a fresh
  # one-element list; the root's other default went with it, and the skill that
  # needed that server was still attached and had nothing to call. The partial
  # list is the case the description used to leave implied.
  # https://github.com/tadasant/tadasant-internal/issues/2145
  test "every artifact list description states that a list replaces the root's defaults" do
    properties = Mcp::Tools::StartSession.input_schema.to_h[:properties]

    %i[mcp_servers skills plugins hooks].each do |param|
      description = properties.dig(param, :description)

      assert_includes description, "REPLACES the agent root's default_#{param}",
        "#{param} must say a list replaces the root's defaults"
      assert_includes description, "every default you do not name is dropped",
        "#{param} must name the partial-list case, not just the omitted and [] ones"
      assert_includes description, "copy it, and subtract",
        "#{param} must tell the caller to start from the defaults rather than compose a fresh list"
    end
  end

  test "the tool description enumerates all three list states" do
    description = Mcp::Tools::StartSession.description

    assert_includes description, "REPLACES the root's defaults, it is never merged with them"
    assert_includes description, "Every root default you did not name is dropped, silently"
    assert_includes description, "complete final set"
  end

  test "the execution_provider description does not promise a sandbox" do
    description = Mcp::Tools::StartSession.input_schema.to_h.dig(:properties, :execution_provider, :description)

    refute_includes description, "remote_sandbox"
    refute_includes description, "isolated sandbox"
    assert_includes description, "unsandboxed"
  end

  test "a session cannot be started against the stub sandbox provider" do
    assert_no_difference "Session.count" do
      assert_raises(ActiveRecord::RecordInvalid) do
        @tool.call(
          "agent_root" => "zimmer",
          "prompt" => "Fix the thing",
          "title" => "Sandbox please",
          "execution_provider" => "remote_sandbox"
        )
      end
    end
  end

  # An explicit [] and an omitted key are two different requests, and only a root
  # that actually declares defaults can tell them apart. Sessions 959 saw
  # ssh-tadasant-obs-prod and ssh-ci-runner attached to spawns that asked for
  # none, because the fallback fired on both.
  test "an explicit empty mcp_servers array attaches no servers" do
    stub_root_with_defaults

    @tool.call("agent_root" => "test-root", "title" => "Least privilege", "mcp_servers" => [])

    session = Session.order(:id).last
    assert_equal [], session.mcp_servers
    # Recorded so McpServerBackfill doesn't restore the defaults at job start.
    assert session.mcp_servers_explicitly_empty?
  end

  test "an omitted mcp_servers still takes the root's defaults" do
    stub_root_with_defaults

    @tool.call("agent_root" => "test-root", "title" => "Defaults please")

    session = Session.order(:id).last
    assert_equal [ "context7" ], session.mcp_servers
    refute session.mcp_servers_explicitly_empty?
  end

  test "an explicit empty skills or plugins array attaches none of that artifact" do
    stub_root_with_defaults

    @tool.call(
      "agent_root" => "test-root",
      "title" => "No skills, no plugins",
      "skills" => [],
      "plugins" => []
    )

    session = Session.order(:id).last
    assert_equal [], session.catalog_skills
    assert_equal [], session.catalog_plugins
    # An untouched list is unaffected by another list being cleared.
    assert_equal [ "git-push-ci-reminder" ], session.catalog_hooks
    assert_equal [ "context7" ], session.mcp_servers
  end

  test "an omitted hooks array takes the root's default hooks" do
    stub_root_with_defaults

    @tool.call("agent_root" => "test-root", "title" => "Default hooks")

    assert_equal [ "git-push-ci-reminder" ], Session.order(:id).last.catalog_hooks
  end

  # An explicit [] has to survive apply_agent_root_defaults!. A `.blank?` test
  # there cannot tell "asked for none" from "not asked yet", so it hands back the
  # root's defaults to a caller that asked for neither.
  test "an explicit empty hooks array attaches no hooks" do
    stub_root_with_defaults

    @tool.call("agent_root" => "test-root", "title" => "No hooks", "hooks" => [])

    session = Session.order(:id).last
    assert_equal [], session.catalog_hooks
    # Clearing hooks leaves the other lists on the root's defaults.
    assert_equal [ "zimmer-run-tests" ], session.catalog_skills
    assert_equal [ "context7" ], session.mcp_servers
  end

  test "an explicit hooks array overrides the root's default hooks" do
    stub_root_with_defaults

    @tool.call("agent_root" => "test-root", "title" => "Named hooks", "hooks" => [ "some-hook" ])

    assert_equal [ "some-hook" ], Session.order(:id).last.catalog_hooks
  end

  # Hooks carry no privilege, so a restricted connection constrains mcp_servers
  # only and leaves the hook list to the caller.
  test "a restricted connection may narrow the hooks it spawns with" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    result = tool.call(
      "agent_root" => "test-root",
      "title" => "Restricted, no hooks",
      "mcp_servers" => [ "context7" ],
      "hooks" => []
    )

    assert_includes result, "## Session Started Successfully"
    assert_equal [], Session.order(:id).last.catalog_hooks
  end

  # The restricted path already rejected [] before this fix, and must keep doing
  # so: on a restricted connection the list has to match the root's defaults
  # exactly, in either direction.
  test "a restricted connection still rejects an explicit empty mcp_servers array" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    error = assert_raises(Mcp::ToolError) do
      tool.call("agent_root" => "test-root", "title" => "x", "mcp_servers" => [])
    end

    assert_match(/must use its exact default MCP servers/, error.message)
  end

  private

  # A root that actually declares defaults. The catalog's own roots are resolved
  # from the AIR index, so a stub is the only way to pin a non-empty default set
  # the omitted-vs-[] distinction can be observed against.
  def stub_root_with_defaults
    root = OpenStruct.new(
      name: "test-root",
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: [ "context7" ],
      default_skills: [ "zimmer-run-tests" ],
      default_hooks: [ "git-push-ci-reminder" ],
      default_plugins: [ "screenshots-videos" ],
      default_runtime: "claude_code",
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("test-root").returns(root)
    AgentRootsConfig.stubs(:find).with("test-root").returns(root)
    # The mock root's artifact names are asserted against, not resolved, so the
    # model's catalog-existence validations are stubbed rather than relied on.
    ServersConfig.stubs(:exists?).returns(true)
    SkillsConfig.stubs(:exists?).returns(true)
    HooksConfig.stubs(:exists?).returns(true)
    PluginsConfig.stubs(:exists?).returns(true)
    root
  end

  def restricted_tool
    Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )
  end

  # --- idempotency_key (#577) ---

  test "the key is persisted on the session it created" do
    @tool.call("agent_root" => "zimmer", "prompt" => "x", "title" => "Keyed", "idempotency_key" => "unit-key")

    assert_equal "unit-key", Session.order(:id).last.idempotency_key
  end

  test "a replay does no create work and queues no job" do
    @tool.call("agent_root" => "zimmer", "prompt" => "x", "title" => "Keyed", "idempotency_key" => "unit-replay")

    assert_no_difference "Session.count" do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        result = @tool.call("agent_root" => "zimmer", "prompt" => "x", "title" => "Keyed", "idempotency_key" => "unit-replay")
        assert_includes result, "## Existing Session Returned (idempotency_key matched)"
      end
    end
  end

  # The lookup must not become a way around the connection's own limits: a
  # restricted connection is refused before the key is ever read.
  test "a restricted connection is rejected on a disallowed root even when it sends a key" do
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    error = assert_raises(Mcp::ToolError) do
      tool.call("agent_root" => "zimmer", "title" => "x", "idempotency_key" => "restricted-key")
    end
    assert_match(/not permitted/, error.message)
  end

  test "omitting the key leaves the column null and keeps every create distinct" do
    assert_difference "Session.count", 2 do
      2.times { @tool.call("agent_root" => "zimmer", "prompt" => "x", "title" => "Unkeyed") }
    end

    assert_equal [ nil, nil ], Session.order(:id).last(2).map(&:idempotency_key)
  end

  test "a restricted connection may omit mcp_servers and take the root's defaults" do
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )

    root = AgentRootsConfig.find("zimmer")
    output = tool.call("agent_root" => "zimmer", "prompt" => "do the thing", "title" => "defaults")

    assert_includes output, "## Session Started Successfully"
    session = Session.order(:created_at).last
    assert_equal (root.default_mcp_servers || []).sort, session.mcp_servers.sort
  end
end
