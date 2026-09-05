# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The list every human-facing picker and REST server list is built from. Its job
# is to carry one fact the catalog cannot supply: whether Zimmer can actually
# start each server. Getting that wrong in either direction is expensive — a
# server wrongly flagged is one a human stops using, and a server wrongly cleared
# is a session that dies at prepare time.
class McpServerOptionsTest < ActiveSupport::TestCase
  teardown do
    Mocha::Mockery.instance.teardown
  end

  test "carries every catalog server, flagged, rather than filtering any out" do
    options = with_mixed_availability_catalog { McpServerOptions.all }

    assert_equal %w[context7 zimmer-self-session strad-secrets-staging-rw strad-secrets-oauth],
      options.map { |o| o[:name] },
      "the picker shows the whole catalog in catalog order — omission is get_configs's remedy, not this one"
  end

  test "a server whose required variable does not resolve is flagged, and the reason names the variable" do
    options = with_mixed_availability_catalog { McpServerOptions.all }
    option = option_for(options, "strad-secrets-staging-rw")

    assert option[:unavailable]
    assert_equal "STRAD_STAGING_API_KEY unresolved", option[:unavailable_reason]
  end

  test "the reason is plain text — a backtick would render as a backtick in the picker" do
    options = with_mixed_availability_catalog { McpServerOptions.all }

    refute_includes option_for(options, "strad-secrets-staging-rw")[:unavailable_reason], "`"
  end

  test "a server the catalog declares unavailable is flagged with the catalog's own reason" do
    options = with_mixed_availability_catalog { McpServerOptions.all }
    option = option_for(options, "strad-secrets-oauth")

    assert option[:unavailable]
    assert_equal "The endpoint accepts only static bearer tokens and exposes no OAuth discovery.",
      option[:unavailable_reason]
  end

  test "a healthy server carries no flag and no reason" do
    options = with_mixed_availability_catalog { McpServerOptions.all }
    option = option_for(options, "context7")

    assert_equal false, option[:unavailable]
    assert_nil option[:unavailable_reason]
    assert_equal "Context7", option[:title]
    assert_equal "Up-to-date library documentation lookup.", option[:description]
  end

  # The failure mode worth guarding: "the secret store did not answer" is not
  # the same fact as "this secret is not set". Flagging a working server during
  # a store blip would send a human off to seed a credential that is already
  # there — and it would hit every server at once. ConnectorStatusProbe keeps
  # those states out of BLOCKING_STATES for exactly this reason; this pins that
  # the picker inherits the decision rather than re-deciding it.
  test "a server whose secret store could not be reached is NOT flagged" do
    outage = SecretsInterpolator::Resolution.new(
      state: :unavailable, error: StandardError.new("Parameter Store timed out")
    )
    options = with_mixed_availability_catalog(resolution: outage) { McpServerOptions.all }
    option = option_for(options, "strad-secrets-staging-rw")

    assert_equal false, option[:unavailable],
      "an indeterminate answer must not read as unavailable — reporting it as usable is the cheaper mistake"
    assert_nil option[:unavailable_reason]
  end

  test "the same partition get_configs makes" do
    options = with_mixed_availability_catalog { McpServerOptions.all }
    probed = with_mixed_availability_catalog { ConnectorStatusProbe.all }

    assert_equal probed.reject(&:available?).map(&:server_name).sort,
      options.select { |o| o[:unavailable] }.map { |o| o[:name] }.sort,
      "the human surfaces and the agent surface must not disagree about which servers cannot start"
  end

  # A picker that renders nothing is far worse than a picker without flags: the
  # form would offer no servers at all, which reads as an empty catalog.
  test "falls back to the catalog when the readiness computation fails outright" do
    ConnectorStatusProbe.stubs(:all).raises(StandardError, "probe exploded")

    options = with_mixed_availability_catalog { McpServerOptions.all }

    assert_equal 4, options.size
    assert options.none? { |o| o[:unavailable] }, "say nothing rather than claim everything is broken"
    assert options.all? { |o| o[:title].present? }
  end

  test "the fallback says why in the log" do
    ConnectorStatusProbe.stubs(:all).raises(StandardError, "probe exploded")

    entries = capture_log_entries do
      with_mixed_availability_catalog { McpServerOptions.all }
    end

    assert_match(/McpServerOptions.*falling back to catalog.*probe exploded/, entries.map(&:last).join("\n"))
  end
end
