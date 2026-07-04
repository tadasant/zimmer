require "test_helper"

module Supervisor
  class SessionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @session = sessions(:running)
    end

    test "should get index" do
      get supervisor_sessions_url
      assert_response :success
      assert_select "h1", "Sessions"
    end

    test "should show session" do
      get supervisor_session_url(@session)
      assert_response :success
    end

    test "should get new" do
      get new_supervisor_session_url
      assert_response :success
    end

    test "should get edit" do
      get edit_supervisor_session_url(@session)
      assert_response :success
    end

    test "should update session" do
      patch supervisor_session_url(@session), params: {
        session: {
          prompt: "Updated prompt",
          git_root: @session.git_root,
          branch: @session.branch
        }
      }
      assert_redirected_to supervisor_session_url(@session)
    end

    test "should destroy session" do
      assert_difference("Session.count", -1) do
        delete supervisor_session_url(@session)
      end
      assert_redirected_to supervisor_sessions_url
    end
  end
end
