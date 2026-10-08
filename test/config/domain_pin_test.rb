# frozen_string_literal: true

require "test_helper"
require "kamal"

# ZIMMER_PIN_DOMAIN_TO_HOST writes `<domain> -> deploy-host-address` into the web and worker
# containers' /etc/hosts, so an agent session's call to https://<domain>/mcp stays on the box
# (the host Caddy on :443) even when public DNS points the domain somewhere else -- behind the
# optional Cloudflare edge, at Cloudflare, where the call would meet Cloudflare Access. Docker's
# `host-gateway` token is deliberately not used: it resolves to docker0 even though Kamal app
# containers run on the separate `kamal` bridge, and docker0 may be down.
#
# Two properties, both about the `docker run` Kamal actually issues:
#
#   1. Unset changes nothing, for every destination. This is a shared base config.
#   2. Set reaches BOTH roles. Sessions run in the worker; pinning only `web` would look
#      configured and leave every agent call going out to the edge.
class DomainPinTest < ActiveSupport::TestCase
  include KamalConfigHelpers

  DOMAIN = "zimmer.example.com"
  ADDRESS = "100.64.0.42"
  ROLES = %w[web worker].freeze

  KamalConfigHelpers::DEPLOY_DESTINATIONS.each do |destination|
    test "#{destination}: unset adds no host entry to either role" do
      ROLES.each do |role|
        refute_match(/--add-host/, kamal_docker_run(destination, role),
          "#{destination}/#{role} got an --add-host with ZIMMER_PIN_DOMAIN_TO_HOST unset")
      end
    end

    test "#{destination}: set pins the domain to the deploy host in web AND worker" do
      ROLES.each do |role|
        run = kamal_docker_run(destination, role, env: {
          "ZIMMER_PIN_DOMAIN_TO_HOST" => DOMAIN,
          "ZIMMER_PIN_DOMAIN_TO_ADDRESS" => ADDRESS
        })

        assert_equal [ "#{DOMAIN}:#{ADDRESS}" ],
          run.scan(/--add-host "?([^"\s]+)"?/).flatten,
          "#{destination}/#{role} must carry exactly one --add-host #{DOMAIN}:#{ADDRESS}"
        refute_includes run, "host-gateway"
      end
    end
  end

  test "production derives the address from its sole deploy host" do
    run = kamal_docker_run("production", "worker", env: {
      "ZIMMER_PIN_DOMAIN_TO_HOST" => DOMAIN,
      "PRODUCTION_HOST" => ADDRESS,
      "STAGING_HOST" => nil
    })

    assert_includes run, %(--add-host "#{DOMAIN}:#{ADDRESS}")
    refute_includes run, "host-gateway"
  end

  test "staging derives the address from its sole deploy host" do
    run = kamal_docker_run("staging", "worker", env: {
      "ZIMMER_PIN_DOMAIN_TO_HOST" => DOMAIN,
      "PRODUCTION_HOST" => nil,
      "STAGING_HOST" => ADDRESS
    })

    assert_includes run, %(--add-host "#{DOMAIN}:#{ADDRESS}")
    refute_includes run, "host-gateway"
  end

  test "a value that is not a bare hostname refuses to render" do
    [ "zimmer.example.com:1.2.3.4", "a b", "https://zimmer.example.com" ].each do |bad|
      error = assert_raises(StandardError) do
        kamal_config("production", env: { "ZIMMER_PIN_DOMAIN_TO_HOST" => bad })
      end
      assert_match(/ZIMMER_PIN_DOMAIN_TO_HOST must be a bare hostname/, error.message)
    end
  end

  test "a pin with no unambiguous deploy address refuses to render" do
    error = assert_raises(StandardError) do
      kamal_config("production", env: {
        "ZIMMER_PIN_DOMAIN_TO_HOST" => DOMAIN,
        "PRODUCTION_HOST" => nil,
        "STAGING_HOST" => nil
      })
    end

    assert_match(/requires one deploy host address or ZIMMER_PIN_DOMAIN_TO_ADDRESS/, error.message)
  end

  test "an invalid explicit address refuses to render" do
    error = assert_raises(StandardError) do
      kamal_config("production", env: {
        "ZIMMER_PIN_DOMAIN_TO_HOST" => DOMAIN,
        "ZIMMER_PIN_DOMAIN_TO_ADDRESS" => "host-gateway"
      })
    end

    assert_match(/ZIMMER_PIN_DOMAIN_TO_ADDRESS must be an IP address/, error.message)
  end
end
