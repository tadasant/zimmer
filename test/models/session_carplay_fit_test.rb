# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The CarPlay-fit axis on a session: the values it takes, the staleness rule
# that is counted in transcript lines, and the one filter vocabulary every
# listing shares. The property that matters most is that the scope and the
# row-level predicate answer identically — a board filters with one and draws
# chips with the other.
class SessionCarplayFitTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: lines(10)
    }.merge(attrs))
  end

  def marked(fit, line_count: 10, **attrs)
    make_session(carplay_fit: fit, carplay_fit_source: "auto", carplay_fit_line_count: line_count,
                 carplay_fit_set_at: Time.current, **attrs)
  end

  # `transcript_line_count` is derived from the transcript, so a session that is
  # "at line N" needs N lines of one.
  def lines(n)
    n.times.map { |i| JSON.generate({ "type" => "user", "message" => { "role" => "user", "content" => "m#{i}" } }) }.join("\n") + "\n"
  end

  test "values off the lists are refused, and nil is allowed everywhere" do
    assert make_session.valid?
    assert_not make_session.tap { |s| s.carplay_fit = "driveable" }.valid?
    assert_not make_session.tap { |s| s.carplay_fit_reason = "vibes" }.valid?
    assert_not make_session.tap { |s| s.carplay_fit_source = "robot" }.valid?
  end

  test "a mark is current while the session has not written past it, stale once it has" do
    session = marked(SessionCarplayFit::CARPLAY_OK, line_count: 10)
    assert session.carplay_fit_current?
    assert_equal SessionCarplayFit::CARPLAY_OK, session.effective_carplay_fit
    assert_equal 0, session.carplay_fit_messages_since

    session.update!(transcript: lines(14))
    assert_not session.carplay_fit_current?
    assert_nil session.effective_carplay_fit
    assert_equal 4, session.carplay_fit_messages_since
  end

  test "the scopes and the predicate agree on every bucket" do
    ok = marked(SessionCarplayFit::CARPLAY_OK)
    laptop = marked(SessionCarplayFit::LAPTOP_ONLY)
    stale_laptop = marked(SessionCarplayFit::LAPTOP_ONLY, line_count: 3)
    untagged = make_session
    ids = [ ok, laptop, stale_laptop, untagged ].map(&:id)
    scope = Session.where(id: ids)

    assert_equal [ ok.id ], scope.carplay_fit_filter("carplay_ok").pluck(:id)
    assert_equal [ laptop.id ], scope.carplay_fit_filter("laptop_only").pluck(:id)
    assert_equal [ stale_laptop.id, untagged.id ].sort, scope.carplay_fit_filter("untagged").pluck(:id).sort
    assert_equal [ ok.id, stale_laptop.id, untagged.id ].sort, scope.carplay_fit_filter("not_laptop_only").pluck(:id).sort
    assert_equal ids.sort, scope.carplay_fit_filter("").pluck(:id).sort, "an unknown option narrows nothing"

    scope.find_each do |session|
      assert_equal session.carplay_fit_current?, scope.carplay_fit_current.exists?(session.id),
        "scope and predicate disagree on session #{session.id}"
    end
  end

  test "the summary names the mark, the reason, the source and the freshness" do
    session = marked(SessionCarplayFit::LAPTOP_ONLY, carplay_fit_reason: "credential")
    assert_equal "Laptop only (a credential) · auto · current", session.carplay_fit_summary

    session.update!(transcript: lines(12))
    assert_equal "Laptop only (a credential) · auto · stale, 2 message(s) since", session.carplay_fit_summary

    assert_nil make_session.carplay_fit_summary
  end
end
