# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The GitHub source is the one that actually runs in production — the ledger
# files live in a different repository, there is no checkout of it on the box,
# and by design no shell to debug it from. So it is worth testing the shelling
# out even though every other test drives the directory source.
class GateDecisions::LedgerSourceTest < ActiveSupport::TestCase
  LISTING = [
    { "name" => "PR_MERGE_GATE_ZIMMER_LEDGER.json", "type" => "file" },
    { "name" => "ISSUE_WORK_GATE_STRAD_LEDGER.json", "type" => "file" },
    { "name" => "PR_MERGE_GATE_LEDGER.md", "type" => "file" },
    { "name" => "WORK_BACKLOG.json", "type" => "file" }
  ].freeze

  def stub_gh(responses)
    calls = []
    runner = lambda do |command, **kwargs|
      calls << [ command, kwargs ]
      responses.shift.call(command)
    end
    GhTokenProvisioner.stub(:ensure!, nil) do
      BoundedSubprocess.stub(:run, runner) { yield calls }
    end
  end

  def ok(body) = ->(_command) { [ body, "", SubprocessStatusStub.new(true) ] }
  def failure = ->(_command) { [ "", "gh: not found", SubprocessStatusStub.new(false) ] }

  SubprocessStatusStub = Struct.new(:ok) do
    def success? = ok
    def exitstatus = ok ? 0 : 1
    def signaled? = false
    def termsig = nil
  end

  test "lists only ledger files, in name order" do
    stub_gh([ ok(JSON.generate(LISTING)) ]) do
      files = GateDecisions::LedgerSource::Github.new.files

      assert_equal [ "ISSUE_WORK_GATE_STRAD_LEDGER.json", "PR_MERGE_GATE_ZIMMER_LEDGER.json" ],
                   files.map(&:name)
      assert_equal [ GateDecision::ISSUE_WORK, GateDecision::PR_MERGE ], files.map(&:gate)
      assert_equal %w[strad zimmer], files.map(&:surface)
    end
  end

  test "fetches an entry list with the raw media type, since the default form caps at 1 MB" do
    file = GateDecisions::LedgerFile.parse("PR_MERGE_GATE_ZIMMER_LEDGER.json")

    stub_gh([ ok(JSON.generate([ { "pr" => "https://x/1" } ])) ]) do |calls|
      entries = GateDecisions::LedgerSource::Github.new.entries(file)

      assert_equal [ { "pr" => "https://x/1" } ], entries
      command = calls.sole.first
      assert_includes command.join(" "), "PR_MERGE_GATE_ZIMMER_LEDGER.json"
      assert_includes command, "Accept: application/vnd.github.raw"
    end
  end

  test "a listing that is not a directory is reported, not treated as empty" do
    stub_gh([ ok(JSON.generate({ "message" => "Not Found" })) ]) do
      assert_raises(GateDecisions::LedgerSource::Unavailable) { GateDecisions::LedgerSource::Github.new.files }
    end
  end

  test "unparseable JSON is reported rather than silently importing nothing" do
    stub_gh([ ok("<html>502</html>") ]) do
      error = assert_raises(GateDecisions::LedgerSource::Unavailable) do
        GateDecisions::LedgerSource::Github.new.files
      end
      assert_match(/could not parse/, error.message)
    end
  end

  test "a failed gh call is reported with what gh said" do
    stub_gh([ failure ]) do
      error = assert_raises(GateDecisions::LedgerSource::Unavailable) do
        GateDecisions::LedgerSource::Github.new.files
      end
      assert_match(/gh api/, error.message)
    end
  end

  test "a timeout is reported as unavailable, not raised at the post-deploy task" do
    raiser = ->(_command, **) { raise BoundedSubprocess::TimeoutError, "timed out after 60s" }

    GhTokenProvisioner.stub(:ensure!, nil) do
      BoundedSubprocess.stub(:run, raiser) do
        error = assert_raises(GateDecisions::LedgerSource::Unavailable) do
          GateDecisions::LedgerSource::Github.new.files
        end
        assert_match(/timed out/, error.message)
      end
    end
  end

  test "a container with no gh CLI says how to point the import somewhere else" do
    raiser = ->(_command, **) { raise Errno::ENOENT, "gh" }

    GhTokenProvisioner.stub(:ensure!, nil) do
      BoundedSubprocess.stub(:run, raiser) do
        error = assert_raises(GateDecisions::LedgerSource::Unavailable) do
          GateDecisions::LedgerSource::Github.new.files
        end
        assert_match(/GATE_DECISION_LEDGER_DIR/, error.message)
      end
    end
  end

  test "both timeouts stay under the post-deploy slice budget" do
    # The importer only checks its budget between files, so a fetch allowed to run
    # longer than a whole slice holds the worker past the deadline before the
    # budget is consulted even once.
    assert_operator GateDecisions::LedgerSource::Github::FETCH_TIMEOUT, :<, PostDeployTaskJob::SLICE_BUDGET
    assert_operator GateDecisions::LedgerSource::Github::LIST_TIMEOUT, :<, PostDeployTaskJob::SLICE_BUDGET
  end

  test "resolve prefers an explicit directory, then the env var, then GitHub" do
    Dir.mktmpdir do |dir|
      assert_equal dir, GateDecisions::LedgerSource.resolve(dir: dir).path

      previous = ENV[GateDecisions::LedgerSource::DIR_ENV_VAR]
      begin
        ENV[GateDecisions::LedgerSource::DIR_ENV_VAR] = dir
        assert_equal dir, GateDecisions::LedgerSource.resolve.path
        assert_equal "/other", GateDecisions::LedgerSource.resolve(dir: "/other").path

        ENV.delete(GateDecisions::LedgerSource::DIR_ENV_VAR)
        assert_instance_of GateDecisions::LedgerSource::Github, GateDecisions::LedgerSource.resolve
      ensure
        ENV[GateDecisions::LedgerSource::DIR_ENV_VAR] = previous
      end
    end
  end
end
