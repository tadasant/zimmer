# frozen_string_literal: true

require "test_helper"

# A link to a Basic-auth-gated path must never be hover-prefetched.
#
# The bug: Tadas got the browser's native "Sign in to zimmer.tadasant.com"
# dialog at random moments while reading the sessions dashboard, without
# clicking anything. It tracked the *cursor*, not any action.
#
# The mechanism has two halves, and both live in this repo:
#
#   1. Turbo Drive prefetches same-origin <a href> on `mouseenter` — on by
#      default since Turbo 8 (turbo-rails 2.x, pinned in config/importmap.rb),
#      opt-out per link via `data-turbo-prefetch="false"`.
#   2. /supervisor answers an unauthenticated GET with 401 and
#      `WWW-Authenticate: Basic`. Per WHATWG Fetch, a browser shows its native
#      credential dialog for *any* same-origin credentialed fetch that comes
#      back that way — a background prefetch included. It does not wait for a
#      navigation, and there is no way to ask it not to from JavaScript.
#
# So the dashboard's "Supervisor" button popped a sign-in prompt at 100ms of
# hover, over a page nobody was leaving.
#
# The gate itself is not negotiable — /supervisor is the second wall in front of
# claude_accounts, mcp_oauth_credentials and x_oauth_credentials, which hold
# plaintext OAuth tokens. What changed is the *challenge on a speculative
# request* (Supervisor::ApplicationController#refuse) and whether the request is
# made at all (this file).
#
# This test is a source-level sweep rather than a check of the four links that
# exist today, because the defect returns the moment someone adds a fifth.
class BasicAuthPrefetchTest < ActiveSupport::TestCase
  # Every path under this prefix inherits Supervisor::ApplicationController's
  # Basic realm. It is the only surface in the app that issues a challenge —
  # /jobs (GoodJob) is not gated, and Api::BaseController answers with JSON and
  # no WWW-Authenticate header.
  GATED_ROUTE_HELPER = /\bsupervisor_\w*_(?:path|url)\b/

  OPT_OUT = /turbo_prefetch:\s*false|["']data-turbo-prefetch["']\s*=>\s*["']false["']|data-turbo-prefetch=["']false["']/

  test "every view link to a Basic-auth-gated path opts out of Turbo prefetch" do
    offenders = []

    Dir.glob(Rails.root.join("app/views/**/*.erb")).sort.each do |file|
      source = File.read(file)

      erb_tags(source).each do |tag|
        next unless tag.match?(GATED_ROUTE_HELPER)
        next unless tag.include?("link_to")
        next if tag.match?(OPT_OUT)

        offenders << "#{Pathname.new(file).relative_path_from(Rails.root)}: #{tag.squish.truncate(160)}"
      end
    end

    assert_empty offenders, <<~MESSAGE
      These links point at the HTTP Basic realm without `data: { turbo_prefetch: false }`.
      Turbo prefetches them on hover, /supervisor answers 401 + WWW-Authenticate, and the
      browser opens its native sign-in dialog over whatever page the human was reading.

      #{offenders.join("\n")}
    MESSAGE
  end

  # `<%# ... %>` comments count as tags here, which is harmless: a comment that
  # names a supervisor route helper does not contain `link_to`.
  def erb_tags(source)
    source.scan(/<%.*?%>/m)
  end
end

# The source sweep above is the guard that survives someone adding a link. This
# is the other half: what the browser is actually handed on the two screens the
# links live on today.
class BasicAuthPrefetchRenderingTest < ActionDispatch::IntegrationTest
  test "the sessions dashboard ships no prefetchable link to the Basic realm" do
    get root_url

    assert_response :success
    assert_operator gated_links(response.body).size, :>=, 2, "the dashboard links to /supervisor twice"
    assert_empty prefetchable(response.body), <<~MESSAGE
      Hovering these would fire a background GET at the Basic realm:
      #{prefetchable(response.body).join("\n")}
    MESSAGE
  end

  test "the health dashboard ships no prefetchable link to the Basic realm" do
    get health_dashboard_url

    assert_response :success
    assert_operator gated_links(response.body).size, :>=, 1, "the health page links to /supervisor"
    assert_empty prefetchable(response.body), <<~MESSAGE
      Hovering these would fire a background GET at the Basic realm:
      #{prefetchable(response.body).join("\n")}
    MESSAGE
  end

  private

  def gated_links(body)
    body.scan(/<a\b[^>]*\shref="\/supervisor[^"]*"[^>]*>/)
  end

  # Turbo skips a link with a `target` (it opens outside the document), so that
  # counts as opted out too — the same reason the /jobs links need no guard.
  def prefetchable(body)
    gated_links(body).reject { |link| link.include?(%(data-turbo-prefetch="false")) || link.include?(" target=") }
  end
end
