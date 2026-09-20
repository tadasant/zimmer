require "test_helper"

# Runs against the REAL catalog: what the Quick Router's pickers offer and what
# the two controller actions accept are both scoped to the router root's resolved
# runtime, and a stub root with no default_runtime would prove nothing about the
# scoping.
class QuickRouterOptionsTest < ActiveSupport::TestCase
  setup do
    @options = QuickRouterOptions.new
    @router_root = AgentRootsConfig.find!(AgentRootsConfig.router_root_name)
  end

  test "offers every registered runtime, labelled, in registry order" do
    assert_equal RuntimeRegistry.registered_runtimes, @options.runtimes.map { |r| r[:id] }
    assert_equal RuntimeRegistry.registered_runtimes.map { |r| RuntimeRegistry.label_for(r) },
      @options.runtimes.map { |r| r[:label] }
  end

  test "the default runtime is the router root's own" do
    assert_equal @router_root.default_runtime, @options.default_runtime
  end

  test "models are offered per runtime and agree with the catalog" do
    RuntimeRegistry.registered_runtimes.each do |runtime|
      assert_equal ModelCatalog.model_ids_for(runtime), @options.models_by_runtime[runtime]
    end
  end

  # What each blank option names. For the router root's own runtime that is the
  # root's declared model; for any other it self-heals to that runtime's default,
  # because a claude_code id is not a Codex or Pi model.
  test "the named default model follows the runtime" do
    assert_equal @router_root.default_model, @options.default_models_by_runtime[@router_root.default_runtime]

    (RuntimeRegistry.registered_runtimes - [ @router_root.default_runtime ]).each do |runtime|
      named = @options.default_models_by_runtime[runtime]
      assert ModelCatalog.valid_model?(runtime, named),
        "the default named for #{runtime} (#{named.inspect}) is not one of its models"
    end
  end

  # The same chain Sessions::ResolveSpawnDefaults walks at create time, so the
  # blank option never names a model the created session would not get.
  test "the named default matches what a spawn with no model chosen actually resolves to" do
    RuntimeRegistry.registered_runtimes.each do |runtime|
      session = Session.new(agent_runtime: runtime)
      Sessions::ResolveSpawnDefaults.call(
        session, agent_root_name: @router_root.name, explicit_runtime: true
      )
      assert_equal @options.default_models_by_runtime[runtime], session.config["model"],
        "the blank option for #{runtime} names a model the spawn would not land on"
    end
  end

  test "a registered runtime resolves and an unknown one does not" do
    RuntimeRegistry.registered_runtimes.each { |r| assert_equal r, @options.resolve_runtime(r) }

    assert_nil @options.resolve_runtime("aider")
    assert_nil @options.resolve_runtime("")
    assert_nil @options.resolve_runtime("  ")
    assert_nil @options.resolve_runtime(nil)
    # Not a string: a hand-crafted post, never the picker.
    assert_nil @options.resolve_runtime([ "codex" ])
  end

  test "the effective runtime falls back to the router root's" do
    assert_equal "codex", @options.effective_runtime("codex")
    assert_equal @router_root.default_runtime, @options.effective_runtime("")
    assert_equal @router_root.default_runtime, @options.effective_runtime("aider")
  end

  test "a model resolves only against its own runtime's catalog" do
    claude_model = ModelCatalog.model_ids_for("claude_code").first
    codex_model = ModelCatalog.model_ids_for("codex").first

    assert_equal claude_model, @options.resolve_model("claude_code", claude_model)
    assert_nil @options.resolve_model("codex", claude_model)
    assert_equal codex_model, @options.resolve_model("codex", codex_model)
    assert_nil @options.resolve_model("claude_code", codex_model)
  end

  test "an untouched picker names nothing and is not a rejection" do
    assert_nil @options.resolve_model("claude_code", "")
    assert_nil @options.resolve_model("claude_code", "   ")
    assert_not @options.model_rejected?("claude_code", "")
    assert_not @options.runtime_rejected?("")
  end

  test "a named value the catalog does not carry is a rejection" do
    assert @options.runtime_rejected?("aider")
    assert @options.model_rejected?("claude_code", ModelCatalog.model_ids_for("codex").first)
    assert @options.model_rejected?("claude_code", "not-a-model")
  end

  # Offered and accepted from the same source, so a model an operator adds from
  # Settings → Models works on the Quick Router with no deploy.
  test "a model an operator added to a runtime is both offered and accepted" do
    ModelCatalogEntry.new(runtime: "codex", model_id: "gpt-5.7", added_via: "api")
      .save!(validate: false)

    options = QuickRouterOptions.new
    assert_includes options.models_by_runtime["codex"], "gpt-5.7"
    assert_equal "gpt-5.7", options.resolve_model("codex", "gpt-5.7")
  end

  test "default_model_for prefers the root's declared model when the runtime has it" do
    root = OpenStruct.new(default_model: "haiku")

    assert_equal "haiku", QuickRouterOptions.default_model_for(root, "claude_code")
    # A claude_code model on a codex spawn self-heals to the codex default.
    assert_equal AppSetting.current.resolved_default_model_for("codex"),
      QuickRouterOptions.default_model_for(root, "codex")
    assert_equal AppSetting.current.resolved_default_model_for("claude_code"),
      QuickRouterOptions.default_model_for(nil, "claude_code")
  end
end
