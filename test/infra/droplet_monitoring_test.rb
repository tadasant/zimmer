# frozen_string_literal: true

require "test_helper"

# `monitoring` turns on DigitalOcean's metrics agent, and it is ForceNew in the provider
# (every release in the 2.x line, including the `~> 2.43` this module pins; the resource's
# Update function has no `monitoring` branch at all). So the argument is only half of the
# change -- the other half is `ignore_changes`.
#
# Without it, an apply against a droplet created before the flag existed plans a REPLACE of
# the persistent host every Zimmer session runs on. That is not a hypothetical review catch:
# deploy-staging.yml applies with `-auto-approve`, so nobody reads the plan first. These
# assertions fail the build if the two ever come apart.
class DropletMonitoringTest < ActiveSupport::TestCase
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")
  DROPLET = File.read(MAIN_TF)[/resource "digitalocean_droplet" "zimmer" \{.*?\n\}/m]

  test "the droplet resource is still parseable out of main.tf" do
    assert DROPLET, "resource \"digitalocean_droplet\" \"zimmer\" not found in main.tf -- " \
      "the other assertions in this file are vacuous until this parses again."
  end

  test "the droplet asks for the DigitalOcean metrics agent" do
    assert_match(/^\s*monitoring\s*=\s*true\s*$/, DROPLET,
      "The droplet no longer sets `monitoring = true`, so DigitalOcean collects no CPU, " \
      "memory, disk or load history for it and DO's own resource alert policies -- which " \
      "evaluate agent-reported metrics -- cannot target it.")
  end

  test "monitoring is under ignore_changes, so enabling it can never replace the droplet" do
    ignored = DROPLET[/ignore_changes\s*=\s*\[([^\]]*)\]/m, 1].to_s.split(",").map(&:strip)

    assert_includes ignored, "monitoring", <<~MSG
      `monitoring` is set on the droplet but is not in its `ignore_changes` list. It is
      ForceNew in the DigitalOcean provider, so for any droplet that already exists this
      plans DESTROY AND RECREATE -- of the box that runs every session -- and
      deploy-staging.yml applies with -auto-approve, so no human sees that plan.

      An existing droplet gets the agent from the DigitalOcean control panel toggle (or an
      `enable_monitoring` droplet action) instead; a new one gets it on create, which
      `ignore_changes` does not affect.

      ignore_changes = [#{ignored.join(", ")}]
    MSG
  end

  test "user_data stays under ignore_changes alongside it" do
    ignored = DROPLET[/ignore_changes\s*=\s*\[([^\]]*)\]/m, 1].to_s.split(",").map(&:strip)

    assert_includes ignored, "user_data",
      "`user_data` dropped out of ignore_changes -- that is the setting that stops a " \
      "bootstrap-template edit from force-replacing the persistent droplet."
  end
end
