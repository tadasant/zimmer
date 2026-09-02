require "application_system_test_case"

class GithubPrTrackingTest < ApplicationSystemTestCase
  include ActionCable::TestHelper

  setup do
    @session = sessions(:running)
    @session.update!(custom_metadata: {})
  end

  test "PR URL appears in session card when custom_metadata is updated" do
    @session.update!(git_root: "https://github.com/owner/repo.git")
    visit root_path(every_status_params)

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

    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      # Gray color for unknown status (color is on the SVG icon)
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub (Unknown)", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-gray-400"
    end
  end

  test "PR icon shows green color for open status" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" }
    })

    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub (Open)", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-green-600"
    end
  end

  test "PR icon shows purple color for merged status" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "merged" }
    })

    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub (Merged)", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-purple-600"
    end
  end

  test "PR icon shows red color for closed status" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "closed" }
    })

    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/123']")
      assert_equal "View PR on GitHub (Closed)", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-red-600"
    end
  end

  # The button's visible label names the PR and nothing else: state rides on the
  # icon's glyph and colour (asserted above), with the parenthetical in an sr-only
  # span and in the title so it survives for a reader of neither.
  test "the PR button label drops the state parenthetical but keeps it for assistive tech" do
    url = "https://github.com/owner/repo/pull/123"
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ url ],
      "github_pull_request_statuses" => { url => "merged" }
    })

    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='#{url}']")

      # What a sighted user reads: the label with the sr-only text taken back out.
      # Asserted on the DOM rather than on Capybara's #text, which is free to decide
      # either way about a 1px clipped span.
      sighted_label = page.evaluate_script(<<~JS, pr_link)
        (function (el) {
          const clone = el.cloneNode(true);
          clone.querySelectorAll(".sr-only").forEach((n) => n.remove());
          return clone.textContent;
        })(arguments[0])
      JS
      assert_equal "PR", sighted_label.squish

      # What a screen reader reads, and what a hover reveals.
      assert_equal "(Merged)", pr_link.find("span.sr-only", visible: :all).text(:all).strip
      assert_equal "View PR on GitHub (Merged)", pr_link[:title]
    end
  end

  # A session with several PRs renders a second, separate copy of that label in the
  # session header's dropdown primary button, so it gets its own pin. The menu rows
  # below it are the one place the state stays visible text -- there is room in a list.
  test "the multi-PR button label drops the state parenthetical too" do
    first = "https://github.com/owner/repo/pull/122"
    second = "https://github.com/owner/repo/pull/123"
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ first, second ],
      "github_pull_request_statuses" => { first => "merged", second => "open" }
    })

    visit session_path(@session)

    primary = find("a[href='#{second}'].rounded-l-md")

    sighted_label = page.evaluate_script(<<~JS, primary)
      (function (el) {
        const clone = el.cloneNode(true);
        clone.querySelectorAll(".sr-only").forEach((n) => n.remove());
        return clone.textContent;
      })(arguments[0])
    JS
    assert_equal "#123", sighted_label.squish
    assert_equal "(Open)", primary.find("span.sr-only", visible: :all).text(:all).strip
    assert_equal "View most recent PR on GitHub (Open)", primary[:title]
  end

  # The dashboard card cannot seat that button group next to the ⋮ / Trash / View
  # group -- the footer wrapped (#607) -- so several PRs collapse there into one
  # dropdown trigger. Its face is the count, and the newest PR's number and state,
  # which the header spells out in the label, ride in the sr-only span and the title.
  test "the multi-PR card control collapses to a count and keeps the rest for assistive tech" do
    first = "https://github.com/owner/repo/pull/122"
    second = "https://github.com/owner/repo/pull/123"
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ first, second ],
      "github_pull_request_statuses" => { first => "merged", second => "open" },
      "github_pull_request_ci_statuses" => { second => "pass" }
    })

    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      trigger = find("[data-controller='dropdown'] > button")

      assert_no_selector "a[href='#{second}'].rounded-l-md"

      sighted_label = page.evaluate_script(<<~JS, trigger)
        (function (el) {
          const clone = el.cloneNode(true);
          clone.querySelectorAll(".sr-only").forEach((n) => n.remove());
          return clone.textContent;
        })(arguments[0])
      JS
      assert_equal "2", sighted_label.squish
      assert_equal "PRs, most recent #123 (Open)",
        trigger.find("span.sr-only", visible: :all).text(:all).strip
      assert_equal "View all PRs (2) — most recent #123 (Open)", trigger[:title]

      # The glyph and the CI dot still describe the newest PR, the way the header's
      # primary button does: open, so green; CI passing, so a green dot.
      assert_includes trigger.find("svg", match: :first)[:class], "text-green-600"
      assert trigger.has_selector?("span.rounded-full.bg-green-500", visible: :all),
        "the newest PR's CI status is not on the card's collapsed control"

      # The trigger says it opens something, and every PR is still one click away.
      assert_equal "true", trigger[:"aria-haspopup"]
      assert_equal "false", trigger[:"aria-expanded"]
      trigger.click
      assert_selector "[role='menuitem'][href='#{second}']"
      assert_selector "[role='menuitem'][href='#{first}']"
      assert_equal "true", trigger[:"aria-expanded"]
    end
  end

  test "PR status change from open to merged updates UI via turbo stream" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" }
    })

    visit root_path(every_status_params)

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

    visit root_path(every_status_params)

    # Verify PR link is present
    within "turbo-frame#session_#{@session.id}" do
      assert_selector "a[href='https://github.com/owner/repo/pull/456']"
    end

    # Refresh the page
    visit root_path(every_status_params)

    # Verify PR link is still present after refresh
    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/owner/repo/pull/456']")
      assert_equal "View PR on GitHub (Merged)", pr_link[:title]
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
    assert_equal "View PR on GitHub (Open)", pr_link[:title]
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

    # Archived sessions are hidden until the status filter names them.
    visit root_path(every_status_params(status: [ "archived" ]))

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

    visit root_path(every_status_params)

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

  test "full flow: session without PR gets the PR URL it opened extracted from the transcript" do
    # Start with a session with no PR metadata
    assert_nil @session.custom_metadata["github_pull_request_urls"]

    visit root_path(every_status_params)
    wait_for_turbo_streams_connected

    # No PR link initially
    within "turbo-frame#session_#{@session.id}" do
      assert_no_selector "a[href*='github.com']"
    end

    # Simulate what happens when TranscriptPollerService runs hooks:
    # 1. The agent runs `gh pr create` and its result carries the PR URL
    # 2. GithubPrUrlHook records it and updates custom_metadata
    # The invocation line matters: the hook records a PR the transcript shows this
    # session opening, not any PR URL that happens to appear in a tool result.
    transcript_content = <<~JSONL
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_123","name":"Bash","input":{"command":"gh pr create --fill"}}]}}
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
    visit root_path(every_status_params)

    within "turbo-frame#session_#{@session.id}" do
      pr_link = find("a[href='https://github.com/test/repo/pull/999']")
      assert_equal "View PR on GitHub (Merged)", pr_link[:title]
      pr_icon = pr_link.find("svg")
      assert_includes pr_icon[:class], "text-purple-600"
    end
  end
end
