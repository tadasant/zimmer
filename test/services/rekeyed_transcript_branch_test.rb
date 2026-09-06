# frozen_string_literal: true

require "test_helper"

# The merge that makes following a re-keyed transcript branch non-destructive
# (#1047). Every case here is stated in the three terms the service's own comment
# uses: H, the head the branch copied; A, what the abandoned file recorded after
# the copy; T, the branch's own tail.
class RekeyedTranscriptBranchTest < ActiveSupport::TestCase
  test "a branch that copied the whole file replaces the stored transcript" do
    stored = lines(1..5)
    branch = lines(1..7)

    assert_equal branch, RekeyedTranscriptBranch.splice(stored: stored, branch: branch)
  end

  test "the abandoned file's tail survives a branch that copied only part of it" do
    # H = 1..3, A = 4..5, T = 6..7
    stored = lines(1..5)
    branch = lines(1..3) + lines(6..7)

    assert_equal lines(1..5) + lines(6..7), RekeyedTranscriptBranch.splice(stored: stored, branch: branch)
  end

  test "a second call on a grown branch appends only what is new" do
    stored = lines(1..5) + lines(6..7)
    branch = lines(1..3) + lines(6..8)

    assert_equal lines(1..5) + lines(6..8), RekeyedTranscriptBranch.splice(stored: stored, branch: branch)
  end

  test "a chained re-key does not re-append the first branch's tail" do
    # The case a remembered split point gets wrong: after the first merge the
    # stored transcript is no longer prefix-shaped, so a K derived as a head
    # prefix undercounts and the error compounds on every further re-key.
    stored = lines(1..5) + lines(6..8)
    second_branch = lines(1..3) + lines(6..8) + lines(9..9)

    assert_equal lines(1..5) + lines(6..9),
      RekeyedTranscriptBranch.splice(stored: stored, branch: second_branch)
  end

  test "a branch that adds nothing leaves the stored transcript alone" do
    stored = lines(1..5) + lines(6..7)
    branch = lines(1..3)

    assert_equal stored, RekeyedTranscriptBranch.splice(stored: stored, branch: branch)
  end

  test "a stored transcript read mid-flush drops its half-written line rather than duplicating it" do
    stored = lines(1..4) + %({"uuid":"e5","text":"ev)
    branch = lines(1..5) + lines(6..6)

    assert_equal branch, RekeyedTranscriptBranch.splice(stored: stored, branch: branch)
  end

  test "a blank stored transcript yields the branch" do
    assert_equal lines(1..2), RekeyedTranscriptBranch.splice(stored: nil, branch: lines(1..2))
    assert_equal lines(1..2), RekeyedTranscriptBranch.splice(stored: "", branch: lines(1..2))
  end

  test "the legacy Array transcript format is left alone" do
    # Slicing `.to_s` of an Array would splice Ruby's inspect output into the
    # stored transcript; #carryover_prefix bails on one for the same reason.
    assert_equal lines(1..2), RekeyedTranscriptBranch.splice(stored: [ { "type" => "user" } ], branch: lines(1..2))
  end

  test "the merge never shortens the stored transcript" do
    stored = lines(1..9)
    [ lines(1..3), lines(1..3) + lines(20..21), lines(50..50), "" ].each do |branch|
      merged = RekeyedTranscriptBranch.splice(stored: stored, branch: branch)
      assert_operator merged.lines.length, :>=, stored.lines.length,
        "merging #{branch.lines.length} branch lines shrank the record"
      assert merged.start_with?(stored), "the stored transcript must stay the prefix"
    end
  end

  # === continue: the shared entry point every writer of sessions.transcript uses ===

  test "continue is a no-op when the located file is the recorded transcript" do
    session = sessions(:running)
    session.update!(session_id: "recorded-uuid", transcript: lines(1..5))
    file_system = MockFileSystemAdapter.new
    dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    file_system.mkdir_p(dir)
    file_system.write("#{dir}/recorded-uuid.jsonl", lines(1..6))

    assert_equal lines(1..6), RekeyedTranscriptBranch.continue(
      session: session,
      transcript_path: "#{dir}/recorded-uuid.jsonl",
      content: lines(1..6),
      source: ClaudeTranscriptSource.new(file_system: file_system)
    )
  end

  test "continue merges when the located file is a re-keyed branch" do
    session = sessions(:running)
    session.update!(session_id: "recorded-uuid", transcript: lines(1..5))
    file_system = MockFileSystemAdapter.new
    dir = File.join(File.expand_path("~"), ".claude", "projects", "-tmp-test-clone")
    branch_content = keyed_lines("recorded-uuid", 1..3) + keyed_lines("branch-uuid", 6..7)
    file_system.mkdir_p(dir)
    file_system.write("#{dir}/branch-uuid.jsonl", branch_content)

    merged = RekeyedTranscriptBranch.continue(
      session: session,
      transcript_path: "#{dir}/branch-uuid.jsonl",
      content: branch_content,
      source: ClaudeTranscriptSource.new(file_system: file_system)
    )

    assert_includes merged, "event 5", "the abandoned file's tail is held nowhere else"
    assert_includes merged, "event 7"
  end

  private

  # Lines whose stored form matches what `continue` above will compare against:
  # the session's own id in the head, so the fixtures line up.
  def lines(range)
    keyed_lines("recorded-uuid", range)
  end

  def keyed_lines(session_id, range)
    range.map { |i|
      { "type" => "user", "sessionId" => session_id, "uuid" => "e#{i}", "text" => "event #{i}" }.to_json
    }.join("\n") + "\n"
  end
end
