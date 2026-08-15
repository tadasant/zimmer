require "test_helper"

# The dashboard's Filters section: the status multi-select, its default, "none
# selected means show all", persistence across requests, and the reset control.
#
# Statuses are asserted through the rendered cards rather than an assigns() peek,
# because what the filter is for is which cards a person sees.
class SessionsControllerFiltersTest < ActionDispatch::IntegrationTest
  setup do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    @waiting = make_session(:waiting)
    @running = make_session(:running)
    @needs_input = make_session(:needs_input)
    @failed = make_session(:failed)
    @archived = make_session(:archived)
  end

  test "the dashboard shows only needs_input sessions before anything is filtered" do
    get root_url

    assert_response :success
    assert_cards [ @needs_input ]
  end

  test "selecting several statuses shows exactly those" do
    get root_url(filters: "1", status: %w[running failed])

    assert_response :success
    assert_cards [ @running, @failed ]
  end

  test "submitting the Filters form with no status ticked shows every status" do
    get root_url(filters: "1")

    assert_response :success
    assert_cards [ @waiting, @running, @needs_input, @failed, @archived ]
  end

  test "a selection survives a plain reload of the bare dashboard" do
    get root_url(filters: "1", status: %w[running])
    assert_response :success
    assert_cards [ @running ]

    # No params at all — the persisted choice, not the default, is what applies.
    get root_url
    assert_response :success
    assert_cards [ @running ]
  end

  test "an explicit show-everything selection also persists" do
    get root_url(filters: "1")
    assert_response :success

    get root_url
    assert_response :success
    assert_cards [ @waiting, @running, @needs_input, @failed, @archived ]
  end

  test "reset filters clears the persisted selection and returns to the default" do
    get root_url(filters: "1", status: %w[archived])
    assert_response :success
    assert_cards [ @archived ]

    get root_url(reset_filters: "1")
    assert_redirected_to root_path

    follow_redirect!
    assert_response :success
    assert_cards [ @needs_input ]
  end

  test "the scheduling class choice persists alongside the statuses" do
    get root_url(filters: "1", status: %w[running], priority_class: SessionGenesis::SPOT)
    assert_response :success

    get root_url
    assert_response :success
    assert_select "input#priority-class-filter-spot[checked]", count: 1
  end

  test "an unknown status in the query string is dropped rather than matching nothing" do
    # "waiting" survives; "chartreuse" is not a status and is discarded. A hand-edited
    # URL must not silently empty the dashboard, and must not raise.
    get root_url(filters: "1", status: %w[waiting chartreuse])

    assert_response :success
    assert_cards [ @waiting ]
  end

  test "a corrupt filters cookie is ignored rather than 500ing the dashboard" do
    cookies[SessionsController::FILTERS_COOKIE] = "not json at all"

    get root_url

    assert_response :success
    assert_cards [ @needs_input ]
  end

  test "an unfiltered search spans every status" do
    # The default would hide the trashed or running session the search is for, so an
    # un-narrowed search widens instead.
    get root_url(q: "Filterable")

    assert_response :success
    assert_cards [ @waiting, @running, @needs_input, @failed, @archived ]
  end

  test "a persisted selection still applies while searching" do
    get root_url(filters: "1", status: %w[archived])
    assert_response :success

    get root_url(q: "Filterable")
    assert_response :success
    assert_cards [ @archived ]
  end

  private

  def make_session(status)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Filterable #{status}",
      title: "Filterable #{status}",
      status: status
    )
  end

  # Asserts the rendered dashboard holds a card for each expected session and for no
  # other session in the fixture set.
  def assert_cards(expected)
    all = [ @waiting, @running, @needs_input, @failed, @archived ]
    all.each do |session|
      frame = "turbo-frame##{ActionView::RecordIdentifier.dom_id(session)}"
      if expected.include?(session)
        assert_select frame, { count: 1 }, "expected a card for the #{session.status} session"
      else
        assert_select frame, { count: 0 }, "did not expect a card for the #{session.status} session"
      end
    end
  end
end
