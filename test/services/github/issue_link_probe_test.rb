# frozen_string_literal: true

require "test_helper"

# Reading GitHub's answer: which pull requests reference an issue, what state each
# is in, and the shapes that must not be mistaken for an answer.
class Github::IssueLinkProbeTest < ActiveSupport::TestCase
  test "parses issue state and the pull requests referencing it" do
    probes = probe_with(response(i0: issue(1, "OPEN", [
      pr(500, "MERGED", "2026-09-01T00:00:00Z"),
      pr(501, "OPEN", "2026-09-09T00:00:00Z")
    ])))

    probe = probes.fetch(1)
    assert probe.open?
    assert_equal "tadasant/zimmer", probe.repo
    assert_equal [ 500 ], probe.merged_references.map(&:number)
    assert_equal [ 501 ], probe.open_references.map(&:number)
    assert_equal Time.iso8601("2026-09-09T00:00:00Z"), probe.open_references.first.updated_at
  end

  test "a closed issue reads as closed" do
    probes = probe_with(response(i0: issue(1, "CLOSED", [])))

    assert_not probes.fetch(1).open?
  end

  # A cross-reference from an issue, or from a repository the token cannot see,
  # arrives as an empty object. It is not a pull request we can say anything
  # about, so it must not become a reference.
  test "a cross-reference with no pull request behind it is skipped" do
    probes = probe_with(response(i0: issue(1, "OPEN", [ pr(500, "OPEN", "2026-09-09T00:00:00Z") ], extra: [ {} ])))

    assert_equal [ 500 ], probes.fetch(1).references.map(&:number)
  end

  # GraphQL answers a batch partially: one deleted issue number puts a NOT_FOUND in
  # `errors` and makes `gh` exit non-zero, while every other issue in the response
  # is correct. Throwing that away would blind the sweep to a whole repo.
  test "keeps the issues a partially-failed batch did return, and omits the one it did not" do
    payload = response(i0: issue(1, "OPEN", []))
    payload["data"]["repository"]["i1"] = nil
    payload["errors"] = [ { "type" => "NOT_FOUND", "message" => "Could not resolve to an Issue" } ]

    probes = probe_with(payload, success: false)

    assert_equal [ 1 ], probes.keys
    assert_not probes.key?(2), "a number GitHub could not resolve is absent, never nil"
  end

  test "raises rather than answering when the response cannot be parsed at all" do
    assert_raises(Github::IssueLinkProbe::ProbeError) do
      probe_with_raw("not json", success: false)
    end
  end

  test "raises when the response carries no repository" do
    assert_raises(Github::IssueLinkProbe::ProbeError) do
      probe_with({ "data" => { "repository" => nil } })
    end
  end

  test "refuses a repo that is not owner/name" do
    assert_raises(Github::IssueLinkProbe::ProbeError) do
      Github::IssueLinkProbe.call(repo: "zimmer", numbers: [ 1 ])
    end
  end

  test "asks for every issue in one request per batch" do
    calls = []
    stub = lambda do |argv, **|
      calls << argv
      cli_result(JSON.generate(response(i0: issue(1, "OPEN", []))), success: true)
    end

    GithubCli.stub(:run, stub) do
      Github::IssueLinkProbe.call(repo: "tadasant/zimmer", numbers: (1..(Github::IssueLinkProbe::BATCH_SIZE + 1)).to_a)
    end

    assert_equal 2, calls.size, "one request per BATCH_SIZE issues"
    assert_includes calls.first.join(" "), "issue(number: 1)"
  end

  test "a reference with no updatedAt counts as idle rather than moving" do
    probes = probe_with(response(i0: issue(1, "OPEN", [ pr(500, "OPEN", nil) ])))

    assert probes.fetch(1).open_references.first.idle?(14.days)
  end

  private

  def issue(number, state, prs, extra: [])
    nodes = prs.map { |source| { "source" => source } } + extra
    { "number" => number, "state" => state, "timelineItems" => { "nodes" => nodes } }
  end

  def pr(number, state, updated_at)
    { "number" => number, "state" => state, "updatedAt" => updated_at }
  end

  def response(**issues)
    { "data" => { "repository" => issues.transform_keys(&:to_s) } }
  end

  def probe_with(payload, success: true)
    probe_with_raw(JSON.generate(payload), success: success)
  end

  def probe_with_raw(stdout, success: true)
    GithubCli.stub(:run, ->(*, **) { cli_result(stdout, success: success) }) do
      Github::IssueLinkProbe.call(repo: "tadasant/zimmer", numbers: [ 1 ])
    end
  end

  def cli_result(stdout, success:)
    Struct.new(:stdout, :success?, :failure_description, keyword_init: false)
          .new(stdout, success, "exit 1")
  end
end
