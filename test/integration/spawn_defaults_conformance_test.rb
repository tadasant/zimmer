# frozen_string_literal: true

require "test_helper"

# The four ways a new session is built — POST /api/v1/sessions, MCP
# `start_session`, the web new-session form, and Session.create_from_agent_root!
# (quick prompt, chat bubble, every trigger fire) — have to resolve the same
# request to the same session. They share one resolution,
# Sessions::ResolveSpawnDefaults, because separate copies disagreed and produced
# three closed bugs (#310, #331, #81; see #454). Each surface is driven end to end here, the
# way its callers drive it, and the resulting rows are compared.
#
# Where a surface cannot express a request at all it is left out of that
# comparison rather than forced into it, and the test says why.
class SpawnDefaultsConformanceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ROOT = "zimmer"

  setup do
    @api_key = "spawn_conformance_key"
    ENV["API_KEYS"] = @api_key
    @root = AgentRootsConfig.find!(ROOT)
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "the root has defaults to fall back to, or nothing below proves anything" do
    assert_predicate @root.default_mcp_servers, :present?
    assert_predicate @root.default_skills, :present?
  end

  test "a request that names only the root resolves identically on all four surfaces" do
    sessions = {
      rest: via_rest,
      mcp: via_mcp,
      # The form cannot omit a list: it renders the root's defaults into its
      # pickers, so what it posts for "left alone" is those defaults.
      web: via_web(session: root_default_lists),
      create_from_agent_root: via_create_from_agent_root
    }

    assert_all_agree(sessions)
    expected = fingerprint(sessions[:rest])
    assert_equal ROOT, expected[:agent_root_key]
    assert_equal @root.url, expected[:git_root]
    assert_equal @root.default_branch, expected[:branch]
    assert_equal @root.default_mcp_servers, expected[:mcp_servers]
    assert_equal @root.default_skills, expected[:catalog_skills]
    assert_equal @root.default_hooks || [], expected[:catalog_hooks]
    assert_equal @root.default_plugins || [], expected[:catalog_plugins]
    assert ModelCatalog.valid_model?(expected[:agent_runtime], expected[:model])
  end

  test "an explicit runtime wins, and the model heals to one valid for it, on all four surfaces" do
    sessions = {
      rest: via_rest(agent_runtime: "codex"),
      mcp: via_mcp("agent_runtime" => "codex"),
      web: via_web(session: root_default_lists, agent_runtime: "codex"),
      create_from_agent_root: via_create_from_agent_root(agent_runtime: "codex")
    }

    assert_all_agree(sessions)
    assert_equal "codex", sessions[:rest].agent_runtime
    assert ModelCatalog.valid_model?("codex", sessions[:rest].config["model"])
  end

  # create_from_agent_root! takes no branch: its callers always spawn on the
  # root's default branch.
  test "an explicit branch wins on every surface that can name one" do
    sessions = {
      rest: via_rest(branch: "feature-x"),
      mcp: via_mcp("branch" => "feature-x"),
      web: via_web(session: root_default_lists.merge(branch: "feature-x"))
    }

    assert_all_agree(sessions)
    assert_equal "feature-x", sessions[:rest].branch
  end

  test "a non-empty list replaces the root's defaults on all four surfaces" do
    sessions = {
      rest: via_rest(mcp_servers: [ "context7" ]),
      mcp: via_mcp("mcp_servers" => [ "context7" ]),
      web: via_web(session: root_default_lists.merge(mcp_servers: [ "context7" ])),
      create_from_agent_root: via_create_from_agent_root(mcp_servers: [ "context7" ])
    }

    assert_all_agree(sessions)
    assert_equal [ "context7" ], sessions[:rest].mcp_servers
  end

  # The split that matters. REST, MCP and the form can ask for no servers, and
  # get none, recorded as deliberate. create_from_agent_root! cannot: its
  # callers include every trigger, whose list columns hold [] when nobody
  # touched them, so [] there has to keep meaning "the root's defaults".
  test "an explicit empty mcp_servers is none where a caller can say none, and the root's defaults on the trigger path" do
    none = {
      rest: via_rest(mcp_servers: []),
      mcp: via_mcp("mcp_servers" => []),
      # The picker's blank hidden input, which is what the form posts for "none".
      web: via_web(session: root_default_lists.merge(mcp_servers: [ "" ]))
    }

    assert_all_agree(none)
    none.each do |surface, session|
      assert_empty session.mcp_servers, "#{surface} handed out servers nobody asked for"
      assert session.mcp_servers_explicitly_empty?, "#{surface} did not record the none as deliberate"
    end

    from_trigger_path = via_create_from_agent_root(mcp_servers: [])
    assert_equal @root.default_mcp_servers, from_trigger_path.mcp_servers
    refute from_trigger_path.mcp_servers_explicitly_empty?
  end

  private

  def via_rest(**params)
    post api_v1_sessions_path,
      params: { agent_root: ROOT, prompt: "Conformance" }.merge(params),
      headers: { "X-API-Key" => @api_key },
      as: :json
    assert_response :created, response.body
    Session.find(JSON.parse(response.body).dig("session", "id"))
  end

  def via_mcp(args = {})
    tool = Mcp::Tools::StartSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    tool.call({ "agent_root" => ROOT, "prompt" => "Conformance", "title" => "Conformance" }.merge(args))
    Session.order(:id).last
  end

  # Posted the way the form posts: the root's name, its url as git_root, and a
  # branch field left empty unless the test names one.
  def via_web(session:, **params)
    post sessions_url, params: {
      session: { prompt: "Conformance", git_root: @root.url, branch: "" }.merge(session),
      agent_root_name: ROOT
    }.merge(params)
    assert_response :redirect
    Session.order(:id).last
  end

  def via_create_from_agent_root(**kwargs)
    Session.create_from_agent_root!(agent_root_name: ROOT, prompt: "Conformance", skip_enqueue: true, **kwargs)
  end

  def root_default_lists
    {
      mcp_servers: @root.default_mcp_servers,
      catalog_skills: @root.default_skills,
      catalog_hooks: @root.default_hooks,
      catalog_plugins: @root.default_plugins
    }.compact_blank
  end

  def fingerprint(session)
    session.reload
    {
      agent_runtime: session.agent_runtime,
      model: session.config["model"],
      git_root: session.git_root,
      branch: session.branch,
      subdirectory: session.subdirectory,
      agent_root_key: session.metadata["agent_root_key"],
      mcp_servers: session.mcp_servers,
      catalog_skills: session.catalog_skills,
      catalog_hooks: session.catalog_hooks,
      catalog_plugins: session.catalog_plugins
    }
  end

  def assert_all_agree(sessions)
    fingerprints = sessions.transform_values { |session| fingerprint(session) }
    reference_surface, reference = fingerprints.first
    fingerprints.each do |surface, print|
      assert_equal reference, print, "#{surface} resolved differently from #{reference_surface}"
    end
  end
end
