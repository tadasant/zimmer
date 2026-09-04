# frozen_string_literal: true

# Geometry assertions for "does this screen fit a phone".
#
# Horizontal overflow is the failure mode phone users actually report: a control
# runs past the right edge and is either unreachable or forces the whole page to
# scroll sideways. Two things have to be checked, because neither sees what the
# other does — the document's own scroll width misses anything an
# `overflow-x: hidden` ancestor has already clipped, and a clipped control is the
# worse of the two failures, since the user cannot even scroll to it.
#
# Extracted from MobileHorizontalOverflowTest so screens that need their own
# setup — a request header, a credential — can assert the same invariant without
# reimplementing a weaker copy of the probe.
module MobileOverflowAssertions
  MOBILE_WIDTH = 375
  MOBILE_HEIGHT = 812

  # The narrowest phone the mobile QA pass asks for. It is a separate width rather
  # than a lower MOBILE_WIDTH because the two catch different things: 375px is the
  # width most phones actually report, and 320px is where a fixed minimum — a
  # `min-w-`, a grid track's floor — stops fitting at all. A layout can pass one
  # and fail the other, which is exactly what issue #803 was.
  NARROW_WIDTH = 320

  # Returns [document_overflow_px, [clipped control descriptions], viewport_px].
  #
  # The viewport width is reported rather than assumed because the same probe runs
  # at both MOBILE_WIDTH and NARROW_WIDTH, and `resize_to` sizes the window rather
  # than the viewport — so the number a failure should name is the one the document
  # actually got.
  def overflow_report
    page.evaluate_script(<<~JS)
      (function () {
        const W = document.documentElement.clientWidth;
        const clipped = [];
        document.querySelectorAll("button, a, input, select, textarea, summary, table, h1, h2, h3, code, pre").forEach((el) => {
          const cs = getComputedStyle(el);
          if (cs.display === "none" || cs.visibility === "hidden") return;
          const b = el.getBoundingClientRect();
          if (b.width === 0 || b.height === 0) return;
          let p = el.parentElement, clipper = null;
          while (p && p !== document.documentElement) {
            const s = getComputedStyle(p);
            if (s.overflowX === "hidden" || s.overflowX === "clip") { clipper = p; break; }
            p = p.parentElement;
          }
          if (!clipper) return;
          const cut = Math.round(b.right - clipper.getBoundingClientRect().right);
          if (cut > 1) {
            clipped.push(cut + "px past its container: <" + el.tagName.toLowerCase() + "> " +
              JSON.stringify((el.innerText || el.value || "").trim().slice(0, 40)));
          }
        });
        return [document.documentElement.scrollWidth - W, clipped, W];
      })()
    JS
  end

  def assert_no_horizontal_overflow(label)
    doc_overflow, clipped, width = overflow_report

    assert doc_overflow <= 0,
      "#{label} scrolls sideways at #{width}px: the document is #{doc_overflow}px wider than the viewport."
    assert_empty clipped,
      "#{label} has controls clipped out of reach at #{width}px:\n  #{clipped.join("\n  ")}"
  end
end
