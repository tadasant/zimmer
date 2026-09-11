# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The authentication decision behind every API and MCP request (tadasant/zimmer#46).
#
# The load-bearing property is the cutover: a key in API_KEYS that authenticated
# before this table existed must still authenticate after it, with nothing
# re-provisioned — every agent session holds one.
class ApiKeyTest < ActiveSupport::TestCase
  setup do
    @original_env = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = "env-key-one, env-key-two"
  end

  teardown do
    @original_env.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @original_env
  end

  def fingerprint(key) = Digest::SHA256.hexdigest(key)[0, 8]

  # --- API_KEYS entries: the cutover ---

  test "an API_KEYS entry authenticates and gets a row named after its fingerprint" do
    assert_difference -> { ApiKey.count }, 1 do
      result = ApiKey.authenticate("env-key-two")

      assert_predicate result, :authenticated?
      assert_equal "API_KEYS #{fingerprint('env-key-two')}", result.api_key.name
      assert_predicate result.api_key, :env?
      assert_predicate result.api_key, :persisted?
    end
  end

  test "an API_KEYS entry is registered once, however often it authenticates" do
    ApiKey.authenticate("env-key-one")

    assert_no_difference -> { ApiKey.count } do
      3.times { assert_predicate ApiKey.authenticate("env-key-one"), :authenticated? }
    end
  end

  test "the row stores a digest of the key and never the key" do
    api_key = ApiKey.authenticate("env-key-one").api_key

    assert_equal Digest::SHA256.hexdigest("env-key-one"), api_key.token_digest
    refute(ApiKey.column_names.any? { |column| api_key.read_attribute(column).to_s.include?("env-key-one") })
  end

  test "API_KEYS is re-read on every call, so a key added to the variable works without a restart" do
    refute_predicate ApiKey.authenticate("added-later"), :authenticated?

    ENV[ApiKey::ENV_VAR] = "env-key-one,added-later"

    assert_predicate ApiKey.authenticate("added-later"), :authenticated?
  end

  test "an env row stops authenticating once its key leaves API_KEYS" do
    ApiKey.authenticate("env-key-one")
    ENV[ApiKey::ENV_VAR] = "env-key-two"

    result = ApiKey.authenticate("env-key-one")

    refute_predicate result, :authenticated?
    assert_equal :retired, result.refusal
    assert_predicate result.api_key, :retired?
  end

  test "a failed registration still authenticates the API_KEYS entry, as it did before this table existed" do
    ApiKey.stubs(:create!).raises(ActiveRecord::StatementInvalid, "PG::ReadOnlySqlTransaction")

    entries = capture_log_entries do
      result = ApiKey.authenticate("env-key-one")

      assert_predicate result, :authenticated?
      assert_predicate result.api_key, :new_record?
      assert_equal "API_KEYS #{fingerprint('env-key-one')}", result.api_key.name
    end

    assert(entries.any? { |severity, message| severity == "WARN" && message.include?("authenticating it without one") })
  end

  test "a name taken by another row gives the entry its full digest as a name, so it is still listed and revocable" do
    taken = "API_KEYS #{fingerprint('env-key-one')}"
    ApiKey.create!(name: taken, source: ApiKey::ENV_SOURCE, token_digest: ApiKey.digest("something-else"))

    api_key = ApiKey.authenticate("env-key-one").api_key

    assert_predicate api_key, :persisted?
    assert_equal "API_KEYS #{ApiKey.digest('env-key-one')}", api_key.name
    api_key.revoke!
    assert_equal :revoked, ApiKey.authenticate("env-key-one").refusal
  end

  test "losing the registration race returns the winner's row, quietly" do
    winner = ApiKey.create!(name: "API_KEYS #{fingerprint('env-key-one')}", source: ApiKey::ENV_SOURCE,
      token_digest: ApiKey.digest("env-key-one"))

    # What a second worker does when its find_by ran before the winner committed.
    entries = capture_log_entries do
      assert_equal winner, ApiKey.send(:register_env_key, ApiKey.digest("env-key-one"))
    end

    assert_empty(entries.select { |severity, _message| severity == "WARN" })
  end

  test "the unique index settles a race the validation cannot see" do
    ApiKey.create!(name: "API_KEYS #{fingerprint('env-key-one')}", source: ApiKey::ENV_SOURCE,
      token_digest: ApiKey.digest("env-key-one"))
    ApiKey.any_instance.stubs(:valid?).returns(true)

    assert_predicate ApiKey.send(:register_env_key, ApiKey.digest("env-key-one")), :persisted?
  end

  test "register_env_keys gives every entry a row and is idempotent" do
    assert_difference -> { ApiKey.count }, 2 do
      ApiKey.register_env_keys
      ApiKey.register_env_keys
    end
  end

  # --- Minted keys ---

  test "a minted key authenticates, and only its digest is kept" do
    api_key, token = ApiKey.mint!(name: "laptop scripts")

    assert token.start_with?(ApiKey::MINTED_PREFIX)
    assert_equal ApiKey.digest(token), api_key.reload.token_digest
    assert_equal api_key, ApiKey.authenticate(token).api_key
  end

  test "names are unique regardless of case" do
    ApiKey.mint!(name: "Laptop")

    error = assert_raises(ActiveRecord::RecordInvalid) { ApiKey.mint!(name: "laptop") }
    assert_match(/Name has already been taken/, error.message)
  end

  test "a minted key cannot take the prefix env rows are named with, in any case" do
    [ "API_KEYS deadbeef", "api_keys deadbeef" ].each do |name|
      error = assert_raises(ActiveRecord::RecordInvalid) { ApiKey.mint!(name: name) }
      assert_match(/can't start with "API_KEYS"/, error.message)
    end
  end

  test "a name cannot carry control or formatting characters" do
    [ "two\nlines", "bidi\u202Eoverride", "tab\there" ].each do |name|
      error = assert_raises(ActiveRecord::RecordInvalid) { ApiKey.mint!(name: name) }
      assert_match(/control or formatting characters/, error.message)
    end
  end

  # --- Refusals ---

  test "a missing or unknown key is refused without a row" do
    assert_equal :missing, ApiKey.authenticate(nil).refusal
    assert_equal :missing, ApiKey.authenticate("").refusal

    assert_no_difference -> { ApiKey.count } do
      result = ApiKey.authenticate("never-issued")
      assert_equal :unknown, result.refusal
      assert_nil result.api_key
    end
  end

  test "a revoked key is refused on the very next call, and a restored one authenticates again" do
    api_key, token = ApiKey.mint!(name: "revoke me")
    assert_predicate ApiKey.authenticate(token), :authenticated?

    api_key.revoke!
    result = ApiKey.authenticate(token)
    assert_equal :revoked, result.refusal
    assert_equal api_key, result.api_key

    api_key.restore!
    assert_predicate ApiKey.authenticate(token), :authenticated?
  end

  test "revoking an API_KEYS entry sticks while the key is still in the variable" do
    ApiKey.register_env_keys
    ApiKey.authenticate("env-key-one").api_key.revoke!

    assert_no_difference -> { ApiKey.count } do
      assert_equal :revoked, ApiKey.authenticate("env-key-one").refusal
      ApiKey.register_env_keys
    end
    assert_equal :revoked, ApiKey.authenticate("env-key-one").refusal
  end

  # --- last_used_at ---

  test "last_used_at is stamped on use, at most once per resolution" do
    api_key, token = ApiKey.mint!(name: "busy")
    assert_nil api_key.last_used_at

    travel_to Time.zone.parse("2026-09-11 12:00:00") do
      ApiKey.authenticate(token)
      assert_equal Time.current, api_key.reload.last_used_at
    end

    travel_to Time.zone.parse("2026-09-11 12:00:30") do
      ApiKey.authenticate(token)
      assert_equal Time.zone.parse("2026-09-11 12:00:00"), api_key.reload.last_used_at
    end

    travel_to Time.zone.parse("2026-09-11 12:01:05") do
      ApiKey.authenticate(token)
      assert_equal Time.current, api_key.reload.last_used_at
    end
  end

  test "stamping last_used_at leaves updated_at alone" do
    api_key, token = ApiKey.mint!(name: "quiet")
    updated_at = api_key.updated_at

    travel 1.hour do
      ApiKey.authenticate(token)
    end

    assert_equal updated_at, api_key.reload.updated_at
  end

  test "a failed last_used_at stamp is logged, not raised" do
    api_key, _token = ApiKey.mint!(name: "stamp fails")
    ApiKey.stubs(:where).raises(ActiveRecord::StatementInvalid, "boom")

    entries = capture_log_entries { api_key.record_use! }

    assert_nil api_key.last_used_at
    assert(entries.any? { |severity, message| severity == "WARN" && message.include?("could not stamp last_used_at") })
  end

  # --- Display ---

  test "the fingerprint is the prefix sha256sum prints" do
    api_key = ApiKey.authenticate("env-key-one").api_key

    assert_equal Digest::SHA256.hexdigest("env-key-one")[0, 8], api_key.fingerprint
  end

  test "self_session_key? matches only the digest it is given" do
    api_key = ApiKey.authenticate("env-key-one").api_key

    assert api_key.self_session_key?(ApiKey.digest("env-key-one"))
    refute api_key.self_session_key?(ApiKey.digest("env-key-two"))
    refute api_key.self_session_key?(nil)
  end
end
