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
# The split is crude: it does not understand quoting, and it errs toward *more*
# segments. That is the safe direction for both callers here — a mis-split loses a
# recording rather than manufacturing one.
#
# Used by TranscriptHooks::GithubPrUrlHook and
# TranscriptHooks::GithubCommentAuthorshipHook, which share the shape but not the
# classification: one looks for a create against a `/pulls` collection, the other
# for a write against a comments endpoint.
module TranscriptHooks::ShellSegments
  # Shell separators a command is split on before classification.
  SEGMENT_SEPARATOR = /(?:&&|\|\||[;|\n])/

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

  # The commands in +command+, each normalized so that the invocation it runs is at
  # the front of the string and callers can anchor their patterns there. The
  # prefixes are stripped in the order they nest — a capture around a wrapper
  # around an environment assignment — and the environment strip runs on both
  # sides of the wrapper, since either can come first.
  #
  # @param command [String]
  # @return [Array<String>]
  def shell_segments(command)
    command.to_s
           .gsub(LINE_CONTINUATION_PATTERN, " ")
           .split(SEGMENT_SEPARATOR)
           .map do |segment|
             segment.sub(CAPTURE_PREFIX_PATTERN, "")
                    .sub(ENV_PREFIX_PATTERN, "")
                    .sub(SHELL_WRAPPER_PATTERN, "")
                    .sub(ENV_PREFIX_PATTERN, "")
                    .strip
           end
  end
end
