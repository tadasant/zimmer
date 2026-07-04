require "application_system_test_case"

class GithubPrTrackingTest < ApplicationSystemTestCase
  include ActionCable::TestHelper

  setup do
    @session = sessions(:running)
    @session.update!(custom_metadata: {})
  end

  test "PR URL appears in session card when custom_metadata is updated" do
    @session.update!(git_root: "https://github.com/owner/repo.git")
    visit root_path

    # Initially no PR link visible
    within "turbo-frame#session_#{@session.id}" do
      assert_no_selector "a[href*='github.com']"
    end

    # Simulate PR URL being extracted via transcript hook
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Wait for turbo stream update
    assert_selector "turbo-frame#session_#{@session.id} a[href='https://github.com/owner/repo/pull/123']", wait: 5
  end

  test "PR icon shows gray color for unknown status" do
    @session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    visit root_path

    within "turbo-frame#session_#{@session.id}" do
      # Gray color for unknown status (color is on the SVG icon)
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-gray-400"
    end
  end

  test "PR icon shows green color for open status" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" }
    })

    visit root_path

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-green-600"
    end
  end

  test "PR icon shows purple color for merged status" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "merged" }
    })

    visit root_path

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-purple-600"
    end
  end

  test "PR icon shows red color for closed status" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "closed" }
    })

    visit root_path

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-red-600"
    end
  end

  test "PR status change from open to merged updates UI via turbo stream" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" }
    })

    visit root_path

    # Verify initial green (open) status (color is on the SVG icon)
    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-green-600"
    end

    # Simulate PR being merged (as would happen from poller job)
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "merged" }
    })

    # Wait for turbo stream to update the PR icon to purple (color is on the SVG)
    within "turbo-frame#session_#{@session.id}" do
      assert_selector "a[href='https://github.com/owner/repo/pull/123'] svg.text-purple-600", wait: 5
    end
  end

  test "PR link persists on page refresh" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "merged" }
    })

    visit root_path

    # Verify PR link is present
    within "turbo-frame#session_#{@session.id}" do
      assert_selector "a[href='https://github.com/owner/repo/pull/456']"
    end

    # Refresh the page
    visit root_path

    # Verify PR link is still present after refresh
    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/456']")
      assert_equal "View PR on GitHub", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-purple-600"
    end
  end

  test "PR link is also shown on session show page" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/789" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/789" => "open" }
    })

    visit session_path(@session)

    # PR link should appear on the show page too
    pr_link = find("a[href='https://github.com/owner/repo/pull/789']")
    assert_equal "View PR on GitHub", pr_link[:title]
    pr_icon = pr_link.find("svg")
    assert_includes pr_icon[:class], "text-green-600"
  end

  test "PR link appears in footer for archived session with PR URL" do
    @session.update!(
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
        "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "merged" }
      }
    )
    @session.archive!

    # Need to visit with show_archived=true to see archived sessions
    visit root_path(show_archived: true)

    within "turbo-frame#session_#{@session.id}" do
      # Footer should be visible with border
      assert_selector "div.border-t"
      # PR link should be visible
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-purple-600"
      # Archive button should NOT be visible for archived sessions
      assert_no_button "Archive"
    end
  end

  test "clicking the PR button resets the GitHub poll backoff to the fast cadence" do
    # Make the session look stale: last user activity > 24h ago puts PollBackoff
    # on its slowest (24h) cadence, the "stuck" state the user complains about.
    @session.update!(
      metadata: (@session.metadata || {}).merge("last_user_activity_at" => 25.hours.ago.iso8601),
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/321" ],
        "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/321" => "open" }
      }
    )

    # Sanity: before the click the session is on the slow cadence.
    assert_equal 24.hours.to_i, PollBackoff.poll_interval(@session, base_interval: 30)

    visit root_path

    pr_link = nil
    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/321']")
      # Link still opens GitHub in a new tab.
      assert_equal "_blank", pr_link[:target]
      pr_link.click
    end

    # The click fires a non-blocking POST to touch_activity; wait for the DB to
    # reflect the reset rather than asserting immediately. Poll generously — the
    # request races against the browser opening a new tab, and a loaded CI runner
    # can delay the round-trip by a second or two.
    activity_reset = false
    30.times do
      @session.reload
      if PollBackoff.poll_interval(@session, base_interval: 30) == 0
        activity_reset = true
        break
      end
      sleep 0.3
    end

    assert activity_reset, "expected clicking the PR link to reset PollBackoff to the fast cadence"
    assert_operator @session.last_user_activity_at, :>, 1.minute.ago
    assert PollBackoff.should_poll?(@session, job_key: "pr_status", base_interval: 30)
  end

  test "full flow: session without PR gets PR URL extracted from tool result" do
    # Start with a session with no PR metadata
    assert_nil @session.custom_metadata["github_pull_request_urls"]

    visit root_path
    wait_for_turbo_streams_connected

    # No PR link initially
    within "turbo-frame#session_#{@session.id}" do
      assert_no_selector "a[href*='github.com']"
    end

    # Simulate what happens when TranscriptPollerService runs hooks:
    # 1. A tool result with PR URL appears in transcript
    # 2. GithubPrUrlHook extracts it and updates custom_metadata
    # Note: PR URL must match the session's git_root (test/repo) for the hook to extract it
    transcript_content = <<~JSONL
      {"type":"user","message":{"content":[{"tool_use_id":"toolu_123","type":"tool_result","content":"https://github.com/test/repo/pull/999","is_error":false}]}}
    JSONL

    hook = TranscriptHooks::GithubPrUrlHook.new(
      session: @session,
      transcript_content: transcript_content,
      new_messages: []
    )
    hook.call

    # Verify PR URL was extracted
    @session.reload
    assert_equal [ "https://github.com/test/repo/pull/999" ], @session.custom_metadata["github_pull_request_urls"]

    # Wait for turbo stream to show the PR link
    assert_selector "turbo-frame#session_#{@session.id} a[href='https://github.com/test/repo/pull/999']", wait: 5

    # Initially gray (no status yet) - color is on the SVG icon
    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/test/repo/pull/999']")
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-gray-400"
    end

    # Simulate poller job updating status to "open"
    @session.update!(custom_metadata: @session.custom_metadata.merge(
      "github_pull_request_statuses" => { "https://github.com/test/repo/pull/999" => "open" }
    ))

    # Wait for turbo stream to update to green (color is on the SVG)
    within "turbo-frame#session_#{@session.id}" do
      assert_selector "a[href='https://github.com/test/repo/pull/999'] svg.text-green-600", wait: 5
    end

    # Simulate poller job updating status to "merged"
    @session.update!(custom_metadata: @session.custom_metadata.merge(
      "github_pull_request_statuses" => { "https://github.com/test/repo/pull/999" => "merged" }
    ))

    # Wait for turbo stream to update to purple (color is on the SVG)
    within "turbo-frame#session_#{@session.id}" do
      assert_selector "a[href='https://github.com/test/repo/pull/999'] svg.text-purple-600", wait: 5
    end

    # Verify persists after refresh
    visit root_path

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/test/repo/pull/999']")
      assert_equal "View PR on GitHub", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-purple-600"
    end
  end
end
