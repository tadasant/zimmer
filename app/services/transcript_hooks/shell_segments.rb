require "strscan"

# Reading a tool call's shell command as the several commands it usually is.
#
# A `Bash` tool call (or a Codex argv joined back into one) is a whole shell
# script, not one invocation: `gh api A && gh api B`, a retry loop, a `cd x &&`
# prefix, an assignment capturing output. The hooks that classify what a session's
# `gh` commands *did* therefore have to classify per command, because matching
# against the whole string lets one command borrow another's flags —
# `gh api repos/o/r/pulls --jq '.[]' && gh api repos/o/r/issues/1/comments -X POST`
# reads as a POST to `/pulls`, which is a session adopting every PR it listed
# (#214).
#
# Two things are on offer, and they answer different questions. #shell_segments
# answers "which commands are these", and #unquoted answers "what does this
# command *run*, as opposed to what was it handed as data" — `gh pr create` inside
# a `grep` pattern being the case that made the difference matter (#772).
#
# Neither is a shell parser, and the split is crude on purpose. It errs toward
# *more* segments, which is the safe direction for both callers: a mis-split
# loses a recording rather than manufacturing one. Two rules keep it from
# splitting a command that only looks like several:
#
#   - A separator that is escaped, or inside a quoted string, is not a separator.
#     `grep -n "def \|pull/\|gh pr create\|..." hook.rb` is one command, and
#     cutting it at the pipes of its own grep pattern manufactures a segment that
#     begins `gh pr create` out of a read-only grep.
#   - Quoting is read one line at a time, and an unclosed quote falls back to the
#     plain split. A stray apostrophe is ordinary in a shell comment or a heredoc
#     body ("It's ready"), and two of them would otherwise re-balance across the
#     lines between them and swallow whatever they enclose — including a real
#     `gh pr create` on its own line.
#
# Used by TranscriptHooks::GithubPrUrlHook and
# TranscriptHooks::GithubCommentAuthorshipHook, which share the shape but not the
# classification: one looks for a create against a `/pulls` collection, the other
# for a write against a comments endpoint.
module TranscriptHooks::ShellSegments
  # Shell separators a command is split on before classification.
  SEGMENT_SEPARATOR = /(?:&&|\|\||[;|\n])/

  # The quotes that turn a separator into data. Which one opened the run matters:
  # an apostrophe inside a double-quoted string is a literal apostrophe, and a
  # backslash inside a single-quoted string is a literal backslash.
  QUOTE_CHARACTERS = [ '"', "'" ].freeze

  # A backslash and whatever it escapes, taken as one unit so that the `\|` of a
  # `grep` pattern is not read as a pipe.
  ESCAPED_CHARACTER_PATTERN = /\\./m

  # A run of characters that can change nothing about the scan — no quote, no
  # escape, no separator. Consumed in one go so the walk below is a handful of
  # C-level scans per line rather than a Ruby iteration per character.
  PLAIN_RUN_PATTERN = /[^\\"';|&\n]+/

  # A quoted string, and only a *closed* one. What a command quotes is what it was
  # handed rather than what it runs, so #unquoted takes these out — but an
  # unterminated quote is left alone, because that is what a stripped wrapper
  # leaves behind: `bash -lc "cd x && gh pr create"` arrives with its opening quote
  # already gone (SHELL_WRAPPER_PATTERN), and what trails is a script, not data.
  QUOTED_SPAN_PATTERN = /"(?:\\.|[^"\\])*"|'[^']*'/m

  # A backslash-newline is one command wrapped over several lines, so it is folded
  # back into that command rather than splitting it — otherwise a `gh api` and the
  # flags continued underneath it land in different segments and neither means
  # anything.
  LINE_CONTINUATION_PATTERN = /\\\n/

  # `out=$(gh api ...)`, `$(gh api ...)`, `` `gh api ...` ``: a command whose output
  # is being captured is still that command. Stripped before the environment
  # prefix, because the assignment here ends in an opener rather than a value.
  CAPTURE_PREFIX_PATTERN = /\A\s*(?:[A-Za-z_][A-Za-z0-9_]*=)?(?:\$\(|\(|`)\s*/

  # Environment assignments: the `cd x &&` shape is already handled by the split,
  # this strips leading whitespace and `FOO=bar` prefixes so a segment like
  # `GH_TOKEN=x gh api ...` still starts with `gh api`.
  ENV_PREFIX_PATTERN = /\A(?:\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*/

  # `bash -lc <script>`, `sh -c <script>`: Codex records a shell call as an argv
  # array which the parser joins back into one string, so this wrapper is the front
  # of every Codex command. Stripped so what the script runs sits at the front,
  # exactly as it does in a Claude `Bash` command.
  SHELL_WRAPPER_PATTERN = %r{\A(?:\S*/)?(?:ba|da|z|k)?sh\s+-[a-z]*c\s+["']?}

  # The keyword of a compound statement, which sits in front of the command it
  # runs on the same line: `for i in 1 2 3; do gh api ...`, `if ...; then gh api`.
  # Stripped for the sake of the callers that read the *front* of a segment —
  # GithubPrUrlHook's and GithubCommentAuthorshipHook's `\Agh\s+api\b`.
  KEYWORD_PREFIX_PATTERN = /\A\s*(?:do|then|else)\s+/

  # The commands in +command+, each normalized so that the invocation it runs is at
  # the front of the string and callers can anchor their patterns there. The
  # prefixes are stripped in the order they nest — a compound-statement keyword
  # around a capture around a wrapper around an environment assignment — and the
  # environment strip runs on both sides of the wrapper, since either can come
  # first.
  #
  # @param command [String]
  # @return [Array<String>]
  def shell_segments(command)
    script = command.to_s.gsub(LINE_CONTINUATION_PATTERN, " ")

    script.split("\n").flat_map { |line| split_line(line) }.filter_map do |segment|
      normalized = segment.sub(KEYWORD_PREFIX_PATTERN, "")
                          .sub(CAPTURE_PREFIX_PATTERN, "")
                          .sub(ENV_PREFIX_PATTERN, "")
                          .sub(SHELL_WRAPPER_PATTERN, "")
                          .sub(ENV_PREFIX_PATTERN, "")
                          .strip

      normalized unless normalized.empty?
    end
  end

  # +segment+ with every closed quoted string blanked out: what the command runs,
  # with what it was handed removed. `grep -n "gh pr create" hook.rb` runs a grep
  # and nothing else, however much its argument reads like an invocation.
  #
  # Blanked rather than deleted, so that neighbouring words cannot be run together
  # into something neither of them said.
  #
  # @param segment [String]
  # @return [String]
  def unquoted(segment)
    segment.gsub(QUOTED_SPAN_PATTERN, " ")
  end

  private

  # One line of a script, split on the separators a shell would act on and skipping
  # the ones it would read as data: a backslash-escaped character, and anything
  # between quotes.
  #
  # Returns the plain split when the line ends inside an unclosed quote — the
  # quoting did not resolve, so the crude reading is the one to trust. Quote state
  # never leaves the line for the same reason (see the module header).
  #
  # @param line [String]
  # @return [Array<String>]
  def split_line(line)
    scanner = StringScanner.new(line)
    segments = []
    current = +""
    quote = nil

    until scanner.eos?
      if (plain = scanner.scan(PLAIN_RUN_PATTERN))
        current << plain
      elsif quote != "'" && (escaped = scanner.scan(ESCAPED_CHARACTER_PATTERN))
        current << escaped
      elsif quote.nil? && scanner.scan(SEGMENT_SEPARATOR)
        segments << current
        current = +""
      else
        character = scanner.getch

        if quote.nil? && QUOTE_CHARACTERS.include?(character)
          quote = character
        elsif quote == character
          quote = nil
        end

        current << character
      end
    end

    return line.split(SEGMENT_SEPARATOR) if quote

    segments << current
  end
end
