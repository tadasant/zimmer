require "application_system_test_case"

class TurboStreamsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  # Test that Turbo Stream infrastructure is properly set up
  test "sessions index has turbo stream subscription" do
    visit root_path

    # Verify the page subscribes to the sessions_index stream
    # This is indicated by the turbo-cable-stream-source element
    assert_selector "turbo-cable-stream-source[channel='Turbo::StreamsChannel'][signed-stream-name]", visible: :all
  end

  test "session cards are wrapped in turbo frames" do
    visit root_path

    # Verify all session cards are wrapped in turbo frames
    all("[id^='session_']").each do |session_element|
      session_id = session_element[:id]
      # Each session should be in a turbo-frame
      assert_selector "turbo-frame##{session_id}", visible: :all
    end
  end

  test "sessions grid container has correct ID for broadcasts" do
    visit root_path

    # Verify the grid has the ID that broadcasts target
    assert_selector "#sessions_grid"
  end

  test "timestamp has data attributes for JavaScript updater" do
    visit root_path

    # Verify timestamps have the required data attributes
    # At least one timestamp should exist on the page
    assert_selector "[data-controller='timestamp-updater']", minimum: 1

    # Verify it has the timestamp data attribute
    assert_selector "[data-timestamp]", minimum: 1
  end

  test "session card shows correct status badge styling" do
    running_session = sessions(:running)
    waiting_session = sessions(:waiting)

    visit root_path

    # Running session should have green badge
    within "turbo-frame#session_#{running_session.id}" do
      assert_selector ".bg-green-100.text-green-800", text: "Running"
      # Should also have spinning icon
      assert_selector ".animate-spin"
    end

    # Waiting session should have purple badge (changed from yellow to avoid clash with running badge's time-based yellow)
    within "turbo-frame#session_#{waiting_session.id}" do
      assert_selector ".bg-purple-100.text-purple-800", text: "Waiting"
    end
  end

  test "timestamp shows correct relative time format" do
    # Test various time ranges
    recent_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Recent",
      status: :running,
      agent_runtime: "claude_code",
      branch: "main",
      created_at: 30.seconds.ago
    )

    minutes_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Minutes",
      status: :running,
      agent_runtime: "claude_code",
      branch: "main",
      created_at: 5.minutes.ago
    )

    hours_session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Hours",
      status: :running,
      agent_runtime: "claude_code",
      branch: "main",
      created_at: 3.hours.ago
    )

    visit root_path

    # Check each timestamp format
    within "turbo-frame#session_#{recent_session.id}" do
      assert_text "less than a minute ago", wait: 2
    end

    within "turbo-frame#session_#{minutes_session.id}" do
      assert_text "5 minutes ago", wait: 2
    end

    within "turbo-frame#session_#{hours_session.id}" do
      assert_text "3 hours ago", wait: 2
    end
  end

  test "broadcast callbacks are defined on Session model" do
    # Verify the Session model has the broadcast methods defined
    assert Session.private_instance_methods.include?(:broadcast_update_to_sessions_index)
    assert Session.private_instance_methods.include?(:broadcast_create_to_sessions_index)
    assert Session.private_instance_methods.include?(:broadcast_remove_from_sessions_index)
  end
end
