# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The session detail page's tail-first transcript: the panel's own response is
# the newest TRANSCRIPT_TAIL_LIMIT items, read backwards from the end of the
# stored transcript, and #timeline_items pages back from it with a timestamp
# cursor plus a transcript-line hint. These tests walk that protocol the way
# infinite_scroll_controller.js does and check that it adds up to the whole
# timeline — no item dropped at a page boundary, none shown twice.
class SessionsControllerTailFirstTest < ActionDispatch::IntegrationTest
  teardown do
    Mocha::Mockery.instance.teardown
  end

  def build_transcript_session(transcript_entries)
    Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "tail-first",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: transcript_entries.map(&:to_json).join("\n") + "\n"
    )
  end

  def transcript_line(index, at, padding: "")
    role = index.even? ? "user" : "assistant"
    { "type" => role, "message" => { "role" => role, "content" => "Message #{index}#{padding}" }, "timestamp" => at.iso8601 }
  end

  def item_texts
    css_select("[data-timeline-item]").map { |row| row.text.squish }
  end

  def pagination_state
    css_select("#timeline-pagination-state").first
  end

  # Fetch the tail, then every earlier page, exactly as the client does.
  # Returns every item text, oldest first, and the number of requests.
  def walk_timeline(session, filter:, limit: 25)
    get transcript_panel_session_url(session, filter: filter)
    assert_response :success
    shown = item_texts
    panel = css_select("[data-controller='infinite-scroll']").first
    has_more = panel["data-infinite-scroll-has-more-value"] == "true"
    cursor = panel["data-infinite-scroll-before-timestamp-value"]
    line = panel["data-infinite-scroll-before-line-value"]
    requests = 1

    while has_more
      get timeline_items_session_url(session, filter: filter, limit: limit, before_timestamp: cursor, before_line: line)
      assert_response :success
      shown = item_texts + shown
      state = pagination_state
      has_more = state["data-has-more"] == "true"
      cursor = state["data-next-before-timestamp"]
      line = state["data-next-before-line"]
      requests += 1
      flunk "paging did not terminate" if requests > 100
    end

    [ shown, requests ]
  end

  test "the tail and the pages before it add up to the whole timeline, in order" do
    base = 3.hours.ago.change(usec: 0)
    session = build_transcript_session(Array.new(150) { |i| transcript_line(i, base + i.minutes) })

    shown, requests = walk_timeline(session, filter: "minimal")

    assert_equal 150, shown.size
    assert_equal (0...150).map { |i| "Message #{i}" }, shown.map { |text| text[/Message \d+/] }
    # One tail of 10, then 140 more at 25 a page.
    assert_equal 1 + (140 / 25.0).ceil, requests
  end

  # A log and a transcript line stamped the same second is ordinary, and the next
  # page asks for items strictly older than this page's oldest — so a page that
  # split a tie would lose the other half of it forever.
  test "items sharing a timestamp are never split across a page boundary" do
    base = 3.hours.ago.change(usec: 0)
    session = build_transcript_session(Array.new(60) { |i| transcript_line(i, base + (i / 3).minutes) })
    20.times { |i| session.logs.create!(level: "info", content: "Log #{i}", created_at: base + i.minutes) }

    shown, = walk_timeline(session, filter: "show-logs", limit: 7)

    assert_equal 80, shown.size
    assert_equal shown.uniq.size, shown.size
    assert_equal 60, shown.grep(/Message \d+/).size
    assert_equal 20, shown.grep(/Log \d+/).size
  end

  test "through_index reads back to a deep-linked message in one request" do
    base = 3.hours.ago.change(usec: 0)
    session = build_transcript_session(Array.new(150) { |i| transcript_line(i, base + i.minutes) })

    get transcript_panel_session_url(session)
    panel = css_select("[data-controller='infinite-scroll']").first
    assert_select "#message-5", 0

    get timeline_items_session_url(session, filter: "minimal",
                                            before_timestamp: panel["data-infinite-scroll-before-timestamp-value"],
                                            before_line: panel["data-infinite-scroll-before-line-value"],
                                            through_index: 5)

    assert_response :success
    assert_select "#message-5", 1
    # Everything between the anchor and the tail, so nothing is left as a gap.
    assert_equal (5...140).map { |i| "Message #{i}" }, item_texts.map { |text| text[/Message \d+/] }
    assert_equal "true", pagination_state["data-has-more"]
  end

  # The point of reading backwards: a long transcript is stored as many chunks,
  # and the tail should cost the last of them, not the document.
  test "the tail reads only the newest chunks of a long transcript" do
    base = 3.hours.ago.change(usec: 0)
    padding = " #{'x' * 4_000}"
    session = build_transcript_session(Array.new(300) { |i| transcript_line(i, base + i.minutes, padding: padding) })
    chunk_count = SessionTranscriptChunk.where(session_id: session.id).count
    assert_operator chunk_count, :>, 3

    content_reads = 0
    counter = ->(*, payload) { content_reads += 1 if payload[:sql].include?("session_transcript_chunks") && payload[:sql].include?("content") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      get transcript_panel_session_url(session)
    end

    assert_response :success
    assert_select "[data-timeline-item]", SessionsController::TRANSCRIPT_TAIL_LIMIT
    assert_operator content_reads, :<=, 2, "the tail read #{content_reads} of #{chunk_count} chunks"
  end

  test "a transcript with nothing older states its own size as the total" do
    session = build_transcript_session(Array.new(4) { |i| transcript_line(i, 1.hour.ago + i.minutes) })

    get transcript_panel_session_url(session)

    assert_response :success
    assert_select "[data-infinite-scroll-has-more-value='false']"
    assert_select "[data-infinite-scroll-total-count-value='4']"
    assert_match(/4 items/, response.body)
  end

  # The detail page itself: every disclosure collapsed, and both deferred frames
  # eager, so their contents are fetched right after first paint rather than on
  # the click that opens them.
  test "the detail page renders its disclosures closed and prefetches their frames" do
    session = build_transcript_session(Array.new(4) { |i| transcript_line(i, 1.hour.ago + i.minutes) })

    get session_url(session)

    assert_response :success
    assert_select "details[data-controller='transcript-panel']:not([open])", 1
    assert_select "turbo-frame#session_#{session.id}_transcript[src]:not([loading='lazy'])", 1
    assert_select "turbo-frame#session_#{session.id}_provenance_panel[src]:not([loading='lazy'])", 1
    assert_select "turbo-frame#session_#{session.id}_transcript[data-backfill-src*='limit=#{SessionsController::TIMELINE_PAGE_LIMIT}']", 1
  end

  # The Status panel asks on every render whether Regenerate could run, and the
  # page asks whether the session never ran. Neither may materialize the whole
  # transcript to find out.
  test "the detail page does not load the whole transcript" do
    session = build_transcript_session(Array.new(4) { |i| transcript_line(i, 1.hour.ago + i.minutes) })
    Session.any_instance.stubs(:transcript).raises("the detail page loaded the whole transcript")

    get session_url(session)

    assert_response :success
  end
end
