# frozen_string_literal: true

require "test_helper"

# The cache reuses an already-redacted prefix instead of re-scanning a whole
# transcript on every poll (#477). Two things have to be true for that to be
# safe, and both are pinned here:
#
#   1. The incremental result is BYTE-IDENTICAL to a full re-scan, including
#      when a poll boundary falls in the middle of a would-be secret and when a
#      multi-line PEM block spans two polls.
#   2. A transcript that was truncated, rewritten or replaced falls back to a
#      full re-scan rather than emitting a stale prefix.
class TranscriptRedactionCacheTest < ActiveSupport::TestCase
  PATH = "/tmp/transcript-redaction-cache-test/session.jsonl"

  # Comfortably over MIN_CACHEABLE_BYTES so the cache actually engages.
  LINES = 900

  setup do
    TranscriptRedactor.reset_known_secrets!
    TranscriptRedactionCache.reset!
  end

  teardown do
    TranscriptRedactor.reset_known_secrets!
    TranscriptRedactionCache.reset!
  end

  # --- Equivalence ----------------------------------------------------------

  test "an appended transcript redacts byte-identically to a full re-scan" do
    content = transcript

    intermediate = TranscriptRedactionCache.redact(PATH, content.byteslice(0, content.bytesize / 2))
    assert_equal TranscriptRedactor.redact(content.byteslice(0, content.bytesize / 2)), intermediate

    assert_equal TranscriptRedactor.redact(content), TranscriptRedactionCache.redact(PATH, content)
  end

  test "the result is byte-identical however many chunks the transcript arrives in" do
    content = transcript
    offsets = (1..19).map { |n| (content.bytesize * n) / 20 } + [ content.bytesize ]

    offsets.each do |offset|
      seen = content.byteslice(0, offset)
      assert_equal TranscriptRedactor.redact(seen),
        TranscriptRedactionCache.redact(PATH, seen),
        "incremental redaction diverged after #{offset} bytes"
    end
  end

  test "a secret split across a chunk boundary is still redacted" do
    token = "ghp_#{'a1B2c3D4e5' * 4}"
    content = transcript(extra_line: %({"role":"user","content":"the token is #{token} and that is all"}))

    # Cut in the middle of the token itself: a poll that catches the file
    # mid-write sees only its first half.
    split = content.byteindex(token) + (token.length / 2)
    partial = content.byteslice(0, split)

    assert_includes partial, token[0, 8], "the fixture must actually split the token"
    refute_includes partial, token

    assert_equal TranscriptRedactor.redact(partial), TranscriptRedactionCache.redact(PATH, partial)

    complete = TranscriptRedactionCache.redact(PATH, content)
    assert_equal TranscriptRedactor.redact(content), complete
    refute_includes complete, token, "the token survived a redaction split across two reads"
    assert_includes complete, "[REDACTED:GITHUB_TOKEN]"
  end

  test "line count is preserved exactly across incremental reads" do
    content = transcript

    offsets = [ content.bytesize / 3, (content.bytesize * 2) / 3, content.bytesize ]
    offsets.each do |offset|
      seen = content.byteslice(0, offset)
      assert_equal seen.lines.length, TranscriptRedactionCache.redact(PATH, seen).lines.length
    end
  end

  test "a transcript with broken byte sequences still redacts identically, and is still cached" do
    base = transcript
    at = base.byteindex("line 400")
    content = (base.byteslice(0, at) + "\xC3(binary junk\xFF " + base.byteslice(at, base.bytesize - at))
      .force_encoding(Encoding::UTF_8)
    refute_predicate content, :valid_encoding?

    (1..8).each do |n|
      seen = content.byteslice(0, (content.bytesize * n) / 8)
      assert_equal TranscriptRedactor.redact(seen),
        TranscriptRedactionCache.redact(PATH, seen),
        "incremental redaction of an invalid-encoding transcript diverged at chunk #{n}"
    end

    assert_equal 1, TranscriptRedactionCache.statistics[:entries],
      "one broken byte must not cost the session its cache entry for the rest of the run"
  end

  # --- The one cross-line stage --------------------------------------------

  test "a multi-line PEM block that spans two reads is still armored whole" do
    body = Array.new(12) { "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC#{'x' * 20}" }
    pem = [ "-----BEGIN PRIVATE KEY-----", *body, "-----END PRIVATE KEY-----" ]
    content = transcript + pem.join("\n") + "\n" + %({"role":"assistant","content":"done"}\n)

    # The first read stops inside the armor, before the END marker.
    partial = content.byteslice(0, content.byteindex(body.last))
    assert_equal TranscriptRedactor.redact(partial), TranscriptRedactionCache.redact(PATH, partial)

    complete = TranscriptRedactionCache.redact(PATH, content)
    assert_equal TranscriptRedactor.redact(content), complete
    assert_equal 14, complete.scan("[REDACTED:PRIVATE_KEY]").length,
      "every line of the block, including the ones read before the END marker arrived, must be armored"
    refute_includes complete, body.first
  end

  test "a transcript carrying PEM armor never commits past the opening line" do
    pem = [ "-----BEGIN PRIVATE KEY-----", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC", "-----END PRIVATE KEY-----" ]
    head = transcript
    content = head + pem.join("\n") + "\n"

    TranscriptRedactionCache.redact(PATH, content)
    assert_equal head.bytesize, committed_size, "the commit point must stop at the block opener"
  end

  # --- Invalidation ---------------------------------------------------------

  test "a truncated transcript falls back to a full re-scan" do
    content = transcript
    TranscriptRedactionCache.redact(PATH, content)

    shorter = content.byteslice(0, content.bytesize / 4)
    assert_equal TranscriptRedactor.redact(shorter), TranscriptRedactionCache.redact(PATH, shorter)
  end

  test "a transcript rewritten in place falls back to a full re-scan" do
    content = transcript
    TranscriptRedactionCache.redact(PATH, content)

    # Same length, same tail, different opening record: a new session that
    # reused the path, or a restore that rewrote the file.
    rewritten = content.dup
    rewritten[0, 40] = "X" * 40
    assert_equal TranscriptRedactor.redact(rewritten), TranscriptRedactionCache.redact(PATH, rewritten)
  end

  test "a transcript rewritten just before the commit point falls back to a full re-scan" do
    content = transcript
    TranscriptRedactionCache.redact(PATH, content)
    boundary = committed_size

    rewritten = content.dup
    rewritten[boundary - 200, 40] = "Y" * 40
    assert_equal TranscriptRedactor.redact(rewritten), TranscriptRedactionCache.redact(PATH, rewritten)
  end

  test "a rotated transcript is not served from the previous file's prefix" do
    first = transcript(marker: "first")
    TranscriptRedactionCache.redact(PATH, first)

    second = transcript(marker: "second") + transcript(marker: "second-more")
    result = TranscriptRedactionCache.redact(PATH, second)

    assert_equal TranscriptRedactor.redact(second), result
    refute_includes result, "first"
  end

  test "an append that no longer lands on a line boundary falls back to a full re-scan" do
    content = transcript
    TranscriptRedactionCache.redact(PATH, content)
    boundary = committed_size
    assert_operator boundary, :>, 0

    # Delete one byte from inside the committed region so the recorded offset no
    # longer sits after a newline. Redacting from a mid-line offset is the ONE
    # way an incremental scan can under-redact, so this must not be reachable.
    shifted = content.dup
    shifted[boundary - 100] = ""
    refute_equal "\n", shifted[boundary - 1]

    assert_equal TranscriptRedactor.redact(shifted), TranscriptRedactionCache.redact(PATH, shifted)
  end

  # --- The point of the change ---------------------------------------------

  test "a poll after an append scans only the appended bytes" do
    content = transcript
    appended = %({"role":"assistant","content":"#{'z' * 400}"}\n)

    TranscriptRedactionCache.redact(PATH, content)

    scanned = record_scanned_bytes { TranscriptRedactionCache.redact(PATH, content + appended) }

    assert_equal 1, scanned.length
    assert_operator scanned.sum, :<, content.bytesize / 10,
      "the poll re-scanned #{scanned.sum} bytes of a #{content.bytesize}-byte transcript"
    assert_operator scanned.sum, :>=, appended.bytesize
  end

  test "repeated polls of a growing transcript cost the appended bytes, not the total" do
    content = transcript
    TranscriptRedactionCache.redact(PATH, content)

    totals = []
    12.times do |n|
      content += %({"role":"assistant","content":"tick #{n} #{'y' * 300}"}\n)
      totals << record_scanned_bytes { TranscriptRedactionCache.redact(PATH, content) }.sum
    end

    assert_operator totals.max, :<, 4_000,
      "per-poll scan cost grew with the transcript: #{totals.inspect}"
  end

  test "a transcript too small to be worth caching is redacted directly" do
    small = %({"role":"user","content":"hello"}\n) * 3
    assert_operator small.bytesize, :<, TranscriptRedactionCache::MIN_CACHEABLE_BYTES

    assert_equal TranscriptRedactor.redact(small), TranscriptRedactionCache.redact(PATH, small)
    assert_equal 0, TranscriptRedactionCache.statistics[:entries]
  end

  test "nil and non-string content are passed straight through" do
    assert_nil TranscriptRedactionCache.redact(PATH, nil)
    assert_equal "", TranscriptRedactionCache.redact(PATH, "")
  end

  # --- Memory bounds --------------------------------------------------------

  test "the cache evicts so it cannot grow without bound" do
    content = transcript

    (TranscriptRedactionCache::MAX_ENTRIES + 8).times do |n|
      TranscriptRedactionCache.redact("#{PATH}.#{n}", content)
    end

    stats = TranscriptRedactionCache.statistics
    assert_operator stats[:entries], :<=, TranscriptRedactionCache::MAX_ENTRIES
    assert_operator stats[:bytes], :<=, TranscriptRedactionCache::MAX_TOTAL_BYTES
  end

  test "an evicted path still redacts correctly, just without the shortcut" do
    content = transcript
    TranscriptRedactionCache.redact(PATH, content)
    TranscriptRedactionCache.reset!

    assert_equal TranscriptRedactor.redact(content), TranscriptRedactionCache.redact(PATH, content)
  end

  # --- The invariant the whole design rests on ------------------------------

  test "no redaction pattern is multiline" do
    multiline = TranscriptRedactor::PATTERNS.select do |pattern|
      pattern.regexp.options.anybits?(Regexp::MULTILINE)
    end

    assert_empty multiline.map(&:label),
      "a /m pattern lets `.` match a newline, which would break prefix reuse"
  end

  test "no redaction pattern can match across a newline" do
    offenders = TranscriptRedactor::PATTERNS.select { |pattern| crosses_newline?(pattern.regexp) }

    assert_empty offenders.map(&:label),
      "TranscriptRedactionCache splits transcripts at newlines; these patterns could match across one"
  end

  private

  # Does this regexp match any string containing a newline? Probed rather than
  # reasoned about: a pattern that can span a line boundary breaks prefix reuse.
  def crosses_newline?(regexp)
    probes = [
      "aws_secret_access_key=\n#{'A' * 40}",
      "bearer\n#{'a' * 30}",
      "x-api-key:\n#{'b' * 30}",
      "https://user:\npassword@host",
      "postgres://user:\nsecret@host/db",
      "sk-ant-\n#{'c' * 30}",
      "token=\n#{'d' * 30}",
      "-----BEGIN PRIVATE KEY-----\nMIIabc\n-----END PRIVATE KEY-----"
    ]

    probes.any? do |probe|
      match = probe.match(regexp)
      match && match[0].include?("\n")
    end
  end

  def committed_size
    TranscriptRedactionCache.send(:entries)[PATH].raw_committed_size
  end

  # Records the size of every string handed to the redactor while the block runs.
  #
  # Prepended rather than stubbed: `redact` is defined in `class << self`, so
  # defining a singleton method over it and removing it again would delete the
  # real implementation. The module stays prepended and does nothing unless the
  # thread-local collector is set.
  ScanRecorder = Module.new do
    def redact(content)
      Thread.current[:transcript_scan_sizes]&.<<(content.to_s.bytesize)
      super
    end
  end

  def record_scanned_bytes
    TranscriptRedactor.singleton_class.prepend(ScanRecorder)
    sizes = []
    Thread.current[:transcript_scan_sizes] = sizes
    yield
    sizes
  ensure
    Thread.current[:transcript_scan_sizes] = nil
  end

  # A transcript-shaped blob big enough to be cached, with a couple of real
  # credential shapes in it so redaction has something to do.
  def transcript(marker: "line", extra_line: nil)
    lines = Array.new(LINES) do |n|
      case n % 150
      when 7
        %({"role":"assistant","content":"exported AWS_SECRET_ACCESS_KEY=#{'A1b2C3d4E5' * 4} for #{marker} #{n}"})
      when 23
        %({"role":"user","content":"curl -H 'Authorization: Bearer #{'tok3nva1ue' * 3}' #{marker} #{n}"})
      else
        %({"role":"assistant","content":"#{marker} #{n} #{'padding text ' * 6}"})
      end
    end
    lines << extra_line if extra_line
    lines.join("\n") + "\n"
  end
end
