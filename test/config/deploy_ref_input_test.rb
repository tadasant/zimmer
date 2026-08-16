# frozen_string_literal: true

require "test_helper"
require "yaml"

# `actions/checkout` only special-cases a FULL 40-character SHA. Any shorter ref -- an
# abbreviated SHA, which is what `git log --oneline` prints and what gets pasted into a
# pinned redeploy -- is read as a branch name, matches nothing, and kills the run a minute
# later with "The process '/usr/bin/git' failed with exit code 1" and no mention of the ref.
#
# So a dispatch input named `ref` must never reach checkout raw. This is a text-level guard
# rather than a behavioral one because the failure it prevents can only happen on GitHub's
# runners: the wiring IS the bug, and the wiring is what is asserted. It sweeps every
# workflow, not just the one that got caught, so the next workflow to take a ref input
# inherits the guard instead of re-learning it.
class DeployRefInputTest < ActiveSupport::TestCase
  RESOLVER = "scripts/resolve-deploy-ref.sh"

  WORKFLOWS = Rails.root.glob(".github/workflows/*.yml").sort.freeze

  # Psych reads YAML 1.1, where a bare `on` key is the boolean true.
  def triggers(workflow)
    workflow["on"] || workflow[true] || {}
  end

  def dispatch_inputs(workflow)
    dispatch = triggers(workflow)["workflow_dispatch"]
    dispatch.is_a?(Hash) ? (dispatch["inputs"] || {}) : {}
  end

  def steps(workflow)
    (workflow["jobs"] || {}).values.flat_map { |job| job["steps"] || [] }
  end

  def checkouts(workflow)
    steps(workflow).select { |step| step["uses"].to_s.start_with?("actions/checkout") }
  end

  WORKFLOWS.each do |path|
    name = path.basename.to_s

    test "#{name} never checks out a dispatch input without resolving it first" do
      workflow = YAML.safe_load(path.read, aliases: true)

      checkouts(workflow).each do |step|
        ref = step.dig("with", "ref").to_s

        # Any dispatch input, whatever it is called -- `ref`, `sha`, `commit`, `tag` --
        # carries the same hazard, so the guard is on the wiring, not on the name.
        refute_match(/inputs\./, ref,
          "#{name} hands a dispatch input straight to actions/checkout, which cannot " \
          "check out an abbreviated SHA -- pass it through #{RESOLVER} first")
      end
    end
  end

  test "Deploy staging resolves the ref, then checks out what the resolver returned" do
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/deploy-staging.yml").read, aliases: true)
    deploy_steps = workflow.dig("jobs", "deploy", "steps")

    resolver = deploy_steps.index { |step| step["id"] == "ref" }
    assert resolver, "the deploy job has no ref-resolving step"
    assert_includes deploy_steps[resolver]["run"], RESOLVER
    # Via `env:`, never interpolated into the command line: a dispatch input on a shell
    # command line is a script-injection hole.
    assert_equal "${{ inputs.ref }}", deploy_steps[resolver].dig("env", "REQUESTED_REF")
    assert_equal "${{ github.sha }}", deploy_steps[resolver].dig("env", "FALLBACK_REF")

    deploying = deploy_steps.index do |step|
      step["uses"].to_s.start_with?("actions/checkout") &&
        step.dig("with", "ref") == "${{ steps.ref.outputs.ref }}"
    end
    assert deploying, "no checkout consumes the resolved ref"
    assert_operator resolver, :<, deploying, "the ref is resolved after it is checked out"

    # The resolver lives in this repo, so something has to put it on disk first.
    assert_operator deploy_steps.index { |step| step["uses"].to_s.start_with?("actions/checkout") },
      :<, resolver, "nothing checks out the resolver before it runs"
  end

  # The description is half the bug: it advertised "SHA", and an abbreviated SHA is the
  # natural thing to paste under that word.
  test "the ref input says what it actually accepts" do
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/deploy-staging.yml").read, aliases: true)

    assert_match(/abbreviated SHA/i, dispatch_inputs(workflow).dig("ref", "description"))
  end

  # Invoked through `bash`, like every other script this workflow runs, so a lost mode bit
  # cannot break a deploy -- but it is committed executable so it also runs by hand.
  test "the resolver is executable" do
    assert Rails.root.join(RESOLVER).executable?, "#{RESOLVER} must be committed with its +x bit"
  end
end
