require "rouge"
require "rouge/plugins/redcarpet"

module ApplicationHelper
  # Custom HTML renderer with Rouge syntax highlighting
  class MarkdownRenderer < Redcarpet::Render::HTML
    include Rouge::Plugins::Redcarpet

    # Known language identifiers for detecting language in multi-line inline code
    # When inline code starts with one of these followed by a newline, it's treated
    # as a code block with that language for syntax highlighting.
    # This list covers popular languages supported by Rouge for syntax highlighting.
    # Only includes identifiers that Rouge recognizes (verified against Rouge::Lexer.find_fancy).
    # To verify a new language: Rouge::Lexer.find_fancy('language_name')
    INLINE_CODE_LANGUAGES = %w[
      bash sh shell zsh console
      ruby rb python py perl pl php r lua tcl
      javascript js typescript ts jsx tsx coffeescript coffee
      json yaml yml xml html css scss sass
      sql plsql
      go rust java c cpp csharp cs swift kotlin scala
      objective_c objc objective_cpp
      clojure clj elixir erlang elm
      fsharp haskell hs ocaml sml
      lisp common_lisp scheme racket
      groovy
      dart julia nim zig crystal d mojo
      matlab fortran pascal ada cobol
      dockerfile docker makefile make cmake gradle
      terraform hcl nginx apache puppet nix
      graphql protobuf
      diff patch
      toml ini conf properties
      erb liquid jinja haml slim handlebars hbs
      markdown md tex latex
      powershell posh batchfile batch bat
      vim viml sed awk
      nasm armasm llvm glsl hlsl cuda
      prolog
      vue svelte
      gherkin cucumber
      verilog vhdl
    ].freeze

    def initialize(options = {})
      super(options.merge(
        hard_wrap: true,
        link_attributes: { target: "_blank", rel: "noopener noreferrer" }
      ))
    end

    # Override to add custom classes to code blocks with syntax highlighting
    def block_code(code, language)
      language ||= "plaintext"
      lexer = Rouge::Lexer.find_fancy(language, code) || Rouge::Lexers::PlainText.new
      formatter = Rouge::Formatters::HTMLInline.new(Rouge::Themes::Monokai)
      formatted_code = formatter.format(lexer.lex(code))

      # Escape the lexer tag and language for safe HTML attribute values
      safe_tag = ERB::Util.html_escape(lexer.tag)
      safe_language = ERB::Util.html_escape(language)

      %(<pre class="highlight language-#{safe_tag}" data-language="#{safe_language}"><code>#{formatted_code}</code></pre>)
    end

    # Style inline code with proper escaping
    # If the code contains newlines, render it as a code block instead
    def codespan(code)
      if code.nil?
        %(<code class="inline-code"></code>)
      elsif code.include?("\n")
        # Multi-line inline code should be rendered as a code block
        # Try to detect language from first line (e.g., `bash\ncommand`)
        lines = code.split("\n", 2)
        first_line = lines.first.strip.downcase

        # Check if first line looks like a language identifier and has actual code content
        if lines.length > 1 && INLINE_CODE_LANGUAGES.include?(first_line)
          actual_code = lines[1]
          # Only use language detection if there's actual code after the language line
          if actual_code.present?
            language = first_line
          else
            # Language-only with no code: render as plaintext with the original content
            language = "plaintext"
            actual_code = code
          end
        else
          language = "plaintext"
          actual_code = code
        end

        block_code(actual_code, language)
      else
        %(<code class="inline-code">#{ERB::Util.html_escape(code)}</code>)
      end
    end

    # Add classes to blockquotes for styling
    # Note: quote content is already processed by Redcarpet with filter_html: true
    def block_quote(quote)
      %(<blockquote class="markdown-blockquote">#{quote}</blockquote>)
    end

    # Add classes to tables
    # Note: header/body content is already processed by Redcarpet with filter_html: true
    def table(header, body)
      %(<div class="table-wrapper"><table class="markdown-table"><thead>#{header}</thead><tbody>#{body}</tbody></table></div>)
    end
  end

  # Render markdown text as HTML with syntax highlighting
  # Uses filter_html: true to prevent XSS attacks
  # Rescues rendering errors so a single bad message never crashes the whole page
  def markdown(text)
    return "" if text.blank?

    markdown_parser.render(text).html_safe
  rescue => e
    Rails.logger.error("[markdown] Rendering failed: #{e.class}: #{e.message}")
    content_tag(:pre, text, class: "whitespace-pre-wrap text-sm text-gray-700")
  end

  # Persisted network-egress health for the global banner (see EgressHealthCheck).
  # Returns the status hash when egress is degraded, otherwise nil so the banner
  # renders nothing. Never raises — a cache hiccup must not break page rendering.
  def network_egress_alert
    status = EgressHealthCheck.status
    status if status && status["status"] == "degraded"
  end

  # Format a stored iso8601 timestamp for the egress banner as "HH:MM UTC".
  # Tolerant of a malformed value so the banner never crashes on bad cache data.
  def egress_banner_time(iso8601)
    Time.iso8601(iso8601.to_s).utc.strftime("%H:%M UTC")
  rescue ArgumentError, TypeError
    nil
  end

  private

  # Memoize the markdown parser for better performance
  def markdown_parser
    @markdown_parser ||= begin
      renderer = MarkdownRenderer.new(
        filter_html: true,
        escape_html: true,
        safe_links_only: true
      )

      Redcarpet::Markdown.new(
        renderer,
        fenced_code_blocks: true,
        autolink: true,
        tables: true,
        strikethrough: true,
        superscript: true,
        no_intra_emphasis: true,
        highlight: true,
        quote: true,
        footnotes: true
      )
    end
  end
end
