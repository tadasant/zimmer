# frozen_string_literal: true

require "test_helper"

# The web UI's one-off memory boost control (SessionMemoryBoost). The rules are
# Sessions::UpdateMemoryBoost's and are tested there; this pins the door and the page.
class SessionsControllerMemoryBoostTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:needs_input)
  end

  test "the session page offers a boost when none is held" do
    get session_url(@session)

    assert_response :success
    assert_select "#session-memory-boost" do
      assert_select "input[name=memory_mb]"
      assert_select "input[name=hours][value='#{SessionMemoryBoost::DEFAULT_HOURS}']"
    end
  end

  test "granting a boost stores it and the page then describes it with an End control" do
    patch memory_boost_session_url(@session), params: { memory_mb: 6144, hours: 3 }

    assert_redirected_to session_path(@session)
    assert_equal 6144, @session.reload.memory_boost_mb
    assert_in_delta 3.hours.from_now, @session.memory_boost_expires_at, 5

    get session_url(@session)
    assert_select "#session-memory-boost [data-testid=memory-boost-description]", text: /6 GB requested/
    assert_select "#session-memory-boost form[action='#{memory_boost_session_path(@session)}'] input[name=_method][value=delete]"
  end

  test "a refused boost comes back as an alert and stores nothing" do
    patch memory_boost_session_url(@session), params: { memory_mb: 1024 }

    assert_nil @session.reload.memory_boost_mb
    assert_match(/memory_mb must be between/, flash[:alert])
  end

  test "ending a boost clears it" do
    @session.update!(memory_boost_mb: 6144, memory_boost_expires_at: 1.hour.from_now)

    delete memory_boost_session_url(@session)

    assert_redirected_to session_path(@session)
    assert_nil @session.reload.memory_boost_mb
  end
end
