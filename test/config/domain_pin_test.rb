# frozen_string_literal: true

require "test_helper"
require "kamal"

# ZIMMER_PIN_DOMAIN_TO_HOST writes `<domain> -> host-gateway` into the web and worker
# containers' /etc/hosts, so an agent session's call to https://<domain>/mcp stays on the box
# (the host Caddy on :443) even when public DNS points the domain somewhere else -- behind the
# optional Cloudflare edge, at Cloudflare, where the call would meet Cloudflare Access.
#
# Two properties, both about the `docker run` Kamal actually issues:
#
#   1. Unset changes nothing, for every destination. This is a shared base config.
#   2. Set reaches BOTH roles. Sessions run in the worker; pinning only `web` would look
#      configured and leave every agent call going out to the edge.
class DomainPinTest < ActiveSupport::TestCase
  include KamalConfigHelpers

  DOMAIN = "zimmer.example.com"
  ROLES = %w[web worker].freeze

  KamalConfigHelpers::DEPLOY_DESTINATIONS.each do |destination|
    test "#{destination}: unset adds no host entry to either role" do
      ROLES.each do |role|
        refute_match(/--add-host/, kamal_docker_run(destination, role),
          "#{destination}/#{role} got an --add-host with ZIMMER_PIN_DOMAIN_TO_HOST unset")
      end
    end

    test "#{destination}: set pins the domain to host-gateway in web AND worker" do
      ROLES.each do |role|
        run = kamal_docker_run(destination, role, env: { "ZIMMER_PIN_DOMAIN_TO_HOST" => DOMAIN })

        assert_equal [ "#{DOMAIN}:host-gateway" ],
          run.scan(/--add-host "?([^"\s]+)"?/).flatten,
          "#{destination}/#{role} must carry exactly one --add-host #{DOMAIN}:host-gateway"
      end
    end
  end

  test "a value that is not a bare hostname refuses to render" do
    [ "zimmer.example.com:1.2.3.4", "a b", "https://zimmer.example.com" ].each do |bad|
      error = assert_raises(StandardError) do
        kamal_config("production", env: { "ZIMMER_PIN_DOMAIN_TO_HOST" => bad })
      end
      assert_match(/ZIMMER_PIN_DOMAIN_TO_HOST must be a bare hostname/, error.message)
    end
  end
end
