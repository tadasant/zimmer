# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The write side of the readiness signal. Its job is the mirror of
# McpServerOptions': to tell a caller that has just named an unstartable server
# so, at the moment it can still act — and to do so without ever standing
# between a caller and a spawn.
class McpServerReadinessTest < ActiveSupport::TestCase
  setup { McpServerOptions::Cache.reset }

  teardown { Mocha::Mockery.instance.teardown }

  test "names the server the caller asked for that cannot start, and why" do
    unavailable = with_mixed_availability_catalog do
      McpServerReadiness.unavailable_among(%w[context7 strad-secrets-staging-rw])
    end

    assert_equal [ "strad-secrets-staging-rw" ], unavailable.map(&:name)
    assert_equal "STRAD_STAGING_API_KEY unresolved", unavailable.first.reason
  end

  test "a server the catalog itself declares dead counts too" do
    unavailable = with_mixed_availability_catalog do
      McpServerReadiness.unavailable_among(%w[strad-secrets-oauth])
    end

    assert_equal [ "strad-secrets-oauth" ], unavailable.map(&:name)
    assert_equal "The endpoint accepts only static bearer tokens and exposes no OAuth discovery.",
      unavailable.first.reason
  end

  test "a list of servers that all start produces nothing to say" do
    unavailable = with_mixed_availability_catalog do
      McpServerReadiness.unavailable_among(%w[context7 zimmer-self-session])
    end

    assert_empty unavailable
    assert_nil McpServerReadiness.warning_for(unavailable)
  end

  test "a name that is not in the catalog is not this check's business" do
    # Catalog membership is already a Session validation (catalog_reference), and
    # reporting a non-existent server as "unavailable" would tell a caller to go
    # and fix a connector that does not exist.
    unavailable = with_mixed_availability_catalog do
      McpServerReadiness.unavailable_among(%w[no-such-server])
    end

    assert_empty unavailable
  end

  test "blank and nil lists ask the probe nothing at all" do
    ConnectorStatusProbe.expects(:all).never

    assert_empty McpServerReadiness.unavailable_among(nil)
    assert_empty McpServerReadiness.unavailable_among([])
    assert_empty McpServerReadiness.unavailable_among([ "", nil ])
  end

  # The whole design in one assertion: this is advice, and advice that cannot be
  # computed must not take a spawn down with it.
  test "a readiness computation that blows up warns about nothing rather than raising" do
    McpServerOptions.stubs(:all).raises(StandardError, "catalog will not resolve")

    assert_nothing_raised do
      assert_empty McpServerReadiness.unavailable_among(%w[context7])
    end
  end

  test "the sentence names every unavailable server, its reason, and the fix" do
    warning = with_mixed_availability_catalog do
      McpServerReadiness.warning_about(%w[context7 strad-secrets-staging-rw strad-secrets-oauth])
    end

    assert_includes warning, "MCP servers"
    assert_includes warning, "strad-secrets-staging-rw (STRAD_STAGING_API_KEY unresolved)"
    assert_includes warning, "strad-secrets-oauth (The endpoint accepts only static bearer tokens"
    refute_includes warning, "context7"
    assert_includes warning, "/connectors"
    assert_includes warning, "The session was created anyway"
  end

  test "one unavailable server reads in the singular" do
    warning = with_mixed_availability_catalog do
      McpServerReadiness.warning_about(%w[strad-secrets-staging-rw])
    end

    assert_includes warning, "MCP server strad-secrets-staging-rw"
    refute_includes warning, "MCP servers"
  end

  # The reason the write paths read the session rather than the arguments: the
  # caller that gets no say is the one that most needs telling. A spawn naming no
  # servers at all inherits its root's defaults, and one of those can be broken.
  test "warn_for_session reads the session's resolved servers, defaults included" do
    session = with_mixed_availability_catalog do
      Session.create!(
        git_root: "https://github.com/t/r.git",
        prompt: "go",
        mcp_servers: %w[context7 strad-secrets-staging-rw]
      )
    end

    warning = with_mixed_availability_catalog { McpServerReadiness.warn_for_session(session) }

    assert_includes warning, "strad-secrets-staging-rw"
  end

  # A flash fades and a tool result scrolls away; the session's own log is where
  # the human and the agent both still find it, next to the failure it predicts.
  test "warn_for_session records the warning in the session's log" do
    session = with_mixed_availability_catalog do
      Session.create!(git_root: "https://github.com/t/r.git", prompt: "go",
        mcp_servers: %w[strad-secrets-staging-rw])
    end

    warning = with_mixed_availability_catalog { McpServerReadiness.warn_for_session(session) }
    log = session.logs.order(:id).last

    assert_equal warning, log.content
    assert_equal "warning", log.level
  end

  test "warn_for_session writes no log and returns nothing when every server starts" do
    session = with_mixed_availability_catalog do
      Session.create!(git_root: "https://github.com/t/r.git", prompt: "go", mcp_servers: %w[context7])
    end

    assert_no_difference "session.logs.count" do
      assert_nil(with_mixed_availability_catalog { McpServerReadiness.warn_for_session(session) })
    end
  end

  # Same argument as the rescue above, one layer out: the log is a side effect of
  # the warning, not a precondition for delivering it.
  test "a log write that fails still returns the warning to the caller" do
    session = with_mixed_availability_catalog do
      Session.create!(git_root: "https://github.com/t/r.git", prompt: "go",
        mcp_servers: %w[strad-secrets-staging-rw])
    end
    session.logs.stubs(:create!).raises(ActiveRecord::StatementInvalid, "logs table is having a day")

    warning = with_mixed_availability_catalog { McpServerReadiness.warn_for_session(session) }

    assert_includes warning, "strad-secrets-staging-rw"
  end

  # The three surfaces must not disagree about which servers cannot start. This
  # one reads the picker's own answer, so a change to BLOCKING_STATES moves both.
  test "the same partition the pickers make" do
    with_mixed_availability_catalog do
      names = McpServerOptions.all.map { |option| option[:name] }

      assert_equal McpServerOptions.all.select { |o| o[:unavailable] }.map { |o| o[:name] }.sort,
        McpServerReadiness.unavailable_among(names).map(&:name).sort,
        "the write paths and the pickers must not disagree about which servers cannot start"
    end
  end

  # ConnectorStatusProbe keeps "Zimmer could not find out" out of BLOCKING_STATES
  # on purpose. Inheriting that here is what stops a Parameter Store blip from
  # papering every spawn with a warning about servers that are perfectly fine.
  test "a secret store that did not answer is not reported as unavailable" do
    outage = SecretsInterpolator::Resolution.new(
      state: :unavailable, error: StandardError.new("Parameter Store timed out")
    )

    unavailable = with_mixed_availability_catalog(resolution: outage) do
      McpServerReadiness.unavailable_among(%w[strad-secrets-staging-rw])
    end

    assert_empty unavailable
  end
end
