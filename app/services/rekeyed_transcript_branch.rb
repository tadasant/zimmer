# frozen_string_literal: true

# What the stored transcript becomes when the file Zimmer is reading is a
# **re-keyed branch** of the session's conversation rather than the
# `<session_id>.jsonl` it recorded at spawn (#1047).
#
# `TranscriptFileLocator` decides *which* file to read and proves the branch
# belongs to this session. This decides what to do with what it holds, and the
# distinction that makes it necessary is that a branch is not a superset of what
# Zimmer stored: the copy was taken at a point in the conversation, and anything
# the abandoned file recorded after that point exists nowhere but
# `session.transcript`.
#
# Every writer of `sessions.transcript` that starts from a located file goes
# through here — the poller and all five manual-refresh paths (both controllers'
# `refresh`, `bulk_refresh`, and the `action_session` MCP tool's two). They share
# one guard, `Session.transcript_regression?`, and it compares line *counts*: a
# branch that is longer than the stored transcript but does not contain its tail
# passes that guard and takes the tail with it. So the merge has to happen before
# the write, at every one of them, or the one that skips it undoes the others.
class RekeyedTranscriptBranch
  class << self
    # The text to store, given what a located transcript file holds.
    #
    # Returns `content` untouched unless the located file is a re-keyed branch —
    # which is the answer for every ordinary session, and costs one filename
    # comparison to reach.
    #
    # @param session [Session]
    # @param transcript_path [String, nil] the located transcript file
    # @param content [String, nil] that file's decoded, redacted content
    # @param source [TranscriptSource, nil] the session's source, when the caller
    #   already has one
    # @return [String, nil] the text to store
    def continue(session:, transcript_path:, content:, source: nil)
      return content if content.blank?

      source ||= TranscriptRuntime.source_for(session)
      return content if source.rekeyed_branch_id(session: session, transcript_path: transcript_path).blank?

      splice(stored: session.transcript, branch: content)
    end

    # The stored transcript extended by everything `branch` adds to it.
    #
    # Recomputed from the two texts on every call rather than from a remembered
    # split point, which is what makes it safe to run on a partial read, after a
    # poll that failed to read the branch, and across a *second* re-key. A
    # remembered split point is wrong the moment the stored transcript stops being
    # prefix-shaped — which is exactly what the first splice does to it — and the
    # error compounds on each subsequent re-key.
    #
    # Three terms, in order:
    #
    #   H  the head the branch copied, shared with the stored transcript
    #   A  what the abandoned file recorded after the copy — stored only here
    #   T  the branch's own tail
    #
    # `stored` is `H + A` on the first call and `H + A + T` on every later one, so
    # the work is to find how much of `T` is already at the end of `stored` and
    # append only the rest.
    #
    # @param stored [String, Array, nil] `session.transcript`
    # @param branch [String] the branch's content
    # @return [String] the text to store; never shorter than `stored`
    def splice(stored:, branch:)
      # The legacy Array transcript format is not JSONL text, and slicing `.to_s`
      # of an Array would splice Ruby's inspect output into the stored transcript.
      # #carryover_prefix bails on one for the same reason.
      return branch if stored.is_a?(Array)

      stored_text = stored.to_s
      # A trailing line with no newline is a read taken mid-flush. Comparing it
      # would find a mismatch the branch is about to resolve on its own, so it is
      # dropped here and re-supplied from the branch.
      complete = complete_lines(stored_text)
      return branch if complete.blank?
      # The ordinary re-key: the branch copied the whole file, so it already is
      # everything Zimmer has. One comparison, no line surgery.
      return branch if branch.start_with?(complete)

      stored_lines = complete.lines
      branch_lines = branch.lines
      tail = branch_lines.drop(common_prefix_count(stored_lines, branch_lines))
      return stored_text if tail.empty?

      overlap = trailing_overlap_count(stored_lines, tail)
      (stored_lines.first(stored_lines.length - overlap) + tail).join
    end

    private

    # `text` up to and including its last newline; "" when it has none.
    def complete_lines(text)
      return text if text.empty? || text.end_with?("\n")

      last_newline = text.rindex("\n")
      last_newline ? text[0, last_newline + 1] : ""
    end

    # How many leading lines the two share verbatim.
    def common_prefix_count(left, right)
      limit = [ left.length, right.length ].min

      count = 0
      count += 1 while count < limit && left[count] == right[count]
      count
    end

    # The largest m for which the LAST m lines of `lines` are the FIRST m of
    # `tail` — i.e. how much of the branch's tail the stored transcript already
    # carries.
    #
    # Anchored on `tail.first` and scanned from the earliest position it could
    # occupy, so the first anchor hit is the largest answer. A transcript line
    # carries its own uuid and timestamp, so in practice there is at most one hit
    # and this is a single pass.
    def trailing_overlap_count(lines, tail)
      return 0 if lines.empty? || tail.empty?

      anchor = tail.first
      earliest = lines.length - [ lines.length, tail.length ].min

      (earliest...lines.length).each do |i|
        next unless lines[i] == anchor

        length = lines.length - i
        return length if lines[i, length] == tail[0, length]
      end

      0
    end
  end
end
