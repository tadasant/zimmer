require "application_system_test_case"
require "mocha/minitest"

# The session form is where a broken catalog actually shows up. Every config
# façade rescues CatalogError to an empty array, so the form renders with an
# empty agent-root list, an empty MCP server list, an empty skill list — exactly
# what a fresh install with nothing configured looks like. This banner is what
# tells the two apart.
class CatalogFailureBannerTest < ApplicationSystemTestCase
  def teardown
    Mocha::Mockery.instance.teardown
    super
  end

  test "a resolve failure with no fallback says the lists are empty and why" do
    AirCatalogService.stubs(:resolve_failure)
      .returns({ message: "air resolve failed (exit 1): cross-scope shortname collision", at: Time.current })
    AirCatalogService.stubs(:degraded?).returns(false)

    visit new_session_path

    assert_text "Catalog resolution failed — the lists below are empty"
    assert_text "no previous catalog is cached to fall back on"
    assert_text "cross-scope shortname collision"
  end

  test "a degraded resolve says the lists are stale rather than empty" do
    AirCatalogService.stubs(:resolve_failure)
      .returns({ message: "air resolve failed (exit 1): boom", at: Time.current })
    AirCatalogService.stubs(:degraded?).returns(true)
    AirCatalogService.stubs(:last_known_good_at).returns(2.hours.ago)

    visit new_session_path

    assert_text "Catalog resolution failed — showing the last catalog that worked"
    assert_text "2 hours ago"
  end

  test "a healthy catalog shows no banner" do
    AirCatalogService.stubs(:resolve_failure).returns(nil)

    visit new_session_path

    assert_text "Create New Session"
    assert_no_text "Catalog resolution failed"
  end
end
