# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class GhTokenProvisionerTest < ActiveSupport::TestCase
  VAR = GhTokenProvisioner::VARIABLE

  ROUTING = GithubTokens::ROUTING_VARIABLE
  REQUIRE = GhTokenProvisioner::REQUIRE_FINE_GRAINED_VARIABLE
  PULSEMCP = "GH_TOKEN__PULSEMCP"

  setup do
    @managed = [ VAR, ROUTING, REQUIRE, PULSEMCP ]
    @original_env = @managed.to_h { |key| [ key, ENV[key] ] }
    @managed.each { |key| ENV.delete(key) }
    GhTokenProvisioner.reset!
    SecretProviders.reset!
  end

  teardown do
    @original_env.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
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
    assert_match(/Could not resolve the GitHub tokens/, io.string)
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

  # --- the token map ---------------------------------------------------------

  test "publishes every GH_TOKEN__<OWNER> the chain holds, beside the default" do
    stub_real_chain(VAR => "github_pat_default", PULSEMCP => "github_pat_pulsemcp", "UNRELATED" => "x")

    assert_equal "github_pat_default", GhTokenProvisioner.ensure!
    assert_equal "github_pat_default", ENV[VAR]
    assert_equal "github_pat_pulsemcp", ENV[PULSEMCP]
    assert_equal "1", ENV[ROUTING], "a published token turns routing on"
  end

  test "an owner token alone turns routing on" do
    stub_real_chain(PULSEMCP => "github_pat_pulsemcp")

    assert_nil GhTokenProvisioner.ensure!
    assert_equal "github_pat_pulsemcp", ENV[PULSEMCP]
    assert_equal "1", ENV[ROUTING]
  end

  # The backward-compatible deploy: production has no token yet, and its stored
  # `gh auth login` must keep authenticating git — which the helper does only while
  # the routing flag is down.
  test "with no token anywhere, routing stays off" do
    ENV[ROUTING] = "1"
    stub_real_chain({})

    assert_nil GhTokenProvisioner.ensure!
    assert_nil ENV[ROUTING]
  end

  # --- the fine-grained guard -------------------------------------------------

  test "the guard is on in production and off elsewhere by default" do
    refute GhTokenProvisioner.require_fine_grained?(env: {})
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
    assert GhTokenProvisioner.require_fine_grained?(env: {})
    refute GhTokenProvisioner.require_fine_grained?(env: { REQUIRE => "false" })
  end

  test "the guard refuses a token that is not fine-grained, naming the owner and never the value" do
    ENV[REQUIRE] = "true"
    stub_real_chain(VAR => "github_pat_default", PULSEMCP => "gho_oauth_reaches_every_org")
    io = StringIO.new

    GhTokenProvisioner.ensure!(logger: Logger.new(io))

    assert_equal "github_pat_default", ENV[VAR]
    assert_nil ENV[PULSEMCP], "a refused token is not published"
    assert_match(/Refusing #{PULSEMCP} \(owner pulsemcp\): an OAuth token \(gho_\)/, io.string)
    assert_no_match(/gho_oauth_reaches_every_org/, io.string)
  end

  # A refused GH_TOKEN that was already in the environment — a deploy-time export —
  # would otherwise keep authenticating every `gh` call: refusing it means removing it.
  test "a refused token sitting in ENV is removed from it" do
    ENV[REQUIRE] = "true"
    ENV[VAR] = "ghp_classic"
    SecretProviders.stubs(:chain).returns(SecretProviders.build(env: ENV))

    assert_nil GhTokenProvisioner.ensure!(logger: Logger.new(StringIO.new))
    assert_nil ENV[VAR]
    assert_nil ENV[ROUTING], "nothing was accepted, so the stored login still answers"
  end

  test "with the guard off, a classic token is published as before" do
    ENV[REQUIRE] = "false"
    stub_real_chain(VAR => "ghp_staging_test_account")

    assert_equal "ghp_staging_test_account", GhTokenProvisioner.ensure!
    assert_equal "1", ENV[ROUTING]
  end

  private

  # A real chain over an explicit hash, so discovery runs through Chain#names.
  def stub_real_chain(values)
    SecretProviders.stubs(:chain).returns(SecretProviders::Chain.new([ SecretProviders::Env.new(values) ]))
  end

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
