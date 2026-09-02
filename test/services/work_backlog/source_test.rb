# frozen_string_literal: true

require "test_helper"

# The GitHub source is the one that runs in production — the file lives in a
# different repository, there is no checkout of it on the box, and no shell to
# debug from. So the shelling out is worth a test even though every other test
# drives the local-file source.
class WorkBacklog::SourceTest < ActiveSupport::TestCase
  SubprocessStatusStub = Struct.new(:ok) do
    def success? = ok
    def exitstatus = ok ? 0 : 1
    def signaled? = false
    def termsig = nil
  end

  def stub_gh(response)
    calls = []
    runner = lambda do |command, **kwargs|
      calls << [ command, kwargs ]
      response.call(command)
    end
    GhTokenProvisioner.stub(:ensure!, nil) do
      BoundedSubprocess.stub(:run, runner) { yield calls }
    end
  end

  def ok(body) = ->(_command) { [ body, "", SubprocessStatusStub.new(true) ] }
  def failure = ->(_command) { [ "", "gh: not logged in", SubprocessStatusStub.new(false) ] }

  test "resolution order: explicit path, then the env var, then GitHub" do
    assert_instance_of WorkBacklog::Source::LocalFile, WorkBacklog::Source.resolve(path: "/tmp/x.json")

    with_env(WorkBacklog::Source::PATH_ENV_VAR => "/tmp/y.json") do
      source = WorkBacklog::Source.resolve
      assert_instance_of WorkBacklog::Source::LocalFile, source
      assert_equal "/tmp/y.json", source.path
      assert_equal "/tmp/x.json", WorkBacklog::Source.resolve(path: "/tmp/x.json").path
    end

    with_env(WorkBacklog::Source::PATH_ENV_VAR => nil) do
      assert_instance_of WorkBacklog::Source::Github, WorkBacklog::Source.resolve
    end
  end

  test "fetches the one file with the raw media type and parses the array" do
    stub_gh(ok(JSON.generate([ { "id" => "zimmer#1" }, "not an object" ]))) do |calls|
      items = WorkBacklog::Source::Github.new.items

      assert_equal [ { "id" => "zimmer#1" } ], items
      command = calls.sole.first
      assert_equal %w[gh api], command.first(2)
      assert_includes command.join(" "), "repos/tadasant/tadasant-internal/contents/artifacts/agent-roots/fleet-maintenance/WORK_BACKLOG.json"
      assert_includes command, "Accept: application/vnd.github.raw"
      assert_operator calls.sole.last[:timeout], :<, PostDeployTaskJob::SLICE_BUDGET.to_i
    end
  end

  test "a failed gh call is reported with what gh said" do
    stub_gh(failure) do
      error = assert_raises(WorkBacklog::Source::Unavailable) { WorkBacklog::Source::Github.new.items }
      assert_match(/gh api .* failed/, error.message)
    end
  end

  test "a non-array or unparseable response is reported, not treated as empty" do
    stub_gh(ok(JSON.generate({ "message" => "Not Found" }))) do
      assert_raises(WorkBacklog::Source::Unavailable) { WorkBacklog::Source::Github.new.items }
    end
    stub_gh(ok("<html>502</html>")) do
      assert_raises(WorkBacklog::Source::Unavailable) { WorkBacklog::Source::Github.new.items }
    end
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |k| [ k, ENV[k] ] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
