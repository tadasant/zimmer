require "application_system_test_case"

# TEMPORARY — repetition evidence for the BroadcastRenderedFormCsrfSystemTest flake fix.
# Removed before the PR is finalized.
class ZzCsrfFlakeStressTest < ApplicationSystemTestCase
  setup do
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @session = Session.create!(agent_runtime: "claude_code", status: :needs_input, prompt: "p",
      title: "Waiting on a car", mcp_servers: [], config: {},
      git_root: "https://github.com/test/repo.git", branch: "main")
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  def header = "#session_#{@session.id}_header_actions"
  def token_sel = "#{header} form[action$='update_carplay_fit'] input[name='authenticity_token']"

  def wait_for_prefetch
    deadline = Time.current + 10
    until page.evaluate_script("performance.getEntriesByType('resource').some((e) => new URL(e.name).pathname === '/sessions/#{@session.to_param}/drawer')") || Time.current > deadline
      sleep 0.05
    end
  end

  def open_drawer(force_prefetch_first:)
    visit root_path
    wait_for_prefetch if force_prefetch_first
    find("a[href='#{session_path(@session)}'][data-action*='session-drawer#open']").click
    assert_selector token_sel, visible: :all
  end

  def broadcast
    html = SessionsController.render(partial: "sessions/session_header_actions", locals: { agent_session: @session })
    stream = %(<turbo-stream action="replace" target="session_#{@session.id}_header_actions"><template>#{html}</template></turbo-stream>)
    page.execute_script("Turbo.renderStreamMessage(arguments[0])", stream)
  end

  def wait_settled
    assert_no_selector "[data-current-session-id='#{@session.id}'][data-session-activation='pending']"
  end

  def finish
    assert_no_selector token_sel, visible: :all
    find("#{header} summary[aria-label='More CarPlay fit choices']").click
    find("#{header} button[value='laptop_only']").click
    assert_text "marked Laptop only"
    assert_equal "laptop_only", @session.reload.carplay_fit
  end

  25.times do |i|
    test "fixed, natural timing #{i}" do
      open_drawer(force_prefetch_first: false)
      wait_settled
      broadcast
      finish
    end

    test "fixed, prefetch forced to land first #{i}" do
      open_drawer(force_prefetch_first: true)
      wait_settled
      broadcast
      finish
    end
  end

  # Control: the pre-fix ordering (no wait) with the prefetch forced first. Records
  # whether the activation backfill put the token back; never fails.
  10.times do |i|
    test "control, old ordering, prefetch forced first #{i}" do
      open_drawer(force_prefetch_first: true)
      activation = page.evaluate_script("document.querySelector(\"[data-current-session-id='#{@session.id}']\").dataset.sessionActivation || 'none'")
      broadcast
      wait_settled
      token_back = page.all(token_sel, visible: :all, wait: 0).any?
      puts "\nCONTROL #{i}: activation=#{activation} token_back_after_broadcast=#{token_back}"
      assert true
    end
  end
end
