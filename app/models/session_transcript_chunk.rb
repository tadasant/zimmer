# frozen_string_literal: true

# One slice of a session's JSONL transcript.
#
# Concatenating every chunk of a session in `seq` order reproduces the transcript
# byte for byte. That is the whole contract — a chunk carries no semantics of its
# own, it is a storage unit — and it is what lets the poller record ten new lines
# by writing ten new lines instead of rewriting the whole conversation (#110).
#
# TWO INVARIANTS THE WRITER MAINTAINS, both relied on elsewhere:
#
#   1. **Every chunk except the last ends with a newline.** Chunk boundaries are
#      chosen at line breaks, never mid-event. `SessionContentSearch` matches
#      `content ILIKE` per chunk, so a boundary inside a JSON event would make a
#      phrase silently unfindable; a boundary between events cannot, because a
#      phrase spanning two events is not a phrase anybody typed.
#   2. **`line_count` sums to the document's line count.** `Session.transcript_line_count`
#      counts newlines and adds one for an unterminated final line; because only the
#      last chunk may lack its terminator, applying the same rule per chunk and
#      summing gives exactly that number. This is what makes the regression guard a
#      column read instead of a multi-megabyte detoast.
#
# Chunks are never rewritten except for the open tail (below `TARGET_BYTES`, or
# not yet terminated), which is what bounds the cost of an append.
class SessionTranscriptChunk < ApplicationRecord
  belongs_to :session

  # How large a chunk is allowed to get before the writer starts a new one.
  #
  # This is the knob that trades write amplification against row count. An append
  # rewrites at most one chunk, so the worst-case write is ~TARGET_BYTES rather
  # than the whole transcript: at 256 KiB, a 32 MB transcript — the size #477
  # measures on a real production session — costs 128 rows and a rewrite two
  # orders of magnitude smaller than the column it replaces. Smaller chunks would
  # shrink the rewrite further and grow the row count that every full read has to
  # reassemble; 256 KiB keeps both unremarkable.
  TARGET_BYTES = 256 * 1024

  validates :seq, presence: true, uniqueness: { scope: :session_id }
  validates :content, presence: true

  # Where a run of bytes may be cut so the piece ends at a line break.
  #
  # Returns a byte offset into +bytes+ (which must be ASCII-8BIT, so offsets are
  # byte offsets rather than character offsets). Prefers the last newline at or
  # before +want+; when the window holds no newline at all — one enormous JSON
  # event — it runs past +want+ to the next one rather than splitting the line,
  # because invariant 1 above is worth more than a chunk of exactly the target
  # size. Returns the whole length when there is no newline left to cut at.
  def self.split_point(bytes, want)
    size = bytes.bytesize
    return size if size <= want

    if want.positive?
      boundary = bytes.rindex("\n", want - 1)
      return boundary + 1 if boundary
    end

    boundary = bytes.index("\n", [ want, 0 ].max)
    boundary ? boundary + 1 : size
  end

  # The line count of a chunk, under the rule in invariant 2 above.
  def self.line_count_for(content)
    return 0 if content.empty?

    content.count("\n") + (content.end_with?("\n") ? 0 : 1)
  end

  # Cut +content+ into chunk rows ready for `insert_all!`, numbered from +first_seq+.
  #
  # The one place the cutting rule lives, so the append path and
  # `BackfillSessionTranscriptChunks` cannot drift into producing different chunk
  # sets for the same bytes.
  def self.rows_for(session_id:, content:, first_seq: 0, now: Time.current)
    remaining = content.dup.force_encoding(Encoding::BINARY)
    seq = first_seq
    rows = []

    while remaining.bytesize.positive?
      taken = split_point(remaining, TARGET_BYTES)
      piece = remaining.byteslice(0, taken).force_encoding(Encoding::UTF_8)
      rows << {
        session_id: session_id, seq: seq, content: piece, byte_size: piece.bytesize,
        line_count: line_count_for(piece), created_at: now, updated_at: now
      }
      seq += 1
      remaining = remaining.byteslice(taken, remaining.bytesize - taken).to_s
    end

    rows
  end

  # True while this chunk is still allowed to absorb an append: either it has room
  # left, or it ends mid-line and MUST absorb one to restore invariant 1.
  def open?
    byte_size < TARGET_BYTES || !content.end_with?("\n")
  end
end
