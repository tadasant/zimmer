# frozen_string_literal: true

require "test_helper"

# A workflow's requirements are code, so a requirement the catalog cannot resolve
# is a build failure here rather than a fire-time heal and an alert in
# production (#18). Runs against the real catalog — nothing in this file stubs a
# config facade, because a stubbed catalog would prove nothing.
class WorkflowCatalogReferencesTest < ActiveSupport::TestCase
  test "every registered workflow's declared catalog references resolve" do
    # Against a catalog that failed to load every reference would be reported,
    # so an empty one fails loudly — but say what it means rather than listing
    # every workflow as broken.
    assert_predicate AgentRootsConfig.all, :any?, "the artifact catalog did not load, so nothing here can be checked"

    unresolved = WorkflowRegistry.all.to_h { |workflow| [ workflow.workflow_id, workflow.requirements.unresolved_catalog_references ] }
    unresolved.reject! { |_id, references| references.empty? }

    assert_empty unresolved, <<~MESSAGE
      These workflows declare catalog references the catalog cannot resolve. Either the
      catalog entry was removed or renamed — in which case the workflow has to change in the
      same PR — or the workflow names something that was never there.

      #{unresolved.map { |id, references| "  #{id}: #{references.join(', ')}" }.join("\n")}
    MESSAGE
  end

  test "names the catalog does not carry are reported, one per reference" do
    requirements = Workflow::Requirements.new(
      agent_root: "no-such-root",
      mcp_servers: %w[context7 no-such-server],
      skills: %w[wait-for-ci no-such-skill],
      goal: "no-such-goal"
    )

    assert_equal(
      [ 'agent root "no-such-root"', 'MCP server "no-such-server"', 'skill "no-such-skill"', 'goal "no-such-goal"' ],
      requirements.unresolved_catalog_references
    )
  end

  test "names the catalog does carry resolve" do
    requirements = Workflow::Requirements.new(
      agent_root: "zimmer", mcp_servers: %w[context7], skills: %w[wait-for-ci], goal: "codebase-question"
    )

    assert_empty requirements.unresolved_catalog_references
  end

  test "a session's equipment is the root's defaults plus what the workflow declares" do
    root = AgentRootsConfig.find!("zimmer")
    requirements = Workflow::Requirements.new(mcp_servers: %w[context7], skills: %w[wait-for-ci], goal: "codebase-question")

    equipment = requirements.session_equipment(root)

    assert_equal ((root.default_mcp_servers || []) + %w[context7]).uniq, equipment[:mcp_servers]
    assert_equal ((root.default_skills || []) + %w[wait-for-ci]).uniq, equipment[:catalog_skills]
    assert_equal "codebase-question", equipment[:goal]
  end
end
