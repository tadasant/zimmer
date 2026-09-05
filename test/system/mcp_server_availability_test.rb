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

  # The reason is catalog-authored text written in a different repository, and it
  # lands in a template literal assigned to innerHTML. A quote that escaped into
  # the row's `title` attribute could close it and add an event handler, so the
  # reason is rendered as text and the title is set as a DOM property.
  test "a reason carrying quotes and angle brackets renders inert" do
    hostile = %(Use "the other one" <img src=x onerror=alert(1)> instead)
    catalog = AVAILABILITY_CATALOG.deep_dup
    catalog["strad-secrets-oauth"]["unavailable"] = hostile
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(catalog)
    SecretsInterpolator.any_instance.stubs(:resolution)
      .returns(SecretsInterpolator::Resolution.new(state: :found, source: "a stubbed provider"))

    visit new_session_path
    find("[data-mcp-server-select-target='input']").click
    assert_selector ".server-item", minimum: 1

    row = find(".server-item[data-name='strad-secrets-oauth']")
    assert_includes row.text, hostile, "the reason is shown verbatim, as text"
    assert_includes row[:title], hostile, "and survives intact in the title property"
    assert_equal 0, page.all("img[src='x']", visible: :all).size,
      "nothing in the reason may become an element"
    assert_no_selector ".server-item[onerror]"
  end

  # The session detail page drives a second controller over the same payload, and
  # the two build their row markup separately — so the badge has to be asserted
  # there rather than inferred from the form.
  test "the session page's MCP editor renders the same badge and reason" do
    session = Session.create!(prompt: "Test prompt", status: :waiting, agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git", branch: "main")

    with_mixed_availability_catalog do
      visit session_path(session)
      find("[data-action~='click->editable-mcp-servers#edit']", match: :first).click
      input = find("[data-editable-mcp-servers-target='input']")
      input.click
      input.fill_in with: "strad"
      assert_selector ".server-item", minimum: 1

      assert_text "STRAD_STAGING_API_KEY unresolved"
      assert_selector ".server-item", text: "Unavailable", minimum: 1
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
