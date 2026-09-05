require "application_system_test_case"
require "mocha/minitest"

# The session form's MCP picker is the human write path into session creation,
# and it used to offer every catalog server identically — including ones Zimmer
# already knew could not start. That is not a soft failure: an unresolved
# `${VAR}` raises SecretsInterpolator::MissingVariableError at prepare time and
# fails the whole session, not just that server. `get_configs` has protected
# agents against picking one since #539; this is the same signal for the person
# at the form (#538).
#
# The remedy here is deliberately not get_configs's. That surface omits an
# unavailable server, because an agent's list is a menu of things it may pass to
# `start_session` and it can fix none of the reasons. A human can fix most of
# them — "OAuth authorization not completed" is one click away at /connectors —
# so an entry that is present and says why is worth more to them than a silent
# absence, which reads as a broken catalog. Flagged, sorted last, still
# selectable: refusing the pick is the write path and belongs to #537.
class McpServerAvailabilityTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  def teardown
    Mocha::Mockery.instance.teardown
    super
  end

  # Opens the new-session form's MCP dropdown with the mixed catalog seeded.
  def open_picker
    with_mixed_availability_catalog do
      visit new_session_path
      find("[data-mcp-server-select-target='input']").click
      assert_selector ".server-item", minimum: 1
      yield
    end
  end

  test "an unavailable server is shown with a reason rather than silently dropped" do
    open_picker do
      # The entry exists — omitting it would read as a broken catalog.
      assert_text "Strad Secrets Staging"
      assert_text "STRAD_STAGING_API_KEY unresolved"
      assert_text "The endpoint accepts only static bearer tokens and exposes no OAuth discovery."
      assert_selector ".server-item", text: "Unavailable", count: 2
    end
  end

  test "an available server is unchanged — no badge, no reason, still pickable" do
    open_picker do
      row = find(".server-item", text: "Context7")
      refute_includes row.text, "Unavailable"

      row.click
      assert_selector "[data-mcp-server-select-target='selectedContainer']", text: "Context7"
    end
  end

  test "unavailable servers sort below the ones that work" do
    open_picker do
      titles = all(".server-item").map { |row| row.text.lines.first.strip }

      assert_equal "Context7", titles.first
      assert_equal [ "Strad Secrets Staging", "Strad Secrets (OAuth)" ].sort, titles.last(2).sort,
        "the flag must not bury a server you can actually pick"
    end
  end

  # Picking one is still allowed — this change is the read path, and the list's
  # job is to say. What it must not do is let the pick pass unmarked.
  test "picking an unavailable server carries the warning onto the selected tag" do
    open_picker do
      find(".server-item", text: "Strad Secrets Staging").click

      tag = find("[data-mcp-server-select-target='selectedContainer'] span", text: "Strad Secrets Staging")
      assert_includes tag[:class], "bg-amber-100", "a warned pick must not look like an ordinary one"
      assert_includes tag[:title], "STRAD_STAGING_API_KEY unresolved"
    end
  end

  test "the reason renders as text, not as the markdown get_configs emits" do
    open_picker do
      refute_includes find(".server-item", text: "Strad Secrets Staging").text, "`"
    end
  end

  # The badge and the reason are new markup inside a dropdown row that is already
  # width-capped at `innerWidth - 32`, and the warning chip gains an icon beside
  # its text. Both land on a screen people read on a phone, so both are measured
  # there rather than assumed to fit.
  test "the flagged picker fits a phone" do
    page.driver.browser.manage.window.resize_to(MobileOverflowAssertions::MOBILE_WIDTH,
      MobileOverflowAssertions::MOBILE_HEIGHT)

    with_mixed_availability_catalog do
      visit new_session_path
      input = find("[data-mcp-server-select-target='input']")
      input.click
      assert_selector ".server-item", minimum: 1
      assert_text "STRAD_STAGING_API_KEY unresolved"
      assert_no_horizontal_overflow("the new session form with a flagged MCP server in the dropdown")

      # And with one picked, so the amber chip is measured too.
      find(".server-item", text: "Strad Secrets Staging").click
      assert_selector "[data-mcp-server-select-target='selectedContainer']", text: "Strad Secrets Staging"
      assert_no_horizontal_overflow("the new session form with an unavailable MCP server selected")
    end
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  # A store outage hits every server at once. Painting the whole picker amber
  # for a blip that fixes itself would be a worse lie than offering a server
  # that might not start, so ConnectorStatusProbe reports those as available and
  # the picker inherits that.
  test "a server whose secret store could not be reached is not flagged" do
    outage = SecretsInterpolator::Resolution.new(
      state: :unavailable, error: StandardError.new("Parameter Store timed out")
    )
    with_mixed_availability_catalog(resolution: outage) do
      visit new_session_path
      find("[data-mcp-server-select-target='input']").click
      assert_selector ".server-item", minimum: 1

      refute_includes find(".server-item", text: "Strad Secrets Staging").text, "Unavailable"
      assert_selector ".server-item", text: "Unavailable", count: 1, exact_text: false
    end
  end
end
