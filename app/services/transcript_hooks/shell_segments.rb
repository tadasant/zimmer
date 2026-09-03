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
# The split is crude — it is not a shell parser — but it does know the difference
# between a separator and a separator's *characters* appearing inside data. A
# separator that is escaped, or inside a quoted string, is not a separator:
# `grep -n "def \|pull/\|gh pr create\|..." hook.rb` is one command, and splitting
# it at the pipes of its own grep pattern manufactures a segment that starts with
# `gh pr create` out of a read-only grep (#772).
#
# Where the quoting cannot be resolved — the scan ends inside an unclosed quote,
# which a heredoc body carrying an apostrophe is the usual way to produce — the
# plain split is used instead. Over-splitting is the safer of the two readings:
# it loses a recording, where a wrong merge would bury a real invocation behind
# whatever command sits in front of it.
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
  # C-level scans per command rather than a Ruby iteration per character.
  PLAIN_RUN_PATTERN = /[^\\"';|&\n]+/

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
  # runs: `for i in 1 2 3; do gh pr create --fill; done`, `if ...; then gh api ...`.
  # The split leaves it at the front of the segment, where it would hide the
  # invocation from a caller anchoring at the start of the string. `done` and
  # `docker` are untouched — the keyword has to be followed by whitespace.
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
    split_commands(command.to_s.gsub(LINE_CONTINUATION_PATTERN, " "))
      .map do |segment|
        segment.sub(KEYWORD_PREFIX_PATTERN, "")
               .sub(CAPTURE_PREFIX_PATTERN, "")
               .sub(ENV_PREFIX_PATTERN, "")
               .sub(SHELL_WRAPPER_PATTERN, "")
               .sub(ENV_PREFIX_PATTERN, "")
               .strip
      end
  end

  private

  # +script+ split on the separators a shell would act on, skipping the ones it
  # would read as data: a backslash-escaped character, and anything between quotes.
  #
  # Returns the plain split when the walk ends inside an unclosed quote — the
  # quoting did not resolve, so the crude reading is the one to trust (see the
  # module header).
  #
  # @param script [String]
  # @return [Array<String>]
  def split_commands(script)
    scanner = StringScanner.new(script)
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

    return script.split(SEGMENT_SEPARATOR) if quote

    segments << current
  end
end
