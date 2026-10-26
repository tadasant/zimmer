require "test_helper"
require "mocha/minitest"

# The dashboard is two requests: "/" (SessionsController#index) is the shell and
# "/board" (#board) is the session list the shell's <turbo-frame
# id="sessions_board"> loads. The split is what lets the shell paint before a
# single row has rendered, so these tests pin both halves of it: the shell makes
# no board, and the board is a frame that behaves as the inline board did.
class SessionsControllerBoardTest < ActionDispatch::IntegrationTest
  DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
    AppSetting.delete_all
  end

  def make_session(title: "A session", **attrs)
    Session.create!(
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      title: title,
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      **attrs
    )
  end

  test "the shell renders the board frame with a skeleton and no rows" do
    session = make_session

    get root_path(view: "user"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_select "turbo-frame#sessions_board[target=_top][data-deferred-panel]" do
      assert_select "[data-board-skeleton]"
    end
    assert_select "#user_view_list", false, "the shell must not render the board itself"
    assert_select "#user_view_row_#{session.id}", false
    # The Filters, the view switcher and the off-board slot are the shell's.
    assert_select "form[action='/'] input[name=q]"
    assert_select "[aria-label='Dashboard view mode']"
    assert_select "#off-board-count", text: ""
  end

  test "the shell runs no session queries" do
    make_session

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/FROM "sessions"/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get root_path(view: "user"), headers: { "User-Agent" => DESKTOP_UA }
    end

    assert_response :success
    assert_empty queries, "the shell must stay free of session queries; those belong to #board"
  end

  test "the frame's src carries the shell's query string to the board" do
    get root_path(view: "last_touched", q: "needle", filters: "1", status: %w[failed])

    frame = css_select("turbo-frame#sessions_board").first
    uri = URI.parse(frame["src"])
    assert_equal "/board", uri.path
    query = Rack::Utils.parse_nested_query(uri.query)
    assert_equal "last_touched", query["view"]
    assert_equal "needle", query["q"]
    assert_equal "1", query["filters"]
    assert_equal %w[failed], query["status"]
  end

  test "the board is the frame alone, without the layout" do
    session = make_session

    get dashboard_board_path(view: "user"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    refute_includes response.body, "<html", "the board renders without the application layout"
    assert_select "turbo-frame#sessions_board[target=_top]" do
      assert_select "#user_view_row_#{session.id}"
    end
  end

  test "the board's page links lead back to the dashboard, not to the bare board" do
    (SessionsController::SESSIONS_PER_PAGE + 1).times { |i| make_session(title: "S#{i}") }

    get dashboard_board_path(view: "created_desc")

    assert_response :success
    hrefs = css_select("#flat_sessions nav a").map { |a| a["href"] }
    assert hrefs.any?, "expected a paginator"
    hrefs.each do |href|
      assert_equal "/", URI.parse(href).path, "page link #{href} should point at the dashboard"
    end
  end

  test "the board clears the off-board count when nothing is tucked away" do
    make_session

    get dashboard_board_path

    assert_select "turbo-stream[action=update][target=off-board-count] template", text: ""
  end
end
