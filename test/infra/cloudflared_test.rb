# frozen_string_literal: true

require "test_helper"
require "kamal"

# The optional Cloudflare edge's connector is delivered by scripts/install-cloudflared.sh, a
# deploy-time converge, and by nothing else. These assertions hold the properties that make
# that safe and that nothing at runtime would flag if they regressed:
#
#   1. The tunnel token never enters Terraform or cloud-init. user_data is readable from the
#      DigitalOcean metadata service by every process on the droplet, agent sessions included,
#      and a tunnel token lets its holder run a competing connector that Cloudflare routes real
#      traffic onto.
#   2. The token's host directory is not one an app container mounts.
#   3. Adding the edge opened nothing inbound: the firewall still admits only Tailscale's UDP.
#   4. The connector image is pinned, so a deploy never moves it silently.
class CloudflaredTest < ActiveSupport::TestCase
  include KamalConfigHelpers

  SCRIPT = Rails.root.join("scripts/install-cloudflared.sh")
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")
  TEMPLATE = Rails.root.join("infra/terraform/cloud-init.yaml.tftpl")

  def script = File.read(SCRIPT)

  def token_dir
    script[/^TOKEN_DIR="\$\{ZIMMER_CLOUDFLARED_DIR:-([^}]+)\}"$/, 1].tap do |dir|
      assert dir, "could not find TOKEN_DIR's default in #{SCRIPT.basename}"
    end
  end

  test "neither Terraform nor cloud-init carries a tunnel token" do
    [ MAIN_TF, TEMPLATE ].each do |file|
      refute_match(/tunnel_token|TUNNEL_TOKEN|cloudflared tunnel run|token-file/i, File.read(file), <<~MSG)
        #{file.basename} handles a Cloudflare tunnel token. Anything Terraform renders into
        user_data is readable from the DigitalOcean metadata service by every agent session on
        the droplet. Deliver the token through scripts/install-cloudflared.sh instead.
      MSG
    end
  end

  test "the token directory is outside every path an app container mounts" do
    dir = token_dir
    KamalConfigHelpers::DEPLOY_DESTINATIONS.each do |destination|
      %w[web worker].each do |role|
        kamal_volumes(destination, role).each do |volume|
          source = volume.split(":").first
          next unless source.start_with?("/") # named volumes live under Docker's own root

          refute dir.start_with?(source.chomp("/") + "/") || dir == source || source.start_with?(dir),
            "#{destination}/#{role} mounts #{source}, which overlaps the tunnel token's #{dir}"
        end
      end
    end
  end

  test "the connector runs outbound-only on the host network with a pinned image" do
    assert_match(%r{^IMAGE="cloudflare/cloudflared:\d{4}\.\d+\.\d+"$}, script,
      "the cloudflared image must be pinned to a release tag, never latest")
    assert_match(/--network host/, script)
    assert_match(/--restart unless-stopped/, script)
    assert_match(/tunnel run --token-file /, script,
      "the token must be read from a file: as an argument or env var it shows in `docker inspect`")
    refute_match(/\s-p\s|--publish/, script, "the connector must publish no port")
  end

  test "an empty token is a no-op, and removal needs an explicit opt-in" do
    empty_branch = script[/^if \[ -z "\$TOKEN" \]; then\n(.*?)^fi$/m, 1]
    assert empty_branch, "the empty-token branch is gone"
    assert_match(/exit 0/, empty_branch)
    assert_match(/if \[ "\$REMOVE" = "1" \]/, empty_branch,
      "an unset token must not take a running tunnel down on its own")
  end

  test "the firewall still admits exactly one inbound rule, Tailscale's UDP" do
    firewall = File.read(MAIN_TF)[/resource "digitalocean_firewall" "zimmer" \{.*?\n\}/m]
    inbound = firewall.scan(/inbound_rule \{(.*?)\}/m).flatten

    assert_equal 1, inbound.size, "the droplet firewall gained an inbound rule"
    assert_match(/protocol\s*=\s*"udp"/, inbound.first)
    assert_match(/port_range\s*=\s*"41641"/, inbound.first)
  end
end
