# frozen_string_literal: true

require "test_helper"

class HumanIdentityTest < ActiveSupport::TestCase
  teardown do
    ENV.delete(HumanIdentity::SLACK_ID_ENV_KEY)
    HumanIdentity.reset_cache!
  end

  test "seeds the two humans that exist" do
    assert_equal %w[tadasant juliehazz], HumanIdentity.names
    assert_equal "Tadas", HumanIdentity.find("tadasant").display_name
    assert_equal "Julie", HumanIdentity.find("juliehazz").display_name
  end

  test "find returns nil for an unknown or blank name" do
    assert_nil HumanIdentity.find("zimmer-router")
    assert_nil HumanIdentity.find(nil)
    assert_nil HumanIdentity.find("")
  end

  test "the web UI human is Tadas" do
    assert_equal "tadasant", HumanIdentity.web_ui.name
  end

  # Slack IDs are deployment configuration, never application source. Shipped
  # empty, so an unconfigured deployment attributes no Slack message to anyone.
  test "no Slack user IDs are hardcoded in the checked-in config" do
    assert_empty HumanIdentity.slack_id_map
    assert_nil HumanIdentity.for_slack_user_id("U01ANYTHING")
  end

  test "resolves a Slack user ID from the deployment env var" do
    ENV[HumanIdentity::SLACK_ID_ENV_KEY] = "U01TADAS:tadasant,U07JULIE:juliehazz"

    assert_equal "tadasant", HumanIdentity.for_slack_user_id("U01TADAS").name
    assert_equal "juliehazz", HumanIdentity.for_slack_user_id("U07JULIE").name
  end

  test "tolerates whitespace and empty entries in the env var" do
    ENV[HumanIdentity::SLACK_ID_ENV_KEY] = " U01TADAS : tadasant , ,U07JULIE:juliehazz,"

    assert_equal "tadasant", HumanIdentity.for_slack_user_id("U01TADAS").name
    assert_equal "juliehazz", HumanIdentity.for_slack_user_id("U07JULIE").name
  end

  # A pair naming an identity that does not exist must not invent an author.
  test "drops a mapping to an unknown identity name" do
    ENV[HumanIdentity::SLACK_ID_ENV_KEY] = "U01BOT:some-agent"

    assert_nil HumanIdentity.for_slack_user_id("U01BOT")
  end

  test "an unmapped Slack user ID resolves to nobody" do
    ENV[HumanIdentity::SLACK_ID_ENV_KEY] = "U01TADAS:tadasant"

    assert_nil HumanIdentity.for_slack_user_id("U99STRANGER")
    assert_nil HumanIdentity.for_slack_user_id(nil)
    assert_nil HumanIdentity.for_slack_user_id("")
  end

  test "identities compare by name" do
    assert_equal HumanIdentity.find("tadasant"), HumanIdentity.find("tadasant")
    refute_equal HumanIdentity.find("tadasant"), HumanIdentity.find("juliehazz")
  end
end
