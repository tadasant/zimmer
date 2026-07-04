# frozen_string_literal: true

require "test_helper"

class TranscriptRuntimeTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
  end

  test "source_for returns a ClaudeTranscriptSource" do
    assert_instance_of ClaudeTranscriptSource, TranscriptRuntime.source_for(@session)
  end

  test "source_for passes the file_system through to the source" do
    file_system = MockFileSystemAdapter.new
    source = TranscriptRuntime.source_for(@session, file_system: file_system)

    # The injected adapter is used for IO: a path written through it is readable.
    file_system.write("/tmp/x.jsonl", "{\"a\":1}")
    assert_equal [ { "a" => 1 } ], source.read_events("/tmp/x.jsonl")
  end

  test "normalizer_for returns a ClaudeTranscriptNormalizer" do
    assert_instance_of ClaudeTranscriptNormalizer, TranscriptRuntime.normalizer_for(@session)
  end
end
