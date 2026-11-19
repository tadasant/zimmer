require "rouge"

module ApplicationHelper
  # What every composer's "Photos & videos" input accepts.
  #
  # Deliberately wider than ImageStorageService::SUPPORTED_TYPES. `image/*,video/*`
  # is what puts "Photo Library" and "Take Photo or Video" on the iOS share sheet
  # and what opens Android Chrome's media picker instead of its document browser.
  # A list narrowed to the four storable types greys out an iPhone's own photos,
  # since an iPhone still is HEIC. The picked file is split client-side
  # (app/javascript/lib/media_kinds.js) — JPEG/PNG/GIF/WebP go up the image path
  # and the model reads them inline, everything else goes up the file path and the
  # agent gets a path to it.
  #
  # Kept in lockstep with MEDIA_ACCEPT in app/javascript/lib/media_kinds.js, which
  # test/helpers/media_picker_accept_parity_test.rb pins.
  MEDIA_PICKER_ACCEPT = "image/*,video/*,.heic,.heif,.mov"

  def media_picker_accept
    MEDIA_PICKER_ACCEPT
  end

  # Markdown to HTML for everything an agent or a person writes into Zimmer.
  #
  # Parsed by Commonmarker (comrak), which follows CommonMark and GitHub Flavored
  # Markdown — the dialect the agents write. In particular a list item's content
  # continues at the item's content column, so a table, a paragraph or a code
  # block indented three spaces under "1. " stays inside the item, the way GitHub
  # shows it.
  #
  # Raw HTML in the source is escaped rather than rendered, and links whose
  # scheme is not safe (javascript:, data: …) lose their href; both are
  # comrak's own `escape` and default (non-`unsafe`) rendering. Code is the one
  # thing rendered outside comrak: each code block and code span is swapped for a
  # placeholder token before rendering and for Rouge's output after, so the HTML
  # Zimmer injects never passes through comrak's raw-HTML path.
  class MarkdownRenderer
    OPTIONS = {
      parse: { smart: false },
      render: { hardbreaks: true, escape: true, unsafe: false },
      extension: {
        strikethrough: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true,
        shortcodes: true,
        # Off, though comrak has them: neither is GFM, and both pair up characters
        # agents write in prose — `O(n^2) vs O(n^3)` and `a==b && c==d`.
        superscript: false,
        highlight: false,
        header_ids: nil
      }
    }.freeze

    LINK_ATTRIBUTES = %( target="_blank" rel="noopener noreferrer").freeze

    def render(text)
      nonce = SecureRandom.hex(8)
      document = Commonmarker.parse(text, options: OPTIONS)
      code = swap_code_for_tokens(document, nonce)

      html = decorate(document.to_html(options: OPTIONS, plugins: { syntax_highlighter: nil }))
      html.gsub(%r{(<p>)?zmdblock#{nonce}n(\d+)z(</p>)?|zmdspan#{nonce}n(\d+)z}) do
        if $2
          # The token's paragraph is normally `<p>TOKEN</p>`, or bare in a tight
          # list. A footnote's back-reference can land inside it, after the token;
          # then the paragraph reopens for what follows.
          code.fetch($2.to_i) + ($1 && !$3 ? "<p>" : "")
        else
          code.fetch($4.to_i)
        end
      end
    end

    # Rouge-highlighted code block.
    def block_code(code, language)
      language = language.presence || "plaintext"
      lexer = Rouge::Lexer.find_fancy(language, code) || Rouge::Lexers::PlainText.new
      formatter = Rouge::Formatters::HTMLInline.new(Rouge::Themes::Monokai)
      formatted_code = formatter.format(lexer.lex(code))

      safe_tag = ERB::Util.html_escape(lexer.tag)
      safe_language = ERB::Util.html_escape(language)

      %(<pre class="highlight language-#{safe_tag}" data-language="#{safe_language}"><code>#{formatted_code}</code></pre>)
    end

    def codespan(code)
      %(<code class="inline-code">#{ERB::Util.html_escape(code)}</code>)
    end

    private

    # Replace every code block with a paragraph holding a block token, and every
    # code span with a text token, returning the HTML each token stands for. The
    # nonce keeps a token from being forged by the text itself.
    def swap_code_for_tokens(document, nonce)
      nodes = []
      document.walk { |node| nodes << node if node.type == :code_block || node.type == :code }

      nodes.each_with_index.map do |node, index|
        if node.type == :code && inside_image?(node)
          # An image's alt text is an attribute value, where HTML cannot go.
          node.replace(Commonmarker::Node.new(:text, content: node.string_content))
          nil
        elsif node.type == :code_block
          paragraph = Commonmarker::Node.new(:paragraph)
          paragraph.append_child(Commonmarker::Node.new(:text, content: "zmdblock#{nonce}n#{index}z"))
          node.replace(paragraph)
          block_code(node.string_content, node.fence_info.to_s.split.first)
        else
          html = codespan(node.string_content)
          node.replace(Commonmarker::Node.new(:text, content: "zmdspan#{nonce}n#{index}z"))
          html
        end
      end
    end

    def inside_image?(node)
      while (node = node.parent)
        return true if node.type == :image
      end
      false
    end

    # Classes and attributes the stylesheet and the link behaviour key on. Every
    # tag matched here was written by comrak: raw HTML in the source has already
    # been escaped, and the Rouge output is substituted only afterwards. A link
    # or image comrak emptied because its scheme was unsafe is left as its text,
    # so nothing clickable or fetchable is left behind.
    def decorate(html)
      html
        .gsub(%r{<a href=""(?: title="[^"]*")?>(.*?)</a>}m, '\\1')
        .gsub(%r{<img src="" alt="([^"]*)"(?: title="[^"]*")? />}, '\\1')
        .gsub("<table>", %(<div class="table-wrapper"><table class="markdown-table">))
        .gsub("</table>", "</table></div>")
        .gsub("<blockquote>", %(<blockquote class="markdown-blockquote">))
        .gsub(%r{<a href="([^"]*)"( title="[^"]*")?>}) { %(<a href="#{$1}"#{$2}#{LINK_ATTRIBUTES}>) }
    end
  end

  # Render markdown text as HTML with syntax highlighting (see MarkdownRenderer
  # for how raw HTML and unsafe links are kept out).
  # Rescues rendering errors so a single bad message never crashes the whole page
  def markdown(text)
    return "" if text.blank?

    markdown_parser.render(text).html_safe
  rescue => e
    Rails.logger.error("[markdown] Rendering failed: #{e.class}: #{e.message}")
    content_tag(:pre, text, class: "whitespace-pre-wrap text-sm text-gray-700")
  end

  # The inline elements `inline_markdown` keeps. Everything else — paragraphs,
  # headings, lists, tables, code blocks — is unwrapped to its text.
  INLINE_MARKDOWN_TAGS = %w[a code strong em del].freeze
  INLINE_MARKDOWN_ATTRIBUTES = %w[href target rel].freeze

  # Markdown for a one-line slot: a row on a list, where a <p>, a heading or a
  # code block would break the layout. Rendered by `markdown` — so links keep its
  # target="_blank" and its unsafe-scheme filtering — and then narrowed to
  # INLINE_MARKDOWN_TAGS, which a second sanitizer pass enforces even if the
  # renderer ever let something else through.
  def inline_markdown(text)
    return "" if text.blank?

    memoized_markdown(:inline, text) do
      sanitize(markdown(text), tags: INLINE_MARKDOWN_TAGS, attributes: INLINE_MARKDOWN_ATTRIBUTES)
    end.html_safe
  end

  # The same text with its markup gone, for a `title` attribute or anywhere else
  # that cannot hold HTML. Unescaped, because the attribute escapes it again.
  def markdown_plain_text(text)
    return "" if text.blank?

    memoized_markdown(:plain, text) do
      CGI.unescapeHTML(strip_tags(markdown(text))).squish
    end
  end

  # Results of the two conversions above, kept in this process.
  #
  # Each is a pure function of its text, and each costs about 2ms of Nokogiri
  # (`sanitize`, `strip_tags`) — against 0.03ms for the markdown itself. The User
  # view runs both on every row's status summary, so a few hundred rows spent
  # over a second on them, re-deriving the same answers on every page load.
  # Keyed on a digest of the text, so a summary that changes is simply a new key
  # and nothing has to be invalidated. Local memory rather than Rails.cache: a
  # hit has to cost less than the 4ms it saves, and a network round trip per row
  # would give a good part of that back. The size cap evicts least recently used.
  MARKDOWN_MEMO = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)

  def memoized_markdown(kind, text, &)
    MARKDOWN_MEMO.fetch("#{kind}:#{Digest::SHA256.hexdigest(text)}") { yield.to_str }
  end
  private :memoized_markdown

  # Persisted network-egress health for the global banner (see EgressHealthCheck).
  # Returns the status hash when egress is degraded, otherwise nil so the banner
  # renders nothing. Never raises — a cache hiccup must not break page rendering.
  def network_egress_alert
    status = EgressHealthCheck.status
    status if status && status["status"] == "degraded"
  end

  # Queue recovery mode's snapshot for the global banner, memoized for the
  # request so the layout and any panel on the page agree. Never raises — the
  # service already swallows read failures and returns an inactive status.
  def queue_recovery_mode_status
    @queue_recovery_mode_status ||= QueueRecoveryMode.status
  end

  # "42 min" / "3 min" / "under a minute" for the banner's auto-resume countdown.
  def queue_recovery_mode_countdown(status)
    seconds = status.expires_in
    return "unknown" if seconds.nil?
    return "under a minute" if seconds < 60

    "#{(seconds / 60.0).round} min"
  end

  # Format a stored iso8601 timestamp for the egress banner as "HH:MM UTC".
  # Tolerant of a malformed value so the banner never crashes on bad cache data.
  def egress_banner_time(iso8601)
    Time.iso8601(iso8601.to_s).utc.strftime("%H:%M UTC")
  rescue ArgumentError, TypeError
    nil
  end

  # When the broadcast circuit breaker is open, the time it is expected to close
  # — otherwise nil, so shared/_live_updates_paused_banner renders nothing.
  def live_updates_paused_until
    BroadcastService.paused_until
  end

  # "in about a minute" reads as vague hand-waving for a 60-second window, so say
  # the number of seconds while there are seconds worth saying.
  def live_updates_resume_phrase(resume_at, now: Time.current)
    seconds = (resume_at - now).round
    return "in a moment" if seconds <= 5

    "in about #{seconds} seconds"
  end

  # How long a flash toast stays on screen, in milliseconds, for the
  # `data-flash-duration-value` FlashController reads.
  #
  # A toast carrying an inline action holds an affordance the reader has to
  # decide about, so it outlives the timer a bare notice uses. The Undo toast's
  # lifetime is not a taste call at all: it is the server-side undo window
  # itself, so the button cannot still be on screen after the server has started
  # refusing it. That is what drifted in
  # [#1036](https://github.com/tadasant/zimmer/issues/1036) — the toast said 30
  # seconds, the controller accepted 5.
  #
  # `action` is the inline action parsed out of the flash message by
  # shared/_flash ("undo_archive", "force_archive", or nil).
  def flash_duration_ms(action)
    case action
    when "undo_archive"
      SessionStateMachine::UNDO_ARCHIVE_WINDOW.in_milliseconds
    when "force_archive"
      # "Archive anyway" behind a confirm dialog is not a five-second decision,
      # and nothing on the server expires while it is up.
      30_000
    else
      5_000
    end
  end

  private

  def markdown_parser
    @markdown_parser ||= MarkdownRenderer.new
  end
end
