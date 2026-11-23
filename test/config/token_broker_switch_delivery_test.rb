# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Web decides connector status and Zimmer's own calls; worker decides what a
# session gets. If only one of them had the token broker's switch they would
# disagree, so it is set where both roles read it and never on one role.
class TokenBrokerSwitchDeliveryTest < ActiveSupport::TestCase
  CONFIG = Rails.root.join("config/deploy.production.yml")

  test "the switch is in the environment web and worker share, and on no single role" do
    config = YAML.safe_load(ERB.new(CONFIG.read).result, aliases: true)

    assert config.dig("env", "clear").key?(TokenBroker::ENABLED_ENV)
    assert_equal %w[web worker], config["servers"].keys.sort
    config["servers"].each do |role, options|
      env = options.is_a?(Hash) ? options["env"] : nil
      refute env.to_s.include?(TokenBroker::ENABLED_ENV), "#{role} must not override the switch"
    end
  end

  # YAML reads a bare `false` as a boolean; Kamal would then pass its string form,
  # which works, but a quoted value is the one spelling nobody has to think about.
  test "its value is a string this deployment's broker understands" do
    value = YAML.safe_load(ERB.new(CONFIG.read).result, aliases: true).dig("env", "clear", TokenBroker::ENABLED_ENV)

    assert_includes %w[true false], value
  end
end
