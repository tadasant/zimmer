# frozen_string_literal: true

require "digest"

# Incremental secret redaction for transcript files.
#
# ## Why this exists
#
# `TranscriptSource#read` redacts a transcript every time it is read, and the
# poller reads it every few seconds for as long as the session lives. Redaction
# costs ~245 ms per megabyte, so a 32 MB transcript burned ~7.6 s of CPU per poll
# to re-derive a result byte-identical to the last poll's for everything but the
# few kilobytes the agent appended. The cost tracked session *length* rather than
# session *activity*, and with several long sessions alive at once it was the
# poller's dominant expense (#477).
#
# This class keeps the already-redacted prefix of each transcript, so a poll pays
# only for the bytes that are new.
#
# ## Why that is exactly equivalent to a full re-scan
#
# Splitting the text at a **newline** and redacting the two halves separately
# produces the same bytes as redacting the whole, because every stage of
# `TranscriptRedactor.redact` is line-decomposable:
#
#   * **`scrub`** — a UTF-8 sequence never contains a `\n` byte (continuation
#     bytes are >= 0x80), so no codepoint, valid or invalid, straddles the cut.
#   * **The known-secret pass** — exact string matches, and `redactable?` admits
#     only values matching `\A\S+\z`. A known secret therefore cannot contain a
#     newline and cannot span the cut.
#   * **The 23 `PATTERNS`** — audited one by one: none carries `/m`, none uses
#     `.` at all, and every value or gap class either excludes `\s` or is an
#     explicit `[ \t]`. No pattern can match across a newline. This is the same
#     invariant the redactor's line-count guarantee and its line-by-line
#     degradation path already rest on.
#   * **`preceded_by`** — looks back at most `PRECEDING_WINDOW` bytes, but the
#     window regexps contain no newline-matching character and are `\z`-anchored,
#     so any match they can make lies entirely after the last newline before the
#     candidate. Cutting at a line start cannot change their answer.
#   * **The multi-line PEM walk** — the one stage that *is* cross-line, and the
#     reason the commit point is not simply "the last newline". See below.
#
# `scan_patterns`' timeout degradation does not disturb that. A whole-text
# timeout makes it retry line by line, and a per-line retry finds exactly what
# the whole-text pass would have found — the only line whose output differs is
# one that times out on its own, and whether that happens is a property of the
# line, not of how much text was handed to the pass with it.
#
# ## The one cross-line stage
#
# `redact_armored_private_keys` armors the lines between a `-----BEGIN … PRIVATE
# KEY-----` and its matching `-----END`, which spans newlines by construction. A
# block that opened in the committed prefix and closed in the tail would be
# armored by a full scan and missed by a naive incremental one — a redaction that
# silently stops redacting, which is worse than a slow one.
#
# So the commit point never crosses a line that could OPEN such a block
# (`TranscriptRedactor.private_key_block_start`). The committed prefix contains no
# opener, therefore no block can start in it, therefore no block can straddle the
# cut. A transcript carrying multi-line PEM armor simply stops advancing its
# commit point and re-scans from the opener on every poll — never worse than the
# old behavior, which re-scanned everything.
#
# (The escaped-in-JSON form of a PEM, which opens and closes on one line, is a
# `PATTERNS` entry rather than a block, so it stalls nothing. JSONL transcripts
# carry that form, not armor.)
#
# ## What can and cannot go wrong when the append assumption breaks
#
# Transcripts are append-only in the normal case, but not always: a file can be
# truncated, rotated (Codex writes a new rollout), replaced by a new session
# reusing a path, or rewritten by
# `AgentSessionJob#restore_regressed_transcript_if_needed`. `#reusable?` rejects
# all of those and falls back to a full re-scan.
#
# Worth being precise about what it guards, because a stale prefix is *not* a
# leak: the cached prefix is itself redactor output, so re-emitting one would
# produce a wrong transcript, never an unredacted one. The only way an
# incremental scan can UNDER-redact is if the tail begins mid-line, which is why
# the boundary is re-asserted to be a newline in the content actually being read
# (`#reusable?`, check 2) rather than merely trusted from last time.
class TranscriptRedactionCache
  # Below this a full re-scan is already cheap (~16 ms) and an entry is worth
  # neither the memory nor the fingerprinting.
  MIN_CACHEABLE_BYTES = 64 * 1024

  # A single transcript larger than this is not cached: one entry must not be
  # able to evict every other entry to make room for itself.
  MAX_ENTRY_BYTES = 64 * 1024 * 1024

  # The ceiling on everything this cache holds, process-wide. The trade it makes
  # is roughly one extra copy of each hot transcript in memory; this is the
  # number that bounds "roughly". Past it the least-recently-read entry is
  # dropped and that transcript goes back to costing a full re-scan.
  MAX_TOTAL_BYTES = 128 * 1024 * 1024

  # A hard cap on entry count, so a fleet of small-but-cacheable transcripts
  # cannot grow the table without bound underneath the byte ceiling.
  MAX_ENTRIES = 64

  # An entry not read for this long belongs to a session that has ended. Swept
  # on write rather than by a timer.
  MAX_IDLE_SECONDS = 900

  # How many bytes at the start of the file, and how many immediately before the
  # commit point, are fingerprinted to confirm this is still the same stream of
  # bytes. Bounded on purpose: the check is O(1) in transcript size, which is the
  # whole point of the change.
  FINGERPRINT_WINDOW = 16 * 1024

  # Chunks are joined on every read, so they are compacted once the array is long
  # enough for the join's per-chunk overhead to matter.
  MAX_CHUNKS = 256

  NEWLINE = "\n"
  NEWLINE_BYTE = 10

  # One cached transcript.
  #
  # `chunks` holds the redacted committed prefix in pieces, so appending a poll's
  # worth of output does not copy the whole prefix; the pieces are joined to
  # answer a read. `raw_committed_size` counts RAW bytes (what the caller hands
  # us), which is not the same number as the redacted prefix's size.
  Entry = Struct.new(
    :chunks,
    :chunk_bytes,
    :raw_committed_size,
    :head_digest,
    :boundary_digest,
    :touched_at,
    keyword_init: true
  )

  MUTEX = Mutex.new

  class << self
    # Redact `content`, reusing the previously redacted prefix of `path` when
    # this content is an append to what was read last time.
    #
    # @param path [String] the transcript path, used as the cache key
    # @param content [String, nil] the raw bytes just read from that path
    # @return [String, nil] byte-identical to `TranscriptRedactor.redact(content)`
    def redact(path, content)
      # Scrubbed here rather than left to the redactor, which scrubs as its own
      # first act anyway. The cache does byte bookkeeping — newline counting,
      # newline searching, fingerprinting — and `String#count` and `String#match?`
      # both raise `ArgumentError` on a broken byte sequence. Scrubbing up front
      # means every offset this class records refers to the same bytes the
      # redactor will see, and an agent that `cat`s a binary file does not cost
      # its session the cache for the rest of its life. Scrubbing is itself
      # line-decomposable: a UTF-8 sequence never contains a `\n` byte, so no
      # invalid run can straddle a commit point.
      content = content.scrub("") if content.is_a?(String) && !content.valid_encoding?
      return TranscriptRedactor.redact(content) unless cacheable?(path, content)

      entry = checkout(path)
      return redact_fully(path, content) unless entry && reusable?(entry, content)

      pending = content.byteslice(entry.raw_committed_size, content.bytesize - entry.raw_committed_size)
      return entry.chunks.join if pending.nil? || pending.empty?

      redacted_pending = TranscriptRedactor.redact(pending)
      # Prefix reuse rests on the redactor preserving line structure. If that
      # ever stopped holding, splitting would stop being equivalent — so the
      # cheap version of the check is paid on the tail every poll, and a mismatch
      # drops the entry rather than emitting bytes we cannot vouch for.
      return redact_fully(path, content) unless redacted_pending.count(NEWLINE) == pending.count(NEWLINE)

      extend_entry(path, entry, content, pending, redacted_pending)
    end

    # Drop everything. For tests, and for anything that wants to measure or prove
    # a result against a cold cache.
    def reset!
      MUTEX.synchronize do
        @entries = {}
        @total_bytes = 0
      end
    end

    # @return [Hash] entry count and resident bytes, for tests and diagnostics
    def statistics
      MUTEX.synchronize { { entries: entries.size, bytes: total_bytes } }
    end

    private

    def entries
      @entries ||= {}
    end

    def total_bytes
      @total_bytes ||= 0
    end

    def cacheable?(path, content)
      path.is_a?(String) && !path.empty? &&
        content.is_a?(String) &&
        content.bytesize >= MIN_CACHEABLE_BYTES &&
        content.bytesize <= MAX_ENTRY_BYTES
    end

    # Redact the whole thing, and seed an entry so the NEXT read is incremental.
    def redact_fully(path, content)
      output = TranscriptRedactor.redact(content)
      return output unless output.is_a?(String)

      split = commit_split(content, output)
      return output unless split

      raw_commit, redacted_commit = split
      redacted_prefix = output.byteslice(0, redacted_commit)
      store(
        path,
        Entry.new(
          chunks: [ redacted_prefix ],
          chunk_bytes: redacted_prefix.bytesize,
          raw_committed_size: raw_commit,
          head_digest: digest(content.byteslice(0, FINGERPRINT_WINDOW)),
          boundary_digest: boundary_digest(content, raw_commit),
          touched_at: monotonic_now
        )
      )

      output
    end

    # Answer the read from the cached prefix plus this poll's freshly redacted
    # tail, and move the commit point forward over the part of the tail that is
    # now settled.
    def extend_entry(path, entry, content, pending, redacted_pending)
      output = entry.chunks.join + redacted_pending
      split = commit_split(pending, redacted_pending)

      if split
        raw_advance, redacted_advance = split
        committed_chunk = redacted_pending.byteslice(0, redacted_advance)
        chunks = entry.chunks + [ committed_chunk ]
        chunks = [ chunks.join ] if chunks.length > MAX_CHUNKS
        raw_committed_size = entry.raw_committed_size + raw_advance

        store(
          path,
          Entry.new(
            chunks: chunks,
            chunk_bytes: entry.chunk_bytes + committed_chunk.bytesize,
            raw_committed_size: raw_committed_size,
            head_digest: entry.head_digest,
            boundary_digest: boundary_digest(content, raw_committed_size),
            touched_at: monotonic_now
          )
        )
      else
        entry.touched_at = monotonic_now
        store(path, entry)
      end

      output
    end

    # Where `raw` and its redaction `redacted` may be cut so the two halves stay
    # independently redactable.
    #
    # Committing only at a newline is what stops a would-be secret from being
    # split across two scans; stopping short of a line that could open a
    # multi-line PEM block is what stops such a block from straddling the cut.
    # Both are hard requirements, not heuristics.
    #
    # @return [Array(Integer, Integer), nil] raw byte count and redacted byte
    #   count to commit, or nil when nothing can be committed yet
    def commit_split(raw, redacted)
      opener = TranscriptRedactor.private_key_block_start(raw)

      if opener.nil?
        # No PEM armor anywhere: cut at the last newline. Redaction preserves
        # terminators, so the last newline of the redacted text terminates the
        # same source line.
        raw_end = raw.byterindex(NEWLINE)
        redacted_end = redacted.byterindex(NEWLINE)
        return nil if raw_end.nil? || redacted_end.nil?

        [ raw_end + 1, redacted_end + 1 ]
      else
        # An opener always begins a line, so its offset is already a cut point.
        return nil unless opener.positive?

        lines = raw.byteslice(0, opener).count(NEWLINE)
        redacted_end = nth_newline_end(redacted, lines)
        return nil if redacted_end.nil?

        [ opener, redacted_end ]
      end
    end

    # Byte offset just past the `count`-th newline, or nil if there are fewer.
    def nth_newline_end(text, count)
      offset = -1
      count.times do
        offset = text.byteindex(NEWLINE, offset + 1)
        return nil if offset.nil?
      end
      offset + 1
    end

    def reusable?(entry, content)
      return false unless entry.raw_committed_size.positive?
      return false if content.bytesize < entry.raw_committed_size
      # The tail must start where a line starts IN THE CONTENT BEING READ NOW.
      # This is the check that makes under-redaction impossible: no pattern can
      # match across a newline, so a tail that begins at one cannot hide the
      # front half of a secret in the prefix.
      return false unless content.getbyte(entry.raw_committed_size - 1) == NEWLINE_BYTE
      return false unless digest(content.byteslice(0, FINGERPRINT_WINDOW)) == entry.head_digest

      boundary_digest(content, entry.raw_committed_size) == entry.boundary_digest
    end

    # Fingerprint of the last FINGERPRINT_WINDOW bytes before the commit point.
    # With the head fingerprint and the length check, this is what detects a
    # truncated, rotated, restored or replaced file. It samples rather than
    # hashing the whole prefix on purpose: hashing 32 MB per poll would put back
    # an O(total size) cost, and the consequence of a miss is a stale prefix, not
    # an unredacted one (see the class comment).
    def boundary_digest(content, committed)
      window = [ committed, FINGERPRINT_WINDOW ].min
      digest(content.byteslice(committed - window, window))
    end

    def digest(bytes)
      Digest::SHA256.digest(bytes.to_s)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Take the entry and move it to the most-recently-used end.
    #
    # Redaction itself runs OUTSIDE the lock: it is the multi-second CPU cost
    # this class exists to shrink, and holding a process-wide mutex across it
    # would serialize every poller thread behind the slowest transcript. Two
    # threads racing on one path both compute a correct answer and the later
    # write wins, which is the same trade `TranscriptRedactor.known_secrets`
    # already makes.
    def checkout(path)
      MUTEX.synchronize do
        entry = entries.delete(path)
        next nil unless entry

        entries[path] = entry
        entry
      end
    end

    def store(path, entry)
      MUTEX.synchronize do
        drop(path)
        entries[path] = entry
        @total_bytes = total_bytes + entry.chunk_bytes
        evict
      end
    end

    # Called with MUTEX held.
    def evict
      now = monotonic_now
      stale = entries.select { |_path, entry| now - entry.touched_at > MAX_IDLE_SECONDS }.keys
      stale.each { |path| drop(path) }

      while entries.size > MAX_ENTRIES || total_bytes > MAX_TOTAL_BYTES
        oldest = entries.keys.first
        break unless oldest

        drop(oldest)
      end
    end

    # Called with MUTEX held.
    def drop(path)
      entry = entries.delete(path)
      return unless entry

      @total_bytes = total_bytes - entry.chunk_bytes
    end
  end
end
