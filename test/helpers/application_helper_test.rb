require "test_helper"

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
    renderer = ApplicationHelper::MarkdownRenderer.new(filter_html: true, escape_html: true, safe_links_only: true)
    result = renderer.codespan(nil)
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
end
