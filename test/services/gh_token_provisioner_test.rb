# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GhTokenProvisionerTest < ActiveSupport::TestCase
  VAR = GhTokenProvisioner::VARIABLE

  setup do
    @original_env = ENV[VAR]
    ENV.delete(VAR)
    GhTokenProvisioner.reset!
    SecretProviders.reset!
  end

  teardown do
    if @original_env.nil?
      ENV.delete(VAR)
    else
      ENV[VAR] = @original_env
    end
    GhTokenProvisioner.reset!
    SecretProviders.reset!
  end

  test "publishes a token resolved from the chain into ENV" do
    stub_chain_returning("gho_from_the_store")

    assert_equal "gho_from_the_store", GhTokenProvisioner.ensure!
    assert_equal "gho_from_the_store", ENV[VAR]
  end

  test "is a no-op when nothing in the chain has the variable" do
    stub_chain_returning(nil)

    assert_nil GhTokenProvisioner.ensure!
    assert_nil ENV[VAR]
  end

  test "treats a blank value as nothing configured rather than publishing it" do
    stub_chain_returning("")

    assert_nil GhTokenProvisioner.ensure!
    assert_nil ENV[VAR]
  end

  test "picks up a rotation once the refresh clock is due" do
    chain = stub_chain_returning("gho_first")
    GhTokenProvisioner.ensure!
    assert_equal "gho_first", ENV[VAR]

    chain.stubs(:get).with(VAR).returns("gho_second")

    assert_equal "gho_second", GhTokenProvisioner.ensure!(force: true)
    assert_equal "gho_second", ENV[VAR]
  end

  # The poller calls this every minute. Consulting the chain each time would re-resolve
  # the whole namespace on any environment whose store does not hold GH_TOKEN.
  test "consults the chain at most once per refresh interval" do
    chain = mock("chain")
    chain.expects(:get).with(VAR).returns("gho_once").once
    SecretProviders.stubs(:chain).returns(chain)

    5.times { GhTokenProvisioner.ensure! }

    assert_equal "gho_once", ENV[VAR]
  end

  test "force bypasses the refresh clock" do
    chain = mock("chain")
    chain.expects(:get).with(VAR).returns("gho_forced").twice
    SecretProviders.stubs(:chain).returns(chain)

    GhTokenProvisioner.ensure!
    GhTokenProvisioner.ensure!(force: true)
  end

  test "is idempotent: re-resolving the same value leaves ENV untouched" do
    stub_chain_returning("gho_same")

    3.times { GhTokenProvisioner.ensure!(force: true) }

    assert_equal "gho_same", ENV[VAR]
  end

  # The chain deliberately does NOT fall through to a lower provider when a backend
  # fails, so a store outage arrives here as an exception. Blanking a working
  # credential over a transient outage would take gh auth down with the store.
  test "keeps the existing environment when the chain raises" do
    ENV[VAR] = "gho_already_here"
    stub_chain_raising

    assert_equal "gho_already_here", GhTokenProvisioner.ensure!
    assert_equal "gho_already_here", ENV[VAR]
  end

  test "returns nil when the chain raises with no token in hand" do
    stub_chain_raising

    assert_nil GhTokenProvisioner.ensure!
    assert_nil ENV[VAR]
  end

  # A resolver that is permanently misconfigured must not log once a minute forever.
  test "a failure arms the refresh clock, so it does not retry on every call" do
    chain = mock("chain")
    chain.expects(:get).with(VAR).raises(store_error).once
    SecretProviders.stubs(:chain).returns(chain)

    5.times { GhTokenProvisioner.ensure! }
  end

  test "never writes the token value into the log" do
    stub_chain_raising
    ENV[VAR] = "gho_secret_value"

    io = StringIO.new
    GhTokenProvisioner.ensure!(logger: Logger.new(io))

    assert_no_match(/gho_secret_value/, io.string)
    assert_match(/Could not resolve #{VAR}/, io.string)
  end

  # ENV is the chain's last link, so a plain `GH_TOKEN=…` (dev, a self-hoster, an
  # environment with no store wired) must keep working. Built from an explicit hash
  # rather than the real ENV so the test cannot be perturbed by a host that happens to
  # export ZIMMER_PARAMS_* and reach a live store.
  test "an ENV-only token survives a real chain with no store configured" do
    SecretProviders.stubs(:chain).returns(SecretProviders.build(env: { VAR => "gho_from_plain_env" }))

    assert_equal "gho_from_plain_env", GhTokenProvisioner.ensure!
    assert_equal "gho_from_plain_env", ENV[VAR]
  end

  private

  def store_error
    ParameterStore::StoreError.new("parameter render failed", 503)
  end

  def stub_chain_returning(value)
    chain = mock("chain")
    chain.stubs(:get).with(VAR).returns(value)
    SecretProviders.stubs(:chain).returns(chain)
    chain
  end

  def stub_chain_raising
    chain = mock("chain")
    chain.stubs(:get).with(VAR).raises(store_error)
    SecretProviders.stubs(:chain).returns(chain)
    chain
  end
end
