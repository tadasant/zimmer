# Anti-slop rubric

A gradeable checklist for keeping Zimmer's docs from reading or looking
AI-generated. Two parts: **voice** (graded per page against the page's prose)
and **design** (graded once against the theme, since it's global). Use it with
`references/BRAND_VOICE.md` and `references/BRAND.md`, which define the target.

Grade each item **pass / fail / n/a** with a one-line reason and a file:line or
selector. "Slop" is the statistical average of a million templates and a million
blog posts; the goal is prose and design that a specific person made specific
choices about.

Sources this distills: common write-ups on AI "slop" in
[design](https://www.developersdigest.tech/blog/ai-design-slop-and-how-to-spot-it)
and [writing](https://arxiv.org/pdf/2510.15061) (contrast-framing is the single
most-cited tell).

---

## Part A — Voice (grade every page)

Grade a page **fail** on an item if it happens even once, unless noted.

| # | Tell | How to spot it | Pass = |
| --- | --- | --- | --- |
| V1 | **Antithesis / contrast framing.** The #1 tell. | "it's not X, it's Y", "not just … but", "isn't a … it's a …", "not merely", "rather than a … it's a …", or a heading built on "X, not Y". Search the page for `, not ` / `not just` / `isn't` / `rather than`. | Zero rhetorical contrast frames. A plain factual contrast ("returns 200, not 204") is fine; a *framing* device is not. |
| V2 | **Rule of three.** | Three-item lists used for rhythm, especially adjectives ("fast, simple, and reliable") or tricolon sentences repeated across a page. | Lists have the number of items the facts require, not three-for-cadence. |
| V3 | **Em-dash / colon-splice cadence.** | More than one em-dash in a sentence, or a page where most paragraphs lean on the same "—" or ":" reveal beat. | ≤1 em-dash per paragraph; varied sentence shapes. |
| V4 | **Emphasis-bold.** | `**bold**` on whole sentences or clauses for emphasis (not a defined term or a label like `**Consequence:**`). | Bold only marks a term-on-first-use or a run-in label. |
| V5 | **Hype / filler vocabulary.** | seamless, robust, leverage, powerful, effortless, unlock, delve, elevate, "in today's world", "at its core", "the beauty of". | None. |
| V6 | **Weasel intensifiers.** | simply, just, basically, essentially, actually, really, very, "of course", "needless to say". | Only where load-bearing. |
| V7 | **Uniform paragraph rhythm.** | Every paragraph = one short punchy fragment then one long explanatory sentence. | Sentence and paragraph length visibly varies. |
| V8 | **Signposting filler.** | "It's worth noting that", "Importantly,", "That said,", "Ultimately,", "In essence,". | Cut; state the thing. |
| V9 | **Vague grandeur.** | Claims with no file/number behind them; "powerful and flexible"; a benefit with no mechanism. | Every claim names a file, number, or concrete behavior. |
| V10 | **Repeated tic word.** | The same distinctive word ("silently", "deliberately", "genuinely", "cleanly") used 4+ times on one page. | No single tic word dominates. |

## Part B — Design (grade once, against the theme)

| # | Tell | How to spot it | Pass = |
| --- | --- | --- | --- |
| D1 | **Inter / one-font-no-hierarchy.** | Inter specifically, or a single font with no size/weight hierarchy. | A deliberate, non-Inter family with a clear scale. |
| D2 | **Purple/violet gradients, cyan-on-dark, colored glows.** | Gradient fills, `box-shadow` with a coloured tint, neon accents. | No gradients or coloured glows; neutral depth only. |
| D3 | **Colored left borders / stripes** on cards or callouts. | A thick coloured `border-left` "accent bar". | Severity/emphasis carried by icon + label + a quiet full border, not a stripe. |
| D4 | **Tinted-pill / heavy active-nav affordance.** | The selected sidebar item as a filled/tinted rounded background, often with a coloured left bar. | Active state is weight + colour, minimal or no fill. |
| D5 | **Line noise.** | Rules above every heading, full-width `<hr>`s between every block, persistent underlines on every link, heavy table gridlines. | Lines used sparingly; hierarchy from whitespace and weight. |
| D6 | **Over-rounding.** | Border-radius ≥ 16–24px on small elements; everything a soft blob. | Modest radii (≤ ~8px). |
| D7 | **Over-animation / hover on non-interactive elements.** | Lifts, glows, or reveals on things that aren't links/buttons; staggered load animations. | Motion only on genuinely interactive elements; minimal. |
| D8 | **All-caps micro-labels + emoji nav.** | Uppercase tracked section labels; emoji as sidebar icons. | Sentence case; text or restrained icons. |
| D9 | **Identical icon-top cards / centered-hero-badge template.** | The generic landing template: centered hero, badge, three identical icon cards. | Layout has a specific point of view; cards vary or earn their uniformity. |
| D10 | **Low-contrast body text.** | Gray-on-gray body or labels below WCAG AA (4.5:1 body, 3:1 large/graphics). | All text ≥ AA in both themes. |

---

## How to run it

1. A reviewer (or subagent) grades **Part A** for one page and **Part B** once,
   returning a table of fails with file:line / selector and a one-line fix.
2. Fixes are applied, the page re-graded, and the site rebuilt
   (`cd docs && npm run build`) and eyeballed in both themes.
3. A page ships when Part A is all-pass and Part B is all-pass.

The bar is not "no AI wrote this." The bar is "a person who cares made these
choices, and you can tell."
