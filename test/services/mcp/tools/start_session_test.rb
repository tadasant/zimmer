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

  # --- place ---------------------------------------------------------------------

  test "place top_of_spot spawns the session above the current top of the queue" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 400)

    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    spawned = Session.order(:id).last
    assert_equal 400 + SessionPrecedence::SLOT_GAP, spawned.precedence
    assert_operator spawned.precedence, :>, 400, "the spawn heads the queue it was placed into"
  end

  # The whole reason the placement is symbolic: it reads the queue at the moment
  # of the write, so a top that has since been archived does not inflate the
  # scale the way a value an agent read earlier and passed back would.
  test "place top_of_spot resolves against the live queue, not a stale top" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 90_000, status: :archived)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 20)

    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 20 + SessionPrecedence::SLOT_GAP, Session.order(:id).last.precedence
  end

  test "place and precedence together are a tool error" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
        "place" => SessionPrecedence::PLACE_TOP_OF_SPOT, "precedence" => 50)
    end

    assert_match(/mutually exclusive/, error.message)
    assert_equal 0, Session.where(title: "Go").count, "and nothing was created"
  end

  test "an unknown place is a tool error" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go", "place" => "bottom_of_spot")
    end

    assert_match(/Unknown place/, error.message)
  end

  # The default that must survive the new argument: omitting both still lands a
  # spawn one point above its parent.
  test "omitting both place and precedence leaves the lineage bump alone" do
    parent = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", precedence: 700)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 9_000)

    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
      "parent_session_id" => parent.id)

    assert_equal 701, Session.order(:id).last.precedence
  end

  # start_session reads a null precedence as "say nothing", so a placement
  # alongside one is the placement rather than the mutual-exclusion error.
  test "place alongside an explicitly null precedence is the placement, not an error" do
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x",
      scheduling_class: SessionGenesis::SPOT, precedence: 300)

    @tool.call("agent_root" => "zimmer", "prompt" => "Go", "title" => "Go",
      "place" => SessionPrecedence::PLACE_TOP_OF_SPOT, "precedence" => nil)

    assert_equal 305, Session.order(:id).last.precedence
  end

  test "the place argument is advertised on the schema and says when to use it" do
    place = Mcp::Tools::StartSession.input_schema.to_h.dig(:properties, :place)

    assert_equal [ SessionPrecedence::PLACE_TOP_OF_SPOT ], place[:enum]
    assert_match(/head of the spot queue/i, place[:description])
    assert_match(/mutually exclusive/i, place[:description])
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

  # A router read "drop servers the task doesn't need" and wrote a fresh
  # one-element list; the root's other default went with it, and the skill that
  # needed that server was still attached and had nothing to call. The partial
  # list is the case these two assertions pin down — the omitted and [] cases
  # were always stated. https://github.com/tadasant/tadasant-internal/issues/2145
  test "every artifact list description states that a list replaces the root's defaults" do
    properties = Mcp::Tools::StartSession.input_schema.to_h[:properties]

    %i[mcp_servers skills plugins hooks].each do |param|
      description = properties.dig(param, :description)

      assert_includes description, "REPLACES the agent root's default_#{param}",
        "#{param} must say a list replaces the root's defaults"
      assert_includes description, "every default you do not name is dropped",
        "#{param} must name the partial-list case, not just the omitted and [] ones"
    end
  end

  test "the tool description enumerates all three list states" do
    description = Mcp::Tools::StartSession.description

    assert_includes description, "REPLACES the root's defaults"
    assert_includes description, "Every root default you did not name is dropped"
  end

  # The tool schema is what an agent reads to decide what to send. `execution_provider`
  # offered a choice the spawn path never made — it gated `lib/execution/`, which nothing
  # under app/ called — so #172 removed the parameter rather than leaving a one-value enum
  # standing in for a decision.
  test "the tool no longer advertises an execution_provider" do
    assert_not Mcp::Tools::StartSession.input_schema.to_h[:properties].key?(:execution_provider)
  end

  # The enum was public on this tool, so an agent may still be composing a call from a
  # stale schema. What decides whether that call survives is the SDK's schema validation
  # (MCP::Server -> InputSchema#validate_arguments), which rejects an unknown argument
  # only when the schema says `additionalProperties: false`. This one does not, and that
  # is the whole compatibility promise — so it is asserted directly rather than inferred
  # from the tool's own key-whitelisting, which is true by construction and would keep
  # passing after someone tightened the schema.
  test "the schema does not forbid additional properties, so a stale argument survives validation" do
    assert_not Mcp::Tools::StartSession.input_schema.to_h.key?(:additionalProperties)
  end

  test "a legacy execution_provider argument is ignored rather than fatal" do
    result = nil

    assert_difference "Session.count", 1 do
      result = @tool.call(
        "agent_root" => "zimmer",
        "prompt" => "Fix the thing",
        "title" => "Sandbox please",
        "execution_provider" => "remote_sandbox"
      )
    end

    assert_includes result, "## Session Started Successfully"
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
  # and plugins and leaves the hook list to the caller.
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

  # --- the plugins bypass of the agent-root MCP lock (#334) ---
  #
  # A plugin bundles MCP servers, so naming one at launch reaches the servers
  # `mcp_servers` is locked out of. These pin the whole guard: the bypass itself,
  # that it is the servers that make it one, both halves of the omitted-vs-[]
  # distinction the same call site draws for every artifact list, and that skills
  # — which bundle nothing — stay narrowable.

  test "a restricted connection cannot name plugins at launch" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    error = assert_raises(Mcp::ToolError) do
      tool.call("agent_root" => "test-root", "title" => "x", "plugins" => [ "screenshots-videos" ])
    end

    assert_match(/"plugins" parameter is not allowed/, error.message)
    assert_match(/Plugins can add MCP servers/, error.message)
    assert_match(/default plugins: \[screenshots-videos\]/, error.message)
  end

  # The gate is `key?`, not a shape test, so an explicit null is refused with the
  # rest — the same reading the mcp_servers gate beside it already takes.
  test "a restricted connection cannot pass an explicit null plugins either" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    error = assert_raises(Mcp::ToolError) do
      tool.call("agent_root" => "test-root", "title" => "x", "plugins" => nil)
    end

    assert_match(/"plugins" parameter is not allowed/, error.message)
  end

  # The bypass in full: the same connection, the same server, reached the direct
  # way and then the indirect one. The plugin here is deliberately NOT one of the
  # root's defaults — figma-design-workflow bundles figma, image-diff, svg-tracer
  # and playwright-custom, none of which this root grants — so what the second
  # call asks for is a genuine escalation and not a restatement of the omitted
  # case. Before this guard it succeeded.
  test "the plugin route cannot reach a server the mcp_servers route is refused" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    escalation = PluginsConfig.find("figma-design-workflow").mcp_servers
    assert_includes escalation, "playwright-custom"
    assert_empty escalation & (@root_with_defaults.default_mcp_servers + @root_with_defaults.default_plugins)

    direct = assert_raises(Mcp::ToolError) do
      tool.call("agent_root" => "test-root", "title" => "direct",
                "mcp_servers" => [ "context7", "playwright-custom" ])
    end
    assert_match(/must use its exact default MCP servers/, direct.message)

    assert_no_difference "Session.count" do
      assert_raises(Mcp::ToolError) do
        tool.call("agent_root" => "test-root", "title" => "indirect", "plugins" => [ "figma-design-workflow" ])
      end
    end
  end

  # `[]` adds no servers, so this rejection is a deliberate choice and not a
  # consequence: a restricted connection takes its root's catalog exactly as
  # configured, in either direction, the way mcp_servers already reads — and it
  # is the answer action_session's change_plugins gives for the same request
  # after the session exists.
  test "a restricted connection cannot pass an explicit empty plugins array either" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    error = assert_raises(Mcp::ToolError) do
      tool.call("agent_root" => "test-root", "title" => "x", "plugins" => [])
    end

    assert_match(/"plugins" parameter is not allowed/, error.message)
  end

  # Omitted is the request the guard leaves open, and it is not "no plugins" —
  # it is the root's defaults, which is the whole point of leaving it open.
  test "a restricted connection may omit plugins and take the root's defaults" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    result = tool.call("agent_root" => "test-root", "title" => "Restricted, default plugins")

    assert_includes result, "## Session Started Successfully"
    assert_equal [ "screenshots-videos" ], Session.order(:id).last.catalog_plugins
  end

  # Skills carry no MCP servers of their own, so they stay narrowable — the same
  # reasoning that leaves hooks alone above.
  test "a restricted connection may still narrow the skills it spawns with" do
    stub_root_with_defaults
    tool = Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "test-root")
    )

    result = tool.call("agent_root" => "test-root", "title" => "Restricted, no skills", "skills" => [])

    assert_includes result, "## Session Started Successfully"
    assert_equal [], Session.order(:id).last.catalog_skills
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
    @root_with_defaults = root
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

  # --- MCP-server readiness at spawn (#537) ---
  #
  # The write paths used to check only that a named server is in the catalog. A
  # server whose `${VAR}` does not resolve is in the catalog and cannot start, and
  # attaching one fails the whole session at prepare time — the slowest and least
  # legible place to find out. These pin the remedy: the call is ACCEPTED and the
  # caller is told, in the result it is already reading.
  #
  # They drive the real ConnectorStatusProbe against the shared mixed-availability
  # catalog rather than stubbing the readiness answer, so what is under test is
  # the wiring that ships.

  test "a spawn naming a server Zimmer cannot start is accepted, and says so" do
    result = nil

    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default

      assert_difference "Session.count", 1 do
        result = @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "Broken server")
      end
    end

    assert_includes result, "## Session Started Successfully",
      "readiness warns; it must never turn a spawn into a refusal"
    assert_includes result, "Zimmer cannot start MCP server strad-secrets-staging-rw " \
                            "(STRAD_STAGING_API_KEY unresolved)"
    assert_includes result, "/connectors"
    assert Session.order(:id).last.job_id.present?, "the agent job is still queued"
  end

  test "the warning is on the session's own log, where the agent and the human both read it" do
    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default
      @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "Broken server")
    end

    log = Session.order(:id).last.logs.order(:id).last
    assert_equal "warning", log.level
    assert_includes log.content, "strad-secrets-staging-rw (STRAD_STAGING_API_KEY unresolved)"
  end

  test "a spawn whose servers all start says nothing about availability" do
    result = nil

    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default(servers: [ "context7" ])
      result = @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "Healthy")
    end

    refute_includes result, "Zimmer cannot start"
    assert_empty Session.order(:id).last.logs.where(level: "warning")
  end

  # The reason this reads the session rather than the arguments. A caller that
  # named no servers at all still inherits the root's defaults, and one of those
  # can be broken — that caller is the one with the least idea it is happening.
  test "a root default that cannot start is warned about even though the caller named nothing" do
    result = nil

    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default
      result = @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "Inherited")
    end

    assert_equal [ "strad-secrets-staging-rw" ], Session.order(:id).last.mcp_servers
    assert_includes result, "Zimmer cannot start MCP server strad-secrets-staging-rw"
  end

  # The decision the issue asked to be made explicitly rather than fall out of the
  # implementation. A restricted connection MUST pass its root's default_mcp_servers
  # exactly, so it has no legal way to drop an unavailable one. Rejecting here would
  # make the root unspawnable until an operator fixed the secret — so it warns, and
  # the spawn goes through.
  test "a restricted connection compelled to pass an unavailable default is warned, not refused" do
    result = nil

    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default
      tool = Mcp::Tools::StartSession.new(
        context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "broken-root")
      )

      assert_difference "Session.count", 1 do
        result = tool.call(
          "agent_root" => "broken-root",
          "prompt" => "go",
          "title" => "Locked to a broken default",
          "mcp_servers" => [ "strad-secrets-staging-rw" ]
        )
      end
    end

    assert_includes result, "## Session Started Successfully"
    assert_includes result, "Zimmer cannot start MCP server strad-secrets-staging-rw " \
                            "(STRAD_STAGING_API_KEY unresolved)"
    assert_equal [ "strad-secrets-staging-rw" ], Session.order(:id).last.mcp_servers
  end

  # Advice must not be able to take a spawn down. McpServerReadiness rescues
  # internally; this pins the property end to end through the real tool.
  test "a readiness check that blows up does not stop the session being created" do
    result = nil

    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default
      ConnectorStatusProbe.any_instance.stubs(:call).raises(StandardError, "probe exploded")

      assert_difference "Session.count", 1 do
        result = @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "Probe down")
      end
    end

    assert_includes result, "## Session Started Successfully"
    refute_includes result, "Zimmer cannot start"
  end

  # A replay is handed a session it already made. Nothing about that session
  # changed here, so re-warning about it would be a fresh alarm about old news.
  test "an idempotent replay carries no readiness warning" do
    replay = nil

    with_mixed_mcp_catalog_only do
      stub_root_with_unstartable_default
      @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "First",
        "idempotency_key" => "readiness-key")
      replay = @tool.call("agent_root" => "broken-root", "prompt" => "go", "title" => "First",
        "idempotency_key" => "readiness-key")
    end

    assert_includes replay, "## Existing Session Returned"
    refute_includes replay, "Zimmer cannot start"
  end

  # A root whose defaults name a server the mixed-availability catalog cannot
  # start. Only the root is stubbed — the catalog, the probe and the secret
  # resolution are the real ones the surrounding block seeded.
  def stub_root_with_unstartable_default(servers: [ "strad-secrets-staging-rw" ])
    root = OpenStruct.new(
      name: "broken-root",
      url: "https://github.com/test/repo.git",
      default_branch: "main",
      subdirectory: nil,
      default_mcp_servers: servers,
      default_skills: [],
      default_hooks: [],
      default_plugins: [],
      default_runtime: "claude_code",
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("broken-root").returns(root)
    AgentRootsConfig.stubs(:find).with("broken-root").returns(root)
    root
  end
end
