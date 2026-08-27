# frozen_string_literal: true

require "test_helper"

# Turbo's "Content missing" placeholder must never reach the screen.
#
# The string is Turbo's own: when a <turbo-frame>'s fetch comes back with a body
# that has no matching frame in it, Turbo dispatches `turbo:frame-missing`, and if
# nothing cancels that event it writes
# `<strong class="turbo-frame-error">Content missing</strong>` into the frame,
# stamps the frame `complete` so it never retries, and throws.
#
# It has been chased four times. #665 closed the one cause that was genuinely a
# server-side mistake — /sessions/:id served two structurally different bodies from
# one URL, and Turbo's URL-keyed prefetch cache handed the drawer the wrong one —
# and it kept coming back, because every OTHER cause is a response that has nothing
# to do with frames: the 502 a proxy returns while the app restarts, a 500, the 404
# for a session deleted out of the trash, and a redirect that answers a frame's
# fetch with a whole page.
#
# So the rule is pinned from both ends, and neither half is about one link:
#
#   Server side — no URL a frame can navigate to may answer without that frame,
#   and no <a href> may point at a URL a frame fetches (that shared key is what
#   made the prefetch cache able to swap the bodies).
#
#   Client side — whatever the cause, `turbo:frame-missing` is cancelled, so the
#   placeholder is never written and the frame gets an honest message instead.
class TurboFrameContentMissingTest < ActionDispatch::IntegrationTest
  RECOVERY = Rails.root.join("app/javascript/lib/frame_missing_recovery.js")
  ENTRYPOINT = Rails.root.join("app/javascript/application.js")

  # The dashboard in every view mode, with and without the status filters, plus
  # every other page that renders frames. These must render — a scan over a page
  # that 500s would pass by finding nothing.
  DASHBOARD_PAGES = [
    "/",
    "/?view=ranked",
    "/?view=categories",
    "/?view=last_touched",
    "/?view=created_desc",
    "/?filters=1&status%5B%5D=waiting&status%5B%5D=running&status%5B%5D=needs_input&view=ranked",
    "/?filters=1&status%5B%5D=waiting&status%5B%5D=running&status%5B%5D=needs_input&view=categories",
    "/?search=a"
  ].freeze

  OTHER_PAGES = [ "/notifications", "/clis", "/triggers", "/connectors" ].freeze

  # --- client side ----------------------------------------------------------

  test "turbo:frame-missing is always cancelled, so the placeholder is never written" do
    source = RECOVERY.read

    assert_includes source, 'addEventListener("turbo:frame-missing"',
      "Something has to listen for the event, or Turbo writes its placeholder."
    assert_includes source, "event.preventDefault()",
      "Cancelling the event is what stops Turbo writing 'Content missing' and throwing. " \
      "Handling the event without cancelling it changes nothing."
    assert_includes source, 'node.localName === "turbo-frame"',
      "Turbo redispatches this event on <html> when the frame left the document mid-fetch. " \
      "A handler that paints its fallback into event.target without checking would replace " \
      "the whole page with the fallback."
    # Comments are allowed to name the string — that is what they are explaining.
    # The code must never write it.
    code = source.lines.reject { |l| l.strip.start_with?("//") }.join
    assert_no_match(/Content missing/, code,
      "The fallback must say what actually happened, not restate Turbo's placeholder.")
  end

  test "the guard is bound before Turbo can dispatch the event" do
    # Comments above the imports explain the ordering and name both modules, so match
    # on the import statements themselves rather than on any line mentioning them.
    lines = ENTRYPOINT.read.lines.map(&:strip).grep(/\Aimport /)
    recovery = lines.index { |l| l.include?("lib/frame_missing_recovery") }
    turbo = lines.index { |l| l.include?("@hotwired/turbo-rails") }

    assert recovery, "application.js must import lib/frame_missing_recovery."
    assert turbo, "application.js must import @hotwired/turbo-rails."
    assert_operator recovery, :<, turbo,
      "The frame-missing guard is imported ahead of Turbo so it is listening before " \
      "the first frame fetch can come back."
  end

  test "the recovery module is reachable through the importmap" do
    assert_includes Rails.root.join("config/importmap.rb").read, 'pin_all_from "app/javascript/lib"',
      "lib/frame_missing_recovery is only importable because app/javascript/lib is pinned."
  end

  # --- server side ----------------------------------------------------------

  test "no page offers a frame a body without that frame in it" do
    problems = []

    (DASHBOARD_PAGES + OTHER_PAGES + session_pages).each do |page|
      frame = page.end_with?("/drawer") ? "session_detail" : nil
      doc, status = fetch_doc(page, frame: frame)

      if DASHBOARD_PAGES.include?(page)
        assert_equal 200, status, "#{page} must render for this scan to mean anything"
      end
      if doc.nil?
        # A page that cannot render is skipped by the scan below, and a silently
        # skipped page is a scan that passes by looking at nothing.
        problems << "#{page}: did not render (#{status}), so nothing on it was scanned"
        next
      end

      # A frame's own src must answer with that frame.
      doc.css("turbo-frame[src]").each do |f|
        sub, sub_status = fetch_doc(f["src"], frame: f["id"])
        next if sub && sub.css("turbo-frame##{f['id']}").any?
        problems << "#{page}: <turbo-frame id=#{f['id']}> loads #{f['src']}, which answered " \
                    "#{sub_status} with no matching frame"
      end

      # No <a href> may share a URL with a frame's src: Turbo's prefetch cache is
      # keyed by URL alone, so a shared key lets a hover on the link decide what
      # the frame receives. This is the #665 collision, stated as a rule over the
      # whole page rather than as a property of one link.
      # Compared whole, query string included, because that is exactly what Turbo
      # keys its prefetch cache on — anything looser reports a link to ?page=3 as
      # colliding with a frame at ?page=2.
      srcs = doc.css("turbo-frame[src]").to_h { |f| [ f["src"].to_s, f["id"] ] }
      doc.css("a[href]").map { |a| a["href"].to_s }.uniq.each do |href|
        next unless srcs.key?(href)
        problems << "#{page}: <a href=#{href}> points at the URL <turbo-frame " \
                    "id=#{srcs[href]}> fetches; Turbo's prefetch cache is keyed by URL alone"
      end

      # A GET link that navigates a frame must answer with that frame. Links
      # carrying data-turbo-method are excluded on purpose: Turbo synthesises a
      # form for them on document.body, so they escape the frame entirely.
      doc.css("a[href]").uniq { |a| [ a["href"], a["data-turbo-frame"], a.ancestors("turbo-frame").first&.[]("id") ] }.each do |a|
        href = a["href"].to_s
        next unless href.start_with?("/")
        next if a["data-turbo"] == "false"
        method = a["data-turbo-method"].to_s.downcase
        next if method.present? && method != "get" && a["data-turbo-frame"].blank?
        next unless method.blank? || method == "get"

        target = a["data-turbo-frame"] || a.ancestors("turbo-frame").first&.then { |f| f["target"] || f["id"] }
        next if target.nil? || target == "_top"

        sub, sub_status = fetch_doc(href, frame: target)
        next if sub && sub.css("turbo-frame##{target}").any?
        problems << "#{page}: a link to #{href} navigates <turbo-frame id=#{target}>, " \
                    "which answered #{sub_status} with no matching frame"
      end
    end

    assert_empty problems.uniq, "Frame navigations that would render 'Content missing':\n" +
      problems.uniq.join("\n")
  end

  test "the drawer and the full session page still have disjoint URLs" do
    session = Session.first
    get session_path(session)
    assert_response :success
    assert_no_match(/<turbo-frame id="session_detail"/, response.body,
      "/sessions/:id is unconditionally frameless.")

    get drawer_session_path(session), headers: { "Turbo-Frame" => "session_detail" }
    assert_response :success
    assert_match(/<turbo-frame id="session_detail"/, response.body,
      "/sessions/:id/drawer is unconditionally framed.")
  end

  private

  def session_pages
    ids = Session.order(:id).limit(4).pluck(:id)
    ids.map { |id| "/sessions/#{id}" } + ids.map { |id| "/sessions/#{id}/drawer" }
  end

  def fetch_doc(path, frame: nil)
    get path, headers: frame ? { "Turbo-Frame" => frame } : {}
    # Bounded: a redirect cycle would otherwise hang the suite rather than fail it.
    5.times { break unless response.redirect?; follow_redirect! }
    return [ nil, "redirect loop" ] if response.redirect?

    [ Nokogiri::HTML(response.body), response.status ]
  rescue StandardError
    # A 500 raises here rather than rendering, and a page that cannot render is
    # exactly as much of a problem as one that renders without its frame.
    [ nil, "raised" ]
  end
end
