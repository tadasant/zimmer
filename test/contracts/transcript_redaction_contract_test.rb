# frozen_string_literal: true

require "test_helper"

# Redaction is only as good as the narrowest path around it.
#
# `TranscriptRedactor` runs inside `TranscriptSource#read`. That covers the
# poller, but Zimmer has another place that re-reads a transcript off disk and
# writes it to `sessions.transcript` — the manual refresh, Sessions::RefreshTranscript,
# which SessionsController, Api::V1::SessionsController and
# Mcp::Tools::ActionSession all call. Each of those originally used a bare `File.read`,
# which wrote an unredacted transcript straight over the redacted one the poller
# had stored, and (because the refresh paths compare stored content against file
# content) left the two writers overwriting each other on every pass.
#
# That class of bug is invisible in a unit test of any single class, so it is
# pinned structurally here: reading transcript bytes off disk goes through the
# runtime's TranscriptSource, never through `File.read`.
class TranscriptRedactionContractTest < ActiveSupport::TestCase
  # `File.read(main_transcript_file)`, `File.read(transcript_file)`, and any
  # other raw read of a path whose name says "transcript".
  RAW_TRANSCRIPT_READ = /File\.(?:read|binread)\([^)]*transcript[^)]*\)/i

  test "nothing in app/ reads transcript bytes off disk with a bare File.read" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].filter_map do |path|
      hits = File.readlines(path).each_with_index.filter_map do |line, index|
        "  #{Pathname.new(path).relative_path_from(Rails.root)}:#{index + 1}  #{line.strip}" if line.match?(RAW_TRANSCRIPT_READ)
      end
      hits.presence
    end.flatten

    assert_empty offenders, <<~MESSAGE
      These read transcript bytes without going through TranscriptSource#read, so they skip
      TranscriptRedactor and can overwrite a redacted transcript with an unredacted one:

      #{offenders.join("\n")}

      Use `TranscriptRuntime.source_for(session).read(path)` instead. It redacts, and it also
      decompresses a Codex .zst rollout that a raw read would store as binary.
    MESSAGE
  end

  test "every transcript refresh path resolves its reader through TranscriptRuntime" do
    # The refresh implementation, and the three surfaces that used to carry their
    # own copies, named explicitly so deleting one is a deliberate act rather than
    # a silent loss of coverage. The service must persist; a surface that starts
    # persisting a transcript again must resolve a redacting reader too.
    service = "app/services/sessions/refresh_transcript.rb"
    assert_match(/transcript:\s/, File.read(Rails.root.join(service)),
      "#{service} no longer persists a transcript — move this contract to wherever the refresh went")

    [
      service,
      "app/controllers/sessions_controller.rb",
      "app/controllers/api/v1/sessions_controller.rb",
      "app/services/mcp/tools/action_session.rb"
    ].each do |relative|
      source = File.read(Rails.root.join(relative))
      next unless source.match?(/transcript:\s/)

      assert_match(/TranscriptRuntime\.source_for\([^)]*\)\.read\(/, source,
        "#{relative} persists transcript content but never resolves a redacting reader")
    end
  end

  test "TranscriptSource#read applies redaction for every registered runtime" do
    RuntimeRegistry::BUNDLES.each_value do |bundle|
      source_class = bundle.transcript_source_class

      assert_equal TranscriptSource.instance_method(:read), source_class.instance_method(:read),
        "#{source_class} overrides #read and would bypass redaction; override #read_raw instead"
    end
  end
end
