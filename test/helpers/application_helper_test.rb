require "test_helper"
require "mocha/minitest"

class ApplicationHelperTest < ActionView::TestCase
  # Basic rendering tests
  test "markdown renders basic text" do
    result = markdown("Hello **world**")
    assert_includes result, "<strong>world</strong>"
  end

  test "markdown returns empty string for nil input" do
    assert_equal "", markdown(nil)
  end

  test "markdown returns empty string for empty string input" do
    assert_equal "", markdown("")
  end

  test "markdown returns empty string for blank string input" do
    assert_equal "", markdown("   ")
  end

  # Code block tests
  test "markdown renders code blocks with syntax highlighting" do
    result = markdown("```ruby\nputs 'hello'\n```")
    assert_includes result, 'class="highlight language-ruby"'
    assert_includes result, 'data-language="ruby"'
  end

  test "markdown renders code blocks with unknown language" do
    result = markdown("```unknownlang\nsome code\n```")
    assert_includes result, 'class="highlight'
  end

  test "markdown renders code blocks without language" do
    result = markdown("```\nsome code\n```")
    assert_includes result, 'class="highlight language-plaintext"'
    assert_includes result, 'data-language="plaintext"'
  end

  # Inline code tests
  test "markdown renders inline code with custom class" do
    result = markdown("`code`")
    assert_includes result, 'class="inline-code"'
    assert_includes result, "code"
  end

  test "markdown escapes HTML in inline code" do
    result = markdown("`<script>alert('xss')</script>`")
    assert_includes result, "&lt;script&gt;"
    assert_not_includes result, "<script>alert"
  end

  test "codespan handles nil code without crashing" do
    result = ApplicationHelper::MarkdownRenderer.new.codespan(nil)
    assert_includes result, 'class="inline-code"'
  end

  # Rendering error resilience
  test "markdown falls back to escaped plaintext when rendering raises" do
    # Replace the memoized parser with one that always raises
    error_parser = Object.new
    error_parser.define_singleton_method(:render) { |_| raise NoMethodError, "undefined method 'include?' for nil" }
    self.instance_variable_set(:@markdown_parser, error_parser)

    result = markdown("some `broken` content")

    assert_includes result, "some `broken` content"
    assert_includes result, "<pre"
  end

  # Table tests
  test "markdown renders tables with custom classes" do
    markdown_table = "| Header |\n|--------|\n| Cell   |"
    result = markdown(markdown_table)
    assert_includes result, 'class="table-wrapper"'
    assert_includes result, 'class="markdown-table"'
  end

  # A table an agent nests under a numbered item, indented to the item's content
  # column (three spaces under "1. ") — the shape agents write in their final messages.
  test "markdown renders a table nested in a list item, inside the item" do
    text = <<~MD
      **What changed:**
      1. **Live figures**: for this month so far:

         | Functionality | Before | After |
         |---|---|---|
         | Agent inference | $10 | $20 |
         | Docs site | $5 | gone (it held only fixed cost) |

         The monthly total rose about $5.
      2. **Skill**: updated.
    MD
    fragment = Nokogiri::HTML5.fragment(markdown(text))

    items = fragment.css("ol > li")
    assert_equal 2, items.size, "the indented table and paragraph must not end the list"
    table = items.first.at_css("div.table-wrapper > table.markdown-table")
    assert table, "the table renders inside the first list item"
    assert_equal %w[Functionality Before After], table.css("thead th").map(&:text)
    assert_equal [ "Agent inference", "$10", "$20" ], table.css("tbody tr").first.css("td").map(&:text)
    assert_includes items.first.text, "The monthly total rose about $5."
    assert_not_includes fragment.text, "|---|"
  end

  test "markdown renders a table nested in a bulleted item and in a blockquote" do
    bulleted = Nokogiri::HTML5.fragment(markdown("- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n"))
    assert bulleted.at_css("ul > li table.markdown-table")

    quoted = Nokogiri::HTML5.fragment(markdown("> | a | b |\n> |---|---|\n> | 1 | 2 |\n"))
    assert quoted.at_css("blockquote.markdown-blockquote table.markdown-table")
  end

  test "markdown escapes raw HTML in a table cell" do
    fragment = Nokogiri::HTML5.fragment(markdown("| a |\n|---|\n| <img src=x onerror=alert(1)> |\n"))
    assert_empty fragment.css("img")
    assert_includes fragment.at_css("td").text, "<img src=x onerror=alert(1)>"
  end

  test "markdown highlights a fenced code block nested in a list item" do
    fragment = Nokogiri::HTML5.fragment(markdown("1. Run:\n\n   ```ruby\n   puts 1\n   ```\n2. Done\n"))
    assert fragment.at_css("ol > li pre.highlight.language-ruby")
    assert_equal 2, fragment.css("ol > li").size
  end

  test "markdown code tokens cannot be forged by the text" do
    result = markdown("`x`123 zmdspan0n0z")
    assert_includes result, %(<code class="inline-code">x</code>123)
    assert_includes result, "zmdspan0n0z"
  end

  test "markdown keeps a bare URL's closing parenthesis and colon out of the link" do
    result = markdown("Live figures (https://zimmer.example.com/sessions/42): rose")
    assert_includes result, %(<a href="https://zimmer.example.com/sessions/42" target="_blank" rel="noopener noreferrer">)
  end

  # Blockquote tests
  test "markdown renders blockquotes with custom class" do
    result = markdown("> This is a quote")
    assert_includes result, 'class="markdown-blockquote"'
  end

  # Link tests
  test "markdown adds target blank to links" do
    result = markdown("[Link](https://example.com)")
    assert_includes result, 'target="_blank"'
    assert_includes result, 'rel="noopener noreferrer"'
  end

  test "markdown autolinking URLs" do
    result = markdown("Visit https://example.com for more info")
    assert_includes result, "<a"
    assert_includes result, "https://example.com"
  end

  # Security tests - HTML is escaped, not executed
  test "markdown escapes script tags" do
    result = markdown("<script>alert('XSS')</script>")
    # The script tag should be HTML-escaped, not rendered as actual script
    assert_not_includes result, "<script>"
    assert_includes result, "&lt;script&gt;" # Escaped version
  end

  test "markdown escapes onclick handlers" do
    result = markdown('<div onclick="alert(\'xss\')">Click me</div>')
    # The div should be HTML-escaped, not rendered as actual HTML
    assert_not_includes result, "<div onclick"
    assert_includes result, "&lt;div" # Escaped version
  end

  test "markdown escapes img onerror handlers" do
    result = markdown('<img src=x onerror="alert(\'XSS\')">')
    # The img tag should be HTML-escaped, not rendered as actual HTML
    assert_not_includes result, "<img src"
    assert_includes result, "&lt;img" # Escaped version
  end

  test "markdown handles javascript protocol in links" do
    result = markdown('[Click me](javascript:alert("XSS"))')
    # With safe_links_only: true, javascript links are not rendered as clickable links
    # The link text may still appear but the href should be stripped or the link not rendered
    assert_not_includes result, 'href="javascript:'
  end

  # Markdown feature tests
  test "markdown renders strikethrough" do
    result = markdown("~~deleted~~")
    assert_includes result, "<del>"
    assert_includes result, "deleted"
    assert_includes result, "</del>"
  end

  test "markdown renders superscript" do
    result = markdown("2^10^")
    assert_includes result, "<sup>"
  end

  test "markdown renders headings" do
    result = markdown("# Heading 1\n## Heading 2")
    assert_includes result, "<h1>"
    assert_includes result, "<h2>"
  end

  test "markdown renders unordered lists" do
    result = markdown("- Item 1\n- Item 2")
    assert_includes result, "<ul>"
    assert_includes result, "<li>"
  end

  test "markdown renders ordered lists" do
    result = markdown("1. First\n2. Second")
    assert_includes result, "<ol>"
    assert_includes result, "<li>"
  end

  test "markdown renders horizontal rules" do
    result = markdown("---")
    assert_includes result, "<hr"
  end

  test "markdown hard wraps newlines" do
    result = markdown("Line 1\nLine 2")
    assert_includes result, "<br"
  end

  # The Undo toast may not outlive the window the server honors it in — that gap
  # is #1036, where the button sat on screen for 25 seconds after it had stopped
  # working. The toast reads the window rather than restating it.
  test "the Undo toast lives exactly as long as the server's undo window" do
    assert_equal SessionStateMachine::UNDO_ARCHIVE_WINDOW.in_milliseconds,
      flash_duration_ms("undo_archive")
  end

  test "a flash with no inline action uses the short timer" do
    assert_equal 5_000, flash_duration_ms(nil)
  end

  test "the Archive anyway toast outlives a bare notice" do
    assert flash_duration_ms("force_archive") > flash_duration_ms(nil)
  end

  test "inline_markdown keeps links, code and emphasis" do
    result = inline_markdown("Merge [PR #12](https://github.com/o/r/pull/12) or drop `roles.zimmer`, **now** or _later_.")

    assert_includes result, '<a href="https://github.com/o/r/pull/12" target="_blank" rel="noopener noreferrer">PR #12</a>'
    assert_includes result, "<code>roles.zimmer</code>"
    assert_includes result, "<strong>now</strong>"
    assert_includes result, "<em>later</em>"
    assert result.html_safe?
  end

  test "inline_markdown unwraps block elements to their text" do
    result = inline_markdown("# Heading\n\nFirst.\n\nSecond.\n\n- item\n\n```ruby\nputs 1\n```\n\n| a |\n|---|\n| 1 |")

    %w[<p <h1 <ul <li <pre <table <br <span].each { |tag| assert_not_includes result, tag }
    assert_includes result, "Heading"
    assert_includes result, "Second."
    assert_includes result, "item"
    assert_includes result, "<code>puts 1"
  end

  test "inline_markdown lets no raw HTML or script URL through" do
    result = inline_markdown('[bad](javascript:alert(1)) <script>alert(2)</script> <a href="javascript:alert(3)">x</a> <img src=x onerror=alert(4)>')

    # Parsed rather than string-matched: the escaped input still spells
    # `href="javascript:` as TEXT, which is harmless — what must not exist is an
    # element carrying it.
    fragment = Nokogiri::HTML5.fragment(result)
    assert_empty fragment.css("a, script, img")
    assert_includes fragment.text, "<script>alert(2)</script>"
  end

  test "inline_markdown keeps quotation marks" do
    result = Nokogiri::HTML5.fragment(inline_markdown('The gate said "too broad" and stopped.'))
    assert_equal %(The gate said "too broad" and stopped.), result.text.strip
  end

  test "markdown_plain_text keeps quotation marks" do
    assert_equal 'The gate said "too broad" and stopped.', markdown_plain_text('The gate said "too broad" and stopped.')
  end

  test "inline_markdown returns empty string for blank input" do
    assert_equal "", inline_markdown(nil)
    assert_equal "", inline_markdown("  ")
  end

  test "markdown_plain_text drops markup without double-escaping" do
    assert_equal "Merge PR #12 & drop roles.zimmer.",
      markdown_plain_text("Merge [PR #12](https://github.com/o/r/pull/12) & drop `roles.zimmer`.")
  end

  test "inline_markdown answers a repeat from memory, still html_safe and unchanged" do
    text = "Memo check #{SecureRandom.hex(4)}: [PR](https://github.com/o/r/pull/1) and `code`."
    first = inline_markdown(text)

    expects(:sanitize).never
    second = inline_markdown(text)

    assert_predicate second, :html_safe?
    assert_equal first.to_s, second.to_s
  end

  test "markdown_plain_text answers a repeat from memory" do
    text = "Plain memo #{SecureRandom.hex(4)}: **bold** & `code`."
    first = markdown_plain_text(text)

    expects(:strip_tags).never
    assert_equal first, markdown_plain_text(text)
  end
end
