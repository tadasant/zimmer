# frozen_string_literal: true

require "test_helper"

# `monitoring` turns on DigitalOcean's metrics agent, and it is ForceNew in the provider
# (every release in the 2.x line, including the `~> 2.43` this module pins; the resource's
# Update function has no `monitoring` branch, and DigitalOcean exposes no droplet action
# to enable it either). So the argument is only half of the change -- the other half is
# `ignore_changes`.
#
# Without it, an apply against a droplet whose state has monitoring false plans a REPLACE
# of the persistent host. That is not a hypothetical review catch: both environments apply
# with `-auto-approve`, the production one from the companion repo, so nobody reads the
# plan first. These assertions fail the build if the two ever come apart.
class DropletMonitoringTest < ActiveSupport::TestCase
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")
  STAGING_TFVARS = Rails.root.join("infra/terraform/staging.tfvars.example")
  DEPLOY_STAGING = Rails.root.join(".github/workflows/deploy-staging.yml")

  test "the droplet asks for the DigitalOcean metrics agent" do
    assert_match(/^\s*monitoring\s*=\s*var\.monitoring\s*$/, droplet,
      "The droplet no longer wires `monitoring` to var.monitoring, so a downstream copy of " \
      "this module cannot turn the metrics agent off without forking the file.")

    assert_match(/^\s*default\s*=\s*true\s*$/, monitoring_variable,
      "var.monitoring no longer defaults to true, so DigitalOcean would collect no CPU, " \
      "memory, disk or load history for a droplet this module creates and DO's own resource " \
      "alert policies -- which evaluate agent-reported metrics -- could not target it.")
  end

  test "monitoring is under ignore_changes, so enabling it can never replace the droplet" do
    assert_includes ignore_changes, "monitoring", <<~MSG
      `monitoring` is set on the droplet but is not in its `ignore_changes` list. It is
      ForceNew in the DigitalOcean provider, so for any droplet that already exists this
      plans DESTROY AND RECREATE -- of the box that runs every session -- and the applies
      are `-auto-approve`, so no human sees that plan.

      A new droplet gets the agent on create, which `ignore_changes` does not affect. An
      existing one gets it from a deploy-time converge instead; see docs limitations and
      tadasant/zimmer#651.

      ignore_changes = [#{ignore_changes.join(", ")}]
    MSG
  end

  # Staging has no do-agent converge step, and the docs say why: every staging droplet is
  # created by this module (`Teardown staging` destroys it, `Deploy staging` creates the
  # next), so the create-time attribute reaches all of them. That holds only while staging
  # keeps var.monitoring on. Turning it off would ship staging droplets with no agent and
  # nothing to install one.
  test "staging never turns monitoring off, so its droplets need no converge" do
    # Any assignment but a literal `true` (a trailing comment allowed).
    assigned = File.readlines(STAGING_TFVARS).grep(/^\s*monitoring\s*=(?!\s*true\s*(#.*)?$)/)
    assert_empty assigned, <<~MSG
      staging.tfvars.example turns `monitoring` off. `Deploy staging` copies that file
      verbatim, and a -var-file value beats TF_VAR_*, so this decides whether a staging
      droplet gets DigitalOcean's metrics agent at creation.

      Staging has no deploy-time do-agent converge because every staging droplet gets the
      agent at creation. With it off, that no longer holds: either drop the assignment or
      give staging a converge step, and update docs limitations ("Terraform gives the
      DigitalOcean metrics agent only to a droplet it creates").

      #{assigned.join}
    MSG

    workflow = File.read(DEPLOY_STAGING)
    refute_match(/TF_VAR_monitoring\b|-var[\s=]+["']?monitoring\s*=/, workflow,
      "deploy-staging.yml overrides var.monitoring. Staging's droplets were the ones that " \
      "needed no do-agent converge because the module default gave them the agent at " \
      "creation; see docs limitations before changing that.")
  end

  test "user_data stays under ignore_changes alongside it" do
    assert_includes ignore_changes, "user_data",
      "`user_data` dropped out of ignore_changes -- that is the setting that stops a " \
      "bootstrap-template edit from force-replacing the persistent droplet."
  end

  private

  # Parsed per-test rather than into a constant: a constant would read the file at load
  # time, so a moved main.tf would abort the whole runner, and a block that stopped
  # parsing would surface as NoMethodError on nil instead of the messages above.
  def droplet
    @droplet ||= begin
      body = File.read(MAIN_TF)[/resource "digitalocean_droplet" "zimmer" \{.*?\n\}/m]
      assert body, "resource \"digitalocean_droplet\" \"zimmer\" not found in #{MAIN_TF} -- " \
        "this test cannot check anything until that block parses again."
      body
    end
  end

  def monitoring_variable
    @monitoring_variable ||= begin
      body = File.read(MAIN_TF)[/variable "monitoring" \{.*?\n\}/m]
      assert body, "variable \"monitoring\" not found in #{MAIN_TF} -- the droplet's " \
        "`monitoring = var.monitoring` would not even plan."
      body
    end
  end

  def ignore_changes
    @ignore_changes ||= droplet[/ignore_changes\s*=\s*\[([^\]]*)\]/m, 1].to_s.split(",").map(&:strip)
  end
end
