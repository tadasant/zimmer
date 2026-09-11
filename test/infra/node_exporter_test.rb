# frozen_string_literal: true

require "test_helper"

# node_exporter is OPT-IN host telemetry: `var.node_exporter_enabled` (default false) makes
# cloud-init install a pinned node_exporter as a systemd unit, bound to the droplet's TAILNET
# address only.
#
# Two properties carry the whole design, and neither is visible from reading main.tf alone:
#
#   1. OFF changes nothing. The default has to stay false and the gated blocks have to stay
#      gated, or a module every downstream copy mirrors starts installing a daemon nobody
#      asked for on the next rebuild.
#   2. The bind is the security boundary. The DO firewall admits exactly one inbound rule
#      (UDP 41641) and no public TCP, so `0.0.0.0` is not reachable from the internet TODAY --
#      but the bind is the half that does not depend on the firewall staying that way.
#
# These assertions read the RENDERED cloud-config (see CloudInitRender), not the raw template,
# so they check what the droplet would actually receive.
class NodeExporterTest < ActiveSupport::TestCase
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")

  # Pinned deliberately: node_exporter reshapes collectors between minor releases, which moves
  # metric cardinality under whatever scrapes it. Bump this, the checksum, and the template
  # together.
  PINNED_VERSION = "1.12.1"

  test "the variable defaults to false, so an existing consumer gets nothing new" do
    block = File.read(MAIN_TF)[/variable "node_exporter_enabled" \{.*?\n\}/m]
    assert block, "variable \"node_exporter_enabled\" is gone from #{MAIN_TF} -- there is no " \
      "longer any way to opt into host metrics without forking this module."
    assert_match(/^\s*default\s*=\s*false\s*$/, block, <<~MSG)
      node_exporter_enabled no longer defaults to false. This module is mirrored byte-for-byte
      into a downstream configuration repo; a true default installs a daemon on every droplet
      that repo rebuilds, without anyone asking for it.
    MSG
  end

  test "main.tf passes the flag through to the cloud-init template" do
    templatefile = File.read(MAIN_TF)[/templatefile\(.*?\n(.*?)\n\s*\}\)/m, 1].to_s
    assert_match(/^\s*node_exporter_enabled\s*=\s*var\.node_exporter_enabled\s*$/, templatefile,
      "main.tf stopped passing node_exporter_enabled to templatefile(), so the variable is " \
      "inert -- setting it true would install nothing.")
  end

  test "with the flag off the rendered cloud-config mentions node_exporter nowhere" do
    refute_match(/node_exporter/, CloudInitRender.render(node_exporter_enabled: false),
      "A cloud-config rendered with node_exporter_enabled = false must carry no trace of " \
      "the exporter -- that is what makes this variable safe to add to a shared module.")
  end

  test "with the flag on the unit binds the tailnet address, never 0.0.0.0" do
    wrapper = write_file("/usr/local/bin/zimmer-node-exporter").fetch("content")

    assert_match(/tailscale0/, wrapper,
      "the exporter wrapper no longer reads the tailnet interface")
    assert_match(/--web\.listen-address="\$addr:9100"/, wrapper,
      "the exporter must bind the address resolved from tailscale0, on :9100")
    refute_match(/0\.0\.0\.0|\[::\]|--web\.listen-address=":/, wrapper, <<~MSG)
      The exporter binds a wildcard address. The DigitalOcean firewall in this module opens no
      public TCP at all, so nothing is exposed the moment this lands -- but it filters the
      PUBLIC interface only, and the bind is what keeps :9100 tailnet-scoped independently of
      anyone ever adding a TCP rule. Bind the tailscale0 address.
    MSG
  end

  test "the systemd unit runs the exporter unprivileged and keeps retrying the tailnet" do
    unit = write_file("/etc/systemd/system/node_exporter.service").fetch("content")

    assert_match(/^User=node_exporter$/, unit, "the exporter must not run as root")
    assert_match(%r{^ExecStart=/usr/local/bin/zimmer-node-exporter$}, unit,
      "the unit must start through the wrapper -- the tailnet address does not exist at " \
      "render time, so it cannot be baked into ExecStart")
    # The wrapper exits 1 after two minutes without a tailnet address. systemd's default start
    # limit (5 starts in 10s) would then leave the unit dead for good on a slow tailnet join.
    assert_match(/^StartLimitIntervalSec=0$/, unit)
    assert_match(/^Restart=always$/, unit)
  end

  test "the installed version is pinned and checksum-verified" do
    install = CloudInitRender.parse(node_exporter_enabled: true)
      .fetch("runcmd").grep(String).find { |c| c.include?("node_exporter-") }
    assert install, "no runcmd entry installs node_exporter"

    assert_match(/^\s*ver=#{Regexp.escape(PINNED_VERSION)}$/, install, <<~MSG)
      node_exporter is no longer installed at a pinned version. Tracking latest moves metric
      cardinality under the scraper between minor releases, which is exactly what the pin is
      for.
    MSG
    assert_match(/^\s*sha=[0-9a-f]{64}$/, install,
      "the download must be checksum-verified")
    assert_match(/sha256sum -c -/, install,
      "the checksum must actually be CHECKED, not merely recorded")
    assert_match(/^\s*set -eu$/, install, <<~MSG)
      The install block must run under `set -e`. cloud-init does not abort a runcmd entry on a
      failed command, so without it a checksum mismatch would be logged and the unverified
      binary installed anyway.
    MSG
  end

  private

  def write_file(path)
    files = CloudInitRender.parse(node_exporter_enabled: true).fetch("write_files")
    found = files.find { |f| f["path"] == path }
    assert found, "the rendered cloud-config writes no #{path} (paths: #{files.map { _1['path'] }.join(', ')})"
    found
  end
end
