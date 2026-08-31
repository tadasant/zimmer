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

  # Returns [document_overflow_px, [clipped control descriptions]].
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
        return [document.documentElement.scrollWidth - W, clipped];
      })()
    JS
  end

  def assert_no_horizontal_overflow(label)
    doc_overflow, clipped = overflow_report

    assert doc_overflow <= 0,
      "#{label} scrolls sideways at #{MOBILE_WIDTH}px: the document is #{doc_overflow}px wider than the viewport."
    assert_empty clipped,
      "#{label} has controls clipped out of reach at #{MOBILE_WIDTH}px:\n  #{clipped.join("\n  ")}"
  end
end
