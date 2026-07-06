require "test_helper"
require "mocha/minitest"

# Tests for the dashboard view modes on SessionsController#index. Besides the
# default category-grouped grid, the dashboard supports two flat sort modes
# selected via ?view=:
#   - last_touched  → single list ordered by last_user_activity_at (metadata,
#                     falling back to created_at), most-recent first
#   - created_desc  → single list ordered purely by created_at desc
# Both flatten the presentation: no category grouping, no custom/per-category
# ordering, and no pinned favorites float. Desktop defaults to categories,
# mobile defaults to last_touched, and an explicit choice persists via cookie.
class SessionsControllerViewModesTest < ActionDispatch::IntegrationTest
  DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze
  MOBILE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1".freeze

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
    Category.delete_all
    AppSetting.delete_all
  end

  def make_session(favorited: false, category: nil, prompt: "p")
    Session.create!(
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: prompt,
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      favorited: favorited,
      category: category
    )
  end

  # Card dom ids in document order within the flat list.
  def flat_card_ids
    css_select("#flat_sessions [id^='session_']").map { |el| el["id"] }
  end

  # ---- Defaults --------------------------------------------------------------

  test "desktop default is the category-grouped view" do
    make_session

    get root_path, headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_select "#category_sections", true, "desktop default should render the category grid"
    assert_select "#flat_sessions", false, "desktop default should not render the flat list"
  end

  test "mobile default is the last touched flat view" do
    make_session

    get root_path, headers: { "User-Agent" => MOBILE_UA }

    assert_response :success
    assert_select "#flat_sessions", true, "mobile default should render the flat list"
    assert_select "#category_sections", false, "mobile default should not render the category grid"
    assert_select "#pinned_section", false, "flat view should not float pinned favorites"
  end

  # ---- Explicit selection + persistence -------------------------------------

  test "explicit view param overrides the desktop default" do
    make_session

    get root_path(view: "last_touched"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_select "#flat_sessions", true
    assert_select "#category_sections", false
  end

  test "explicit view choice persists via cookie across navigation" do
    make_session

    # First, explicitly pick the flat view (sets the cookie).
    get root_path(view: "last_touched"), headers: { "User-Agent" => DESKTOP_UA }
    assert_select "#flat_sessions", true

    # A subsequent visit with no param (still desktop) keeps the flat view.
    get root_path, headers: { "User-Agent" => DESKTOP_UA }
    assert_response :success
    assert_select "#flat_sessions", true, "the persisted explicit choice should survive navigation"
    assert_select "#category_sections", false
  end

  test "an invalid view param falls back to the default" do
    make_session

    get root_path(view: "bogus"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_select "#category_sections", true, "invalid view should fall back to desktop default"
    assert_select "#flat_sessions", false
  end

  # ---- last_touched ordering -------------------------------------------------

  test "last touched view orders by last_user_activity_at, viewed beats newer-created" do
    # older_created was created first but was just "touched" (viewed);
    # newer_created was created later but never touched.
    older_created = make_session
    older_created.update_column(:created_at, 3.hours.ago)
    newer_created = make_session
    newer_created.update_column(:created_at, 1.hour.ago)

    # Record a recent human view on the older session.
    older_created.touch_user_view!

    get root_path(view: "last_touched"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    # The just-viewed (older-created) session jumps to the top; the never-touched
    # newer session falls back to its created_at and sorts below it.
    assert_equal [ "session_#{older_created.id}", "session_#{newer_created.id}" ], flat_card_ids
  end

  test "last touched view falls back to created_at for never-touched sessions" do
    older = make_session
    older.update_column(:created_at, 2.hours.ago)
    newer = make_session
    newer.update_column(:created_at, 5.minutes.ago)

    get root_path(view: "last_touched"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_equal [ "session_#{newer.id}", "session_#{older.id}" ], flat_card_ids
  end

  test "last touched view does not float favorited sessions" do
    favorited_old = make_session(favorited: true)
    favorited_old.update_column(:created_at, 4.hours.ago)
    plain_new = make_session(favorited: false)
    plain_new.update_column(:created_at, 1.minute.ago)

    get root_path(view: "last_touched"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    # Strict last-touched order ignores the favorite flag: the newer plain
    # session sorts above the older favorited one.
    assert_equal [ "session_#{plain_new.id}", "session_#{favorited_old.id}" ], flat_card_ids
    assert_select "#pinned_section", false
  end

  # ---- created_desc ordering -------------------------------------------------

  test "created desc view orders strictly by created_at descending" do
    a = make_session
    a.update_column(:created_at, 3.hours.ago)
    b = make_session
    b.update_column(:created_at, 2.hours.ago)
    c = make_session
    c.update_column(:created_at, 1.hour.ago)

    # Touch the oldest — created_desc must ignore activity entirely.
    a.touch_user_view!

    get root_path(view: "created_desc"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_equal [ "session_#{c.id}", "session_#{b.id}", "session_#{a.id}" ], flat_card_ids
    assert_select "#category_sections", false
    assert_select "#pinned_section", false
  end

  test "last touched view degrades to created_at on a malformed stored timestamp" do
    # A non-empty but unparseable last_user_activity_at must not 500 the
    # dashboard — the SQL ordering should fall back to created_at, mirroring
    # Session#last_user_activity_at. (We always write ISO8601, so this is a
    # latent-corruption guard, not a live path.)
    garbage = make_session
    garbage.update_column(:created_at, 3.hours.ago)
    garbage.update_column(:metadata, (garbage.metadata || {}).merge("last_user_activity_at" => "not-a-timestamp"))
    newer = make_session
    newer.update_column(:created_at, 1.minute.ago)

    get root_path(view: "last_touched"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success, "a malformed stored timestamp must not raise"
    # garbage falls back to its created_at (older), so newer sorts above it.
    assert_equal [ "session_#{newer.id}", "session_#{garbage.id}" ], flat_card_ids
  end

  test "flat views still honor the trash visibility filter" do
    visible = make_session
    archived = make_session
    archived.update_column(:status, Session.statuses[:archived])

    get root_path(view: "created_desc"), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    ids = flat_card_ids
    assert_includes ids, "session_#{visible.id}"
    assert_not_includes ids, "session_#{archived.id}", "archived sessions hidden by default"
  end

  # ---- show records a human view as last touched -----------------------------

  test "viewing a session page bumps last_user_activity_at" do
    session = make_session
    session.update_column(:metadata, (session.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601))
    before = session.reload.last_user_activity_at

    get session_path(session), headers: { "User-Agent" => DESKTOP_UA }

    assert_response :success
    assert_operator session.reload.last_user_activity_at, :>, before,
      "opening the session page is a human view and should bump last touched"
  end

  test "a prefetch request does not bump last_user_activity_at" do
    session = make_session
    session.update_column(:metadata, (session.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601))
    before = session.reload.last_user_activity_at

    # Turbo hover-prefetch carries this header; it is not a genuine human view.
    get session_path(session), headers: { "User-Agent" => DESKTOP_UA, "X-Sec-Purpose" => "prefetch" }

    assert_response :success
    assert_equal before.to_i, session.reload.last_user_activity_at.to_i,
      "a prefetch must not count as a human view"
  end

  test "a native browser prefetch (Sec-Purpose header) does not bump last_user_activity_at" do
    session = make_session
    session.update_column(:metadata, (session.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601))
    before = session.reload.last_user_activity_at

    # Native <link rel=prefetch> / speculation-rules prefetch send the standard
    # Sec-Purpose header (Turbo Drive uses the X- prefixed variant); neither is a
    # genuine human view.
    get session_path(session), headers: { "User-Agent" => DESKTOP_UA, "Sec-Purpose" => "prefetch;prerender" }

    assert_response :success
    assert_equal before.to_i, session.reload.last_user_activity_at.to_i,
      "a native browser prefetch must not count as a human view"
  end
end
