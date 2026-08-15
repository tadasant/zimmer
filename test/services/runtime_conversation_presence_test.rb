# frozen_string_literal: true

require "test_helper"

# Tests for RuntimeConversationPresence — the "has the runtime written anything
# yet?" question every recovery branch trusts before it abandons a conversation.
#
# The direction of each answer matters more than the answer: a wrong "nothing was
# written" is what makes Zimmer throw away real history, so the interesting cases
# here are the ones that must come back true.
class RuntimeConversationPresenceTest < ActiveSupport::TestCase
  setup do
    @working_directory = "/tmp/presence-clone"
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => @working_directory, "working_directory" => @working_directory }
    )
    @file_system = MockFileSystemAdapter.new
    @file_system.mkdir_p(@working_directory)
  end

  test "true when Zimmer has polled a transcript, even with no runtime file on disk" do
    @session.update!(transcript: { "type" => "user", "message" => { "content" => "hi" } }.to_json)

    assert persisted?
  end

  # The case that stops a lagging poller from costing a session its conversation.
  test "true when only the runtime's own transcript file exists" do
    write_runtime_transcript

    assert persisted?,
      "a conversation the runtime wrote must count even before Zimmer has polled it"
  end

  test "false only when neither store holds anything" do
    refute persisted?
  end

  test "false when the runtime file exists but is empty" do
    write_runtime_transcript(content: "")

    refute persisted?
  end

  # A blank working directory means the on-disk half cannot be asked at all, so
  # the answer rests on Zimmer's copy alone.
  test "falls back to Zimmer's copy when there is no working directory to look in" do
    write_runtime_transcript

    refute RuntimeConversationPresence.persisted?(
      session: @session, working_directory: nil, file_system: @file_system
    )
  end

  # Conservative direction: a lookup that cannot run is not evidence of absence.
  test "answers present when the on-disk lookup raises" do
    exploding = Object.new
    def exploding.exists?(*) = raise("disk on fire")
    def exploding.directory?(*) = raise("disk on fire")
    def exploding.read(*) = raise("disk on fire")
    def exploding.glob(*) = raise("disk on fire")

    assert RuntimeConversationPresence.persisted?(
      session: @session, working_directory: @working_directory, file_system: exploding
    ), "an unanswerable lookup must never be read as proof the runtime wrote nothing"
  end

  test "false for a nil session" do
    refute RuntimeConversationPresence.persisted?(
      session: nil, working_directory: @working_directory, file_system: @file_system
    )
  end

  private

  def persisted?
    RuntimeConversationPresence.persisted?(
      session: @session, working_directory: @working_directory, file_system: @file_system
    )
  end

  def write_runtime_transcript(content: nil)
    require "path_sanitizer"
    dir = File.join(File.expand_path("~"), ".claude", "projects", PathSanitizer.sanitize(@working_directory))
    @file_system.mkdir_p(dir)
    @file_system.write(
      File.join(dir, "#{@session.session_id}.jsonl"),
      content || "#{{ "type" => "user", "message" => { "content" => "hi" } }.to_json}\n"
    )
  end
end
