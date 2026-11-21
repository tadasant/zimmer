# frozen_string_literal: true

require "test_helper"

class SecretProvidersEnvInspectTest < ActiveSupport::TestCase
  test "inspect never prints the environment it reads" do
    provider = SecretProviders::Env.new({ "SOME_SECRET" => "value-that-must-not-print-0123456789" })
    resolution = SecretsInterpolator::Resolution.new(state: :found, source: provider)

    refute_includes provider.inspect, "value-that-must-not-print"
    refute_includes resolution.inspect, "value-that-must-not-print"
    assert_equal "value-that-must-not-print-0123456789", provider.get("SOME_SECRET")
  end
end
