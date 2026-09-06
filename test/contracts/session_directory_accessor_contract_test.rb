# frozen_string_literal: true

require "test_helper"

# A session's directory on disk is ONE concept per question, named once.
#
# Two questions, two accessors:
#
#   Session#working_directory  where this session's agent runs — the recorded
#                              working directory, falling back to the clone root
#                              for a session that has a clone but has not been
#                              spawned in yet
#   Session#clone_root         the root of the git clone, which is the PARENT of
#                              the above for a session with an agent root
#
# The reason this is a contract and not a convention: #183 and #187 were both a
# call site reading one of these keys straight out of `metadata`, getting the
# wrong answer for some population of sessions, and failing silently. Each was
# fixed where it was found; the ~50 sites reading the same keys the same way were
# not. A raw `metadata&.dig("working_directory")` has no fallback, so it answers
# nil for a session whose clone exists but was never spawned in — and every one of
# those reads sits behind a `return unless working_directory.present?` guard that
# then reads as "no clone yet" (#790).
#
# A source scan rather than a runtime assertion because that is the only thing
# that covers all of `app/` at once. ALLOWED is the escape hatch, and adding to it
# is a decision: the reason has to be that the site genuinely needs the raw key,
# not that calling the accessor was inconvenient.
class SessionDirectoryAccessorContractTest < ActiveSupport::TestCase
  SCANNED = Rails.root.join("app")

  # A read of either key out of a metadata hash, in any of the four idioms the
  # sweep found: `&.dig("k")`, `.dig("k")`, `["k"]` and the symbol forms.
  RAW_READ = /
    (?:custom_)?metadata\s*(?:&\.)?(?:
      dig\(\s*:?["']?(?:working_directory|clone_path)["']?\s*[),]
      |
      \[\s*:?["']?(?:working_directory|clone_path)["']?\s*\]
    )
  /x

  # `full_clone_path` was a third key holding the identical value to
  # `working_directory`, written at four sites and read at one. It is gone; this
  # keeps it gone, because the way it appeared the first time was a view spelling
  # the accessor's semantics by hand rather than calling it.
  RETIRED_KEY = /full_clone_path/

  ALLOWED = {
    # The accessors themselves. This is the one place the raw keys are read.
    "models/session.rb" => [
      'metadata&.dig("working_directory").presence || metadata&.dig("clone_path").presence',
      'metadata&.dig("clone_path").presence'
    ]
  }.freeze

  test "no production code outside Session reads a session's directory out of metadata" do
    offenders = []

    each_scanned_line do |relative, line_number, stripped|
      next unless stripped.match?(RAW_READ)
      next if ALLOWED.fetch(relative, []).any? { |snippet| stripped.include?(snippet) }

      offenders << "#{relative}:#{line_number}  #{stripped}"
    end

    assert_empty offenders, <<~MESSAGE
      These read a session's directory straight out of `metadata`. A raw
      `working_directory` read has no fallback and answers nil for a session with
      a clone it has never been spawned in, which every caller's presence guard
      then reads as "no clone yet" (#790).

      Call Session#working_directory for "where does this session's agent run",
      or Session#clone_root for "where is this session's clone" — deletion,
      artifact preservation and disk reclamation want the latter, and saying so by
      name is the point. Add the site to ALLOWED here only with the reason it
      genuinely needs the raw key:

      #{offenders.join("\n      ")}
    MESSAGE
  end

  test "the retired full_clone_path key has not come back" do
    offenders = []

    each_scanned_line do |relative, line_number, stripped|
      next unless stripped.match?(RETIRED_KEY)

      offenders << "#{relative}:#{line_number}  #{stripped}"
    end

    assert_empty offenders, <<~MESSAGE
      `full_clone_path` held the identical value to `working_directory` at all four
      of its write sites and had exactly one reader — a view that spelled
      Session#working_directory's semantics by hand. Use the accessor:

      #{offenders.join("\n      ")}
    MESSAGE
  end

  # The scan is worth nothing if its regex has stopped matching the shape. This
  # pins it against the literal text of the reads that were converted.
  test "the scan still recognises the shape it exists to reject" do
    flagged = [
      'working_directory = @session.metadata&.dig("working_directory")',
      'clone_path = session.metadata&.dig("clone_path")',
      'copy_clone_directory(source_session.metadata["clone_path"], new_clone_path)',
      'Dir.exist?(session.metadata["working_directory"])',
      'working_directory: session.metadata&.dig("working_directory")',
      'previous = session&.metadata&.dig("clone_path")',
      'clone_path = metadata&.dig("clone_path")'
    ]

    flagged.each do |sample|
      assert sample.match?(RAW_READ), "the scan no longer flags: #{sample}"
    end

    not_flagged = [
      "working_directory = @session.working_directory",
      "clone_path = session.clone_root",
      'process_pid = session.metadata&.dig("process_pid")',
      'session.merge_metadata!("clone_path" => clone_path)',
      'metadata&.dig("agent_root_key")',
      "Session.where(\"metadata->>'clone_path' IS NOT NULL\")"
    ]

    not_flagged.each do |sample|
      assert_not sample.match?(RAW_READ), "the scan wrongly flags: #{sample}"
    end
  end

  private

  def each_scanned_line
    Dir.glob(SCANNED.join("**/*.{rb,erb}")).sort.each do |path|
      relative = Pathname.new(path).relative_path_from(SCANNED).to_s

      File.readlines(path).each_with_index do |line, index|
        stripped = line.strip
        next if stripped.start_with?("#", "<%#")

        yield relative, index + 1, stripped
      end
    end
  end
end
