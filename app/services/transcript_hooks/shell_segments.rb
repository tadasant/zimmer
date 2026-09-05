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
# A heredoc body is the one place where lines that are not shell arrive *as*
# lines, so it is the one place a line is dropped rather than split: `python3 -
# <<'PY' … PY` feeds its body to Python, and a `gh pr create` literal in there is
# a Python string (#873). Dropping is the direction that can lose a real create,
# so the reading gives up rather than guesses — a delimiter it cannot find a
# terminator for leaves the whole rest of the script read as shell, because a
# body assumed to run to end-of-input would swallow every command after it and
# switch the session's GitHub integration off in silence (#89).
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
  # handed rather than what it runs, so #unquoted takes these out — but a quote
  # with no partner is not a span, and blanking to the end of the line on the
  # strength of one would delete a command over a stray apostrophe.
  QUOTED_SPAN_PATTERN = /"(?:\\.|[^"\\])*"|'[^']*'/m

  # A run of three or more of the same quote character, which is not a pair of
  # anything. Python's `"""` is the spelling that turns up in transcripts, and
  # pairing through it takes the first two as an empty string and hands the third
  # to the next quote further along — so everything between them, `gh pr create`
  # included, falls outside every quoted span and reads as a command being run
  # (#873).
  #
  # Taken ahead of QUOTED_SPAN_PATTERN and left exactly as written, so pairing
  # resumes *after* the run rather than through it. A triple quote is ambiguous
  # (three quotes to a shell, one delimiter to Python) and this is the cheaper
  # side of it to be wrong on: the run itself stays visible, so a create sitting
  # unquoted next to one is still read as a create.
  QUOTE_RUN_PATTERN = /"{3,}|'{3,}/

  # A Python triple-quoted string, which is what a run of three quotes opens
  # almost every time one turns up in a transcript. Taken ahead of the bare run so
  # that a *closed* one is blanked like any other string — `python3 -c """import
  # x; gh pr create"""` hands Python a string, whatever a shell would make of the
  # same characters. It has to see its own closing run, so unlike a lone quote it
  # cannot blank away to the end of the segment; an unclosed one falls through to
  # QUOTE_RUN_PATTERN.
  TRIPLE_QUOTED_SPAN_PATTERN = /"""(?:(?!""").)*"""|'''(?:(?!''').)*'''/

  # The spans #unquoted walks, in the order it tries them.
  UNQUOTED_SPAN_PATTERN = Regexp.union(TRIPLE_QUOTED_SPAN_PATTERN, QUOTE_RUN_PATTERN, QUOTED_SPAN_PATTERN)

  # A span that is nothing but a quote run, which #unquoted keeps rather than
  # blanks.
  ENTIRE_QUOTE_RUN_PATTERN = /\A(?:#{QUOTE_RUN_PATTERN})\z/

  # A heredoc redirection: `<<DELIM`, `<<-DELIM`, and the quoted spellings
  # `<<'DELIM'`, `<<"DELIM"` and `<<\DELIM`. Everything on the lines after the one
  # carrying it, up to its terminator, is data handed to another program rather
  # than commands the shell runs.
  #
  # `<<<` is a here-*string* and has no body, so it is excluded by the lookbehind
  # and by requiring the delimiter to start on a word character — which also keeps
  # the `$(( a << 2 ))` shift out. That same requirement means an exotic delimiter
  # goes unrecognised and its body is read as shell, which is the direction that
  # cannot lose a real create.
  #
  # `<<-` needs no separate treatment here: it differs only in allowing a
  # tab-indented terminator, and #heredoc_body_end allows leading whitespace on
  # the terminator of every form (see there for why the lax reading is the safe
  # one).
  HEREDOC_OPERATOR_PATTERN = /(?<!<)<<-?[ \t]*(?<delimiter>'[A-Za-z_]\w*'|"[A-Za-z_]\w*"|\\?[A-Za-z_]\w*)/

  # The quoting a heredoc delimiter may be written with, which is the redirection's
  # syntax rather than part of the delimiter. `<<'PY'` and `<<PY` end on the same
  # `PY` line; the quotes only decide whether the body is expanded.
  HEREDOC_DELIMITER_QUOTING = /\A[\\'"]|['"]\z/

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

  # A command handed a *script* rather than data: a shell's `-c` — which is the
  # front of every joined Codex argv — and `eval`. What follows is more commands,
  # so it is split again rather than kept whole. `bash -lc "gh api A --paginate &&
  # rm -f x"` is two commands, and reading it as one lets `rm`'s flags vouch for
  # the read in front of them, which is #214 with the whole thread's comments.
  #
  # The shell form is recognised wherever it appears, because a wrapper sits behind
  # the same things any other command does — `timeout 120 bash -lc "..."`,
  # `xargs -I{} sh -c "..."`. `eval` only in command position, since it is also an
  # ordinary English word that could sit in an argument.
  WRAPPED_SCRIPT_PATTERN = %r{(?:\A\s*eval|(?:\A|\s)(?:\S*/)?(?:ba|da|z|k)?sh\s+-[a-z]*c)\s(?<script>.+)\z}m

  # The keyword of a compound statement, which sits in front of the command it
  # runs on the same line: `for i in 1 2 3; do gh api ...`, `if ...; then gh api`.
  # Stripped for the sake of the callers that read the *front* of a segment —
  # GithubPrUrlHook's and GithubCommentAuthorshipHook's `\Agh\s+api\b`.
  KEYWORD_PREFIX_PATTERN = /\A\s*(?:do|then|else)\s+/

  # The commands in +command+, each normalized so that the invocation it runs is at
  # the front of the string and callers can anchor their patterns there. The
  # prefixes are stripped in the order they nest — a compound-statement keyword
  # around a capture around an environment assignment — and a command that was
  # handed a script runs that script through the whole of this again.
  #
  # @param command [String]
  # @return [Array<String>]
  def shell_segments(command)
    split_script(command.to_s.gsub(LINE_CONTINUATION_PATTERN, " "))
  end

  # +segment+ with every closed quoted string blanked out: what the command runs,
  # with what it was handed removed. `grep -n "gh pr create" hook.rb` runs a grep
  # and nothing else, however much its argument reads like an invocation.
  #
  # Blanked to spaces rather than deleted, so that neighbouring words cannot be run
  # together into something neither of them said — and so that a position in the
  # result is a position in +segment+, which is how a wrapper is told from the
  # mention of one.
  #
  # A run of three or more quotes is not a pair and is left as written, so pairing
  # picks up after it (see QUOTE_RUN_PATTERN).
  #
  # @param segment [String]
  # @return [String]
  def unquoted(segment)
    segment.to_s.gsub(UNQUOTED_SPAN_PATTERN) do |span|
      span.match?(ENTIRE_QUOTE_RUN_PATTERN) ? span : " " * span.length
    end
  end

  private

  # +script+ as the commands it runs: split into the lines a shell would *run*,
  # each line into segments, each segment normalized — and where a segment hands a
  # script to a shell, that script split the same way in place of it.
  #
  # The recursion terminates on its own: a wrapped script is what follows the
  # wrapper, so each round is strictly shorter than the one before it.
  #
  # @param script [String]
  # @return [Array<String>]
  def split_script(script)
    shell_lines(script).flat_map { |line| split_line(line) }.flat_map do |segment|
      normalized = segment.sub(KEYWORD_PREFIX_PATTERN, "")
                          .sub(CAPTURE_PREFIX_PATTERN, "")
                          .sub(ENV_PREFIX_PATTERN, "")
                          .strip

      if (wrapped = wrapped_script(normalized))
        split_script(wrapped)
      elsif normalized.empty?
        []
      else
        [ normalized ]
      end
    end
  end

  # +script+'s lines with every heredoc body dropped: the lines a shell would run,
  # without the ones it feeds to something else.
  #
  # A body is dropped rather than blanked because a line of it is not a command in
  # any reading — `python3 - <<'PY'` hands its body to Python, and a `gh pr create`
  # literal in a Python string is a string. The redirection's *own* line is kept:
  # it is a command, it may carry several heredocs, and it may have run something
  # else before them (`cat <<EOF > f && gh pr create --fill`).
  #
  # Gives up rather than guesses. A delimiter whose terminator is nowhere in what
  # follows — a truncated transcript, a terminator written in a shape this does not
  # recognise — ends the heredoc reading for the whole script, and everything from
  # the body onward is read as shell. A body assumed to run to end-of-input instead
  # would swallow every command after it, so a real `gh pr create` would be
  # recorded nowhere and every GitHub integration for that session would silently
  # stop (#89). Reading a body as shell costs a false positive of the kind #873 is
  # about; reading a command as a body costs the integration.
  #
  # @param script [String]
  # @return [Array<String>]
  def shell_lines(script)
    lines = script.split("\n")
    return lines unless script.include?("<<")

    kept = []
    index = 0

    while index < lines.length
      line = lines[index]
      kept << line
      index += 1

      delimiters = heredoc_delimiters(line)
      next if delimiters.empty?

      body_end = heredoc_body_end(lines, index, delimiters)

      if body_end.nil?
        kept.concat(lines[index..] || [])
        break
      end

      index = body_end
    end

    kept
  end

  # The heredoc delimiters +line+ opens, in the order their bodies follow it.
  #
  # Read off the line as written, but only where the `<<` survives into the
  # #unquoted view — `<<'PY'` quotes its *delimiter*, which the unquoted view
  # blanks, while `echo "cat <<EOF"` quotes the redirection itself, which is a
  # mention rather than one. The views share offsets, so which of the two it is can
  # be read off the position.
  #
  # @param line [String]
  # @return [Array<String>]
  def heredoc_delimiters(line)
    runs = unquoted(line)
    delimiters = []

    line.scan(HEREDOC_OPERATOR_PATTERN) do
      match = Regexp.last_match
      next unless runs[match.begin(0), 2] == "<<"

      delimiters << match[:delimiter].gsub(HEREDOC_DELIMITER_QUOTING, "")
    end

    delimiters
  end

  # The index of the first line after the bodies of +delimiters+, or nil if any of
  # their terminators is missing.
  #
  # A terminator is matched with surrounding whitespace allowed, for every form
  # rather than only `<<-`, and with a carriage return counting as whitespace so a
  # CRLF transcript still ends its bodies. That is deliberately looser than a
  # shell: a lax terminator can only end a body *earlier* than the real one, which
  # leaves body lines read as shell — the harmless direction — where a strict one
  # that walked past the real terminator would keep swallowing until it found
  # another, taking real commands with it.
  #
  # @param lines [Array<String>]
  # @param start [Integer] the first body line
  # @param delimiters [Array<String>]
  # @return [Integer, nil]
  def heredoc_body_end(lines, start, delimiters)
    index = start

    delimiters.each do |delimiter|
      terminator = /\A\s*#{Regexp.escape(delimiter)}\s*\z/
      found = (index...lines.length).find { |i| lines[i].match?(terminator) }
      return nil if found.nil?

      index = found + 1
    end

    index
  end

  # The script +segment+ hands a shell to run, or nil if it hands one nothing.
  #
  # Located in the #unquoted view so that a wrapper *named* inside a quoted string
  # is not mistaken for one being run: `echo "bash -c gh pr create"` runs an echo.
  # That view preserves offsets, so where the script starts there is where it
  # starts here.
  #
  # @param segment [String]
  # @return [String, nil]
  def wrapped_script(segment)
    match = unquoted(segment).match(WRAPPED_SCRIPT_PATTERN)
    return nil unless match

    unwrap(segment[match.begin(:script)..].to_s)
  end

  # A wrapped script without the quotes that held it, which are the wrapper's
  # syntax rather than the script's.
  #
  # @param script [String]
  # @return [String]
  def unwrap(script)
    stripped = script.strip
    quote = QUOTE_CHARACTERS.find { |candidate| stripped.start_with?(candidate) }
    return stripped unless quote

    stripped.delete_prefix(quote).delete_suffix(quote)
  end

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
