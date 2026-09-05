# frozen_string_literal: true

require "test_helper"

class McpServerOauthRequirementTest < ActiveSupport::TestCase
  KEY = "notion|abc123"

  test "records what the server advertised and reads it back" do
    McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: KEY,
      server_url: "https://mcp.notion.example.com/mcp",
      determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )

    assert_equal McpServerOauthRequirement::ADVERTISED_REQUIRED,
      McpServerOauthRequirement.determination_for(KEY)
    assert_equal true, McpServerOauthRequirement.oauth_required_for(KEY)
  end

  test "records an advertised absence of an OAuth requirement" do
    McpServerOauthRequirement.record!(
      server_name: "public", credential_key: KEY,
      determination: McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED, detail: "HTTP 200"
    )

    assert_equal McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED,
      McpServerOauthRequirement.determination_for(KEY)
    assert_equal false, McpServerOauthRequirement.oauth_required_for(KEY)
  end

  # The fallback contract, at its source: nothing recorded is not an answer, and
  # `oauth_required_for` must say nil rather than false. A false here would
  # silently deny credentials to every server nobody has probed yet.
  test "an unrecorded server is undetermined, not not-required" do
    assert_equal McpServerOauthRequirement::UNDETERMINED,
      McpServerOauthRequirement.determination_for("never-probed|000")
    assert_nil McpServerOauthRequirement.oauth_required_for("never-probed|000")
    assert_nil McpServerOauthRequirement.oauth_required_for(nil)
    assert_equal McpServerOauthRequirement::UNDETERMINED, McpServerOauthRequirement.determination_for("")
  end

  test "an explicitly undetermined record still reads as undetermined" do
    McpServerOauthRequirement.record!(
      server_name: "unreachable", credential_key: KEY,
      determination: McpServerOauthRequirement::UNDETERMINED, detail: "execution expired"
    )

    assert_equal McpServerOauthRequirement::UNDETERMINED, McpServerOauthRequirement.determination_for(KEY)
    assert_nil McpServerOauthRequirement.oauth_required_for(KEY)
  end

  # "Not required" is the only determination whose failure is silent, so it is
  # the only one with a shelf life.
  test "an advertised-not-required answer expires back to undetermined" do
    record = McpServerOauthRequirement.record!(
      server_name: "public", credential_key: KEY,
      determination: McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED
    )
    record.update_column(:determined_at, (McpServerOauthRequirement::NOT_REQUIRED_TTL + 1.day).ago)

    assert record.reload.stale?
    assert_equal McpServerOauthRequirement::UNDETERMINED, McpServerOauthRequirement.determination_for(KEY)
    assert_nil McpServerOauthRequirement.oauth_required_for(KEY),
      "a stale 'no' must fall back to the assumption, never to a confident false"
  end

  test "an advertised-required answer does not expire" do
    record = McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: KEY,
      determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )
    record.update_column(:determined_at, 5.years.ago)

    assert_not record.reload.stale?
    assert_equal true, McpServerOauthRequirement.oauth_required_for(KEY)
  end

  test "the freshest observation replaces the previous one for the same server config" do
    McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: KEY,
      determination: McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED
    )
    McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: KEY,
      determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )

    assert_equal 1, McpServerOauthRequirement.for_credential_key(KEY).count
    assert_equal McpServerOauthRequirement::ADVERTISED_REQUIRED,
      McpServerOauthRequirement.determination_for(KEY)
  end

  test "recording refuses blanks and unknown determinations without raising" do
    assert_nil McpServerOauthRequirement.record!(
      server_name: "", credential_key: KEY, determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )
    assert_nil McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: "", determination: McpServerOauthRequirement::ADVERTISED_REQUIRED
    )
    assert_nil McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: KEY, determination: "maybe"
    )
    assert_equal 0, McpServerOauthRequirement.count
  end

  test "a long detail is truncated rather than failing the write" do
    record = McpServerOauthRequirement.record!(
      server_name: "notion", credential_key: KEY,
      determination: McpServerOauthRequirement::UNDETERMINED, detail: "x" * 600
    )

    assert_equal 255, record.detail.length
  end

  test "description names the branch a human is triaging" do
    record = McpServerOauthRequirement.new(determination: McpServerOauthRequirement::UNDETERMINED)
    assert_match "could not determine", record.description

    record.determination = McpServerOauthRequirement::ADVERTISED_REQUIRED
    assert_match "advertises that it requires OAuth", record.description

    record.determination = McpServerOauthRequirement::ADVERTISED_NOT_REQUIRED
    record.determined_at = Time.current
    assert_match "advertises no OAuth requirement", record.description
  end
end
