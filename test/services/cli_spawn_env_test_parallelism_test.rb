# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The demand half of tadasant/zimmer#981.
#
# Eight concurrent agent sessions each ran a parallel Rails suite on 2026-09-05, and
# between them held 41 `ruby` processes and 8.7 GB of anonymous memory against a worker
# container capped at 10 GiB. Every session was inside its own 4 GiB bound; the kernel
# OOM-killed the Rails worker instead. Rails sizes `parallelize` off the processor count,
# which inside the container is the whole droplet's, so each session sizes itself as
# though it had the box to itself.
class CliSpawnEnvTestParallelismTest < ActiveSupport::TestCase
  # Minimal host for the shared module, matching what the real adapters expose.
  class Host
    include CliSpawnEnv

    def initialize(logger:)
      @logger = logger
    end

    def apply!(env_vars) = apply_test_parallelism(env_vars)
  end

  VAR = "ZIMMER_SESSION_PARALLEL_WORKERS"

  setup do
    @original = ENV[VAR]
    ENV.delete(VAR)
    @logger = stub_everything("logger")
  end

  teardown do
    @original.nil? ? ENV.delete(VAR) : ENV[VAR] = @original
  end

  test "caps the parallel test workers a session forks" do
    env = Host.new(logger: @logger).apply!({})

    assert_equal CliSpawnEnv::DEFAULT_TEST_PARALLELISM.to_s, env["PARALLEL_WORKERS"]
  end

  test "the cap is configured at deploy time" do
    ENV[VAR] = "3"

    assert_equal "3", Host.new(logger: @logger).apply!({})["PARALLEL_WORKERS"]
  end

  # The break-glass: a session then sizes itself off the processor count, as it did
  # before this existed.
  test "zero turns the cap off rather than setting it to zero" do
    ENV[VAR] = "0"

    assert_not Host.new(logger: @logger).apply!({}).key?("PARALLEL_WORKERS"),
      "PARALLEL_WORKERS=0 would tell Rails to run no test workers at all"
  end

  # A repo whose suite genuinely needs more is the operator's call, and the per-clone
  # `.env` is where they say so.
  test "a value from the session .env wins" do
    env = Host.new(logger: @logger).apply!("PARALLEL_WORKERS" => "8")

    assert_equal "8", env["PARALLEL_WORKERS"]
  end

  # An unparseable value falls back to the default rather than to "off": the failure mode
  # of off is a worker OOM, and the failure mode of 2 is a slower test run.
  test "an unparseable or negative setting falls back to the default" do
    [ "two", "-1", "" ].each do |value|
      ENV[VAR] = value

      assert_equal CliSpawnEnv::DEFAULT_TEST_PARALLELISM.to_s,
        Host.new(logger: @logger).apply!({})["PARALLEL_WORKERS"],
        "#{value.inspect} should not have changed the cap"
    end
  end
end
