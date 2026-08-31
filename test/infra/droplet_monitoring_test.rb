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

  test "the droplet asks for the DigitalOcean metrics agent" do
    assert_match(/^\s*monitoring\s*=\s*true\s*$/, droplet,
      "The droplet no longer sets `monitoring = true`, so DigitalOcean collects no CPU, " \
      "memory, disk or load history for it and DO's own resource alert policies -- which " \
      "evaluate agent-reported metrics -- cannot target it.")
  end

  test "monitoring is under ignore_changes, so enabling it can never replace the droplet" do
    assert_includes ignore_changes, "monitoring", <<~MSG
      `monitoring` is set on the droplet but is not in its `ignore_changes` list. It is
      ForceNew in the DigitalOcean provider, so for any droplet that already exists this
      plans DESTROY AND RECREATE -- of the box that runs every session -- and the applies
      are `-auto-approve`, so no human sees that plan.

      A new droplet gets the agent on create, which `ignore_changes` does not affect. An
      existing one only gets it from a rebuild; see tadasant/zimmer#651.

      ignore_changes = [#{ignore_changes.join(", ")}]
    MSG
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

  def ignore_changes
    @ignore_changes ||= droplet[/ignore_changes\s*=\s*\[([^\]]*)\]/m, 1].to_s.split(",").map(&:strip)
  end
end
