# frozen_string_literal: true

require "test_helper"

# The follow-up composer is static: typing into it needs nothing from the
# server, so it is part of the first paint of every surface a session opens on,
# and never waits behind the lazy frames that bring the heavy content.
#
# - The full page (/sessions/:id) carries it in its own response, outside the
#   deferred transcript and provenance frames.
# - The drawer's body (/sessions/:id/drawer) carries it the same way.
# - The dashboard drawer, whose whole body is one lazy frame, carries a
#   provisional composer in its loading skeleton (_drawer_composer), so it is
#   on screen the moment the drawer slides in, before that frame lands.
class SessionsControllerEagerComposerTest < ActionDispatch::IntegrationTest
  setup do
    @session = Session.create!(
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "eager composer",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  def lazy_frames
    css_select("turbo-frame[src]")
  end

  def assert_composer_outside_lazy_frames
    composer = css_select("textarea[name='follow_up_prompt']")
    assert_equal 1, composer.size, "the composer textarea is in the initial response"
    assert_not_empty lazy_frames, "the heavy panels are still deferred frames"
    lazy_frames.each do |frame|
      assert_empty frame.css("textarea[name='follow_up_prompt']"),
                   "the composer must not sit inside the lazy frame #{frame['id']}"
    end
    composer.first.ancestors.each do |ancestor|
      next unless ancestor.name == "turbo-frame"

      assert_nil ancestor["src"], "the composer's frame #{ancestor['id']} must not be a lazy one"
    end
  end

  test "the full page renders the composer eagerly, outside the lazy transcript and provenance frames" do
    get session_url(@session)
    assert_response :success

    assert_select "turbo-frame#session_#{@session.id}_transcript[src]"
    assert_select "turbo-frame#session_#{@session.id}_provenance_panel[src]"
    assert_composer_outside_lazy_frames
  end

  test "the drawer body renders the composer eagerly, outside its lazy frames" do
    get drawer_session_url(@session)
    assert_response :success

    assert_select "turbo-frame#session_detail:not([src])"
    assert_select "turbo-frame#session_#{@session.id}_transcript[src]"
    assert_composer_outside_lazy_frames
  end

  test "the dashboard's drawer skeleton carries a provisional composer, and each drawer link names its session" do
    get root_url(status: "all")
    assert_response :success

    template = css_select("template[data-session-drawer-target='skeleton']").first
    assert template, "the dashboard carries the drawer skeleton"
    composer = template.at_css("[data-drawer-skeleton] [data-drawer-composer][data-controller='drawer-composer']")
    assert composer, "the skeleton carries the provisional composer"
    assert composer.at_css("textarea[data-drawer-composer-target='textarea']")
    assert_nil composer.at_css("textarea[id]"), "no id: the real textarea is data-turbo-permanent and keyed by id"
    assert_nil composer.ancestors.find { |node| node["role"] == "status" }, "the composer is not part of the loading status region"
  end
end
