require "application_system_test_case"
require "mocha/minitest"

# The two behaviours of connector_list_controller that only exist in a browser:
# every row's badge resolves without the reader scrolling to it, and once they
# have, the rows re-order so the problems are first.
#
# These are exactly the assertions the integration tests cannot make. Those check
# that the markup carries `data-connector-list-target` and `data-connector-rank`,
# and they would pass with the controller deleted — which is the whole feature.
# So the interesting cases live here.
class ConnectorsListTest < ApplicationSystemTestCase
  # Enough rows that most of them are far below any viewport, and a deliberate
  # mix of states so the sort has something to do. The names are chosen so the
  # server's alphabetical order is the OPPOSITE of severity order: `aaa-healthy`
  # sorts first alphabetically and last by severity, so a page that merely looks
  # loaded cannot be mistaken for a page that sorted.
  CATALOG = {
    "aaa-healthy" => {
      "title" => "AAA Healthy", "description" => "Needs no credential.",
      "type" => "stdio", "command" => "npx", "args" => [ "-y", "healthy@latest" ]
    },
    "zzz-broken" => {
      "title" => "ZZZ Broken", "description" => "Wants a variable nobody set.",
      "type" => "stdio", "command" => "npx", "args" => [ "-y", "broken@latest" ],
      "env" => { "BROKEN_API_KEY" => "${CONNECTORS_SYSTEM_TEST_ABSENT_KEY}" }
    }
  }.merge(
    30.times.to_h do |i|
      [ format("filler-%02d", i), {
        "title" => format("Filler %02d", i), "description" => "Padding, so the list runs well past the fold.",
        "type" => "stdio", "command" => "npx", "args" => [ "-y", "filler@latest" ]
      } ]
    end
  ).freeze

  setup do
    AirCatalogService.stubs(:entries_for).returns({})
    AirCatalogService.stubs(:entries_for).with(:mcp).returns(CATALOG)
    McpOauthCredential.delete_all
  end

  test "every badge resolves without scrolling, and problems sort above healthy rows" do
    visit connectors_url

    # Deliberately no assertion on the "Checking…" placeholder here: against an
    # in-process server these rows resolve faster than Capybara can look, so
    # asserting a transient state would be a race, not a check. The integration
    # test covers the placeholder markup; what only a browser can answer is
    # whether the frames get there without a scroll, which is the rest of this.

    # The controller announces the sort by stamping the list, which it only does
    # once every frame has settled. Waiting on that rather than on a fixed delay
    # keeps this honest on a slow CI box.
    assert_selector "[data-connector-list-sorted]", wait: 30

    # Nothing above ever scrolled. If the frames still needed the viewport, the
    # rows below the fold would be sitting on "Checking…" right now.
    assert_equal 0, page.evaluate_script("window.scrollY"),
      "the test never scrolled; a badge that needed a scroll would prove the frames are still gated on it"
    assert_no_selector "[data-connector-state=checking]"
    assert_selector "[data-connector-rank]", count: CATALOG.size

    ranks = page.evaluate_script(
      "Array.from(document.querySelectorAll('[data-connector-rank]'))" \
      ".map(el => Number(el.getAttribute('data-connector-rank')))"
    )
    assert_equal ranks.sort, ranks, "rows must be ordered most-urgent first"

    # The specific inversion: the broken server is alphabetically last and now
    # leads the list; the healthy one is alphabetically first and does not.
    assert_equal "zzz-broken", page.evaluate_script(
      "document.querySelector('[data-connector-rank]').getAttribute('data-connector')"
    )

    assert_selector "[data-attention-count='1']", text: "1 needs attention, listed first"
  end
end
