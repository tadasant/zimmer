# frozen_string_literal: true

require "test_helper"
require "support/fake_parameter_store"

class ManagedSecretTest < ActiveSupport::TestCase
  VARIABLE = ManagedSecret::OPENROUTER_API_KEY
  VALUE = "sk-or-v1-0123456789abcdef"

  setup do
    @fake = FakeParameterStore.new
    @fake.held_permissions = ParameterStore::Capabilities::PROBED_PERMISSIONS
    @chain = @fake.chain
    # Verification retries with a sleep between attempts; nothing here is
    # eventually consistent, so the first read always answers.
    @secret = build
  end

  def build(writer: writer_configuration)
    ManagedSecret.new(VARIABLE, chain: @chain, writer: writer)
  end

  def writer_configuration(client: @fake.write_client, identity: :writer, reason: nil)
    ParameterStore::Writer::Configuration.new(client: client, identity: identity, reason: reason)
  end

  # --- the property this class exists to hold --------------------------------

  test "nothing ManagedSecret exposes carries the value" do
    @secret.write(VALUE)

    status = @secret.status
    haystack = status.to_h.values.map(&:to_s).join(" ")

    assert status.present?, "precondition: the key is set"
    assert_no_match(/#{Regexp.escape(VALUE)}/, haystack)
    # Not even a fragment of it. A last-four mask would fail this.
    VALUE.chars.each_cons(6).map(&:join).uniq.each do |fragment|
      assert_no_match(/#{Regexp.escape(fragment)}/, haystack,
        "status leaked the substring #{fragment.inspect} of the stored value")
    end
  end

  test "no public method returns the value" do
    @secret.write(VALUE)

    returned = (ManagedSecret.public_instance_methods(false) - [ :write, :delete ]).map do |method|
      @secret.public_send(method).to_s
    end

    assert_not_includes returned, VALUE
    assert_no_match(/#{Regexp.escape(VALUE)}/, returned.join(" "))
  end

  test "a successful write reports a fingerprint, and the fingerprint is a digest" do
    result = @secret.write(VALUE)

    assert result.ok?, result.message
    digest = Digest::SHA256.hexdigest(VALUE)[0, ManagedSecret::FINGERPRINT_LENGTH]
    assert_equal digest, @secret.status.fingerprint
    assert_no_match(/#{Regexp.escape(VALUE[0, 8])}/, digest)
  end

  test "the fingerprint distinguishes two keys" do
    @secret.write(VALUE)
    first = @secret.status.fingerprint

    @secret.write("sk-or-v1-something-else-entirely")

    assert_not_equal first, @secret.status.fingerprint
  end

  # --- status ----------------------------------------------------------------

  test "an unset key reports not present, with no fingerprint" do
    status = @secret.status

    assert_not status.present?
    assert_nil status.fingerprint
    assert_nil status.last_write
  end

  test "status names the address without naming the value" do
    status = @secret.status

    assert_equal ParameterStore::Namespace.parameter_path(VARIABLE), status.path
    assert_equal FakeParameterStore::PROJECT, status.project_id
  end

  test "a key set outside Zimmer still shows as set, with no local write record" do
    @fake.seed_secret(VARIABLE, VALUE)

    status = @secret.status

    assert status.present?
    assert_equal SecretProviders::ParameterStoreProvider::BADGE, status.provider_badge
    assert_nil status.last_write, "Zimmer did not write it, and must not claim it did"
  end

  # --- writing ---------------------------------------------------------------

  test "a write is readable through the ordinary resolution chain" do
    assert @secret.write(VALUE).ok?

    assert_equal VALUE, @chain.get(VARIABLE)
  end

  test "a write records an audit row holding a digest and not the value" do
    @secret.write(VALUE)

    row = ManagedSecretWrite.last_success(VARIABLE)
    assert_equal ManagedSecretWrite::CREATED, row.action
    assert_equal Digest::SHA256.hexdigest(VALUE)[0, ManagedSecret::FINGERPRINT_LENGTH], row.fingerprint
    assert_no_match(/#{Regexp.escape(VALUE)}/, row.attributes.values.map(&:to_s).join(" "))
  end

  test "a blank value is refused before anything reaches the store" do
    result = @secret.write("   ")

    assert_not result.ok?
    assert_empty @fake.secrets
    assert_empty ManagedSecretWrite.all
  end

  # --- the trap: written, and never readable ---------------------------------

  # The forgotten `add-iam-policy-binding`, modelled exactly: every call Google
  # is asked to make succeeds, the bytes are genuinely in Secret Manager, and the
  # parameter still cannot dereference them. This is the documented trap — a
  # write that is accepted and never readable by Zimmer.
  class UnbindingWriteClient < SimpleDelegator
    def initialize(client, fake)
      super(client)
      @fake = fake
    end

    def upsert(variable, value, **kwargs)
      id = __getobj__.upsert(variable, value, **kwargs)
      @fake.revoke_parameter_binding!(variable)
      id
    end
  end

  test "a write Zimmer cannot read back is reported as a failure, not a save" do
    broken = build(writer: writer_configuration(client: UnbindingWriteClient.new(@fake.write_client, @fake)))

    result = broken.write(VALUE)

    assert_not result.ok?
    assert_match(/cannot read it back/, result.message)
    assert_match(/do not assume it works/, result.message)
    assert_match(/IAM binding/, result.detail)
  end

  test "an unverifiable write is recorded as failed, so the page does not claim a last-set time" do
    build(writer: writer_configuration(client: UnbindingWriteClient.new(@fake.write_client, @fake))).write(VALUE)

    assert_nil ManagedSecretWrite.last_success(VARIABLE)
    assert_equal ManagedSecretWrite::FAILED, ManagedSecretWrite.last.outcome
  end

  test "a store that refuses the write says so and records the attempt" do
    secret = build
    assert secret.status.writable?, "precondition: the permissions probe has answered"
    @fake.fail_with!(403)

    result = secret.write("sk-or-v1-rejected")

    assert_not result.ok?
    assert_match(/refused the write/, result.message)
    assert_equal ManagedSecretWrite::FAILED, ManagedSecretWrite.last.outcome
  end

  # --- permissions -----------------------------------------------------------

  test "with no writer credential the write path is closed and named" do
    closed = build(writer: ParameterStore::Writer::Configuration.new(
      client: nil, identity: nil, reason: "ZIMMER_PARAMS_PROJECT_ID is not set"
    ))

    assert_not closed.status.writable?
    assert_match(/ZIMMER_PARAMS_PROJECT_ID/, closed.status.write_reason)
    assert_not closed.write(VALUE).ok?
    assert_empty @fake.secrets, "a refusal must not reach the store"
  end

  test "a read-only credential is refused, and the missing permissions are named" do
    @fake.held_permissions = [
      ParameterStore::Capabilities::RENDER_PARAMETER,
      ParameterStore::Capabilities::READ_SECRET_VALUE
    ]

    status = build.status

    assert_not status.writable?
    assert_includes status.missing_permissions, ParameterStore::Capabilities::CREATE_SECRET
    assert_includes status.missing_permissions, ParameterStore::Capabilities::BIND_SECRET
    assert_match(/writer credential is missing/, status.write_reason)
  end

  test "the resolver's own credential is named as the resolver, not as a writer" do
    @fake.held_permissions = [ ParameterStore::Capabilities::RENDER_PARAMETER ]

    status = build(writer: writer_configuration(identity: :resolver)).status

    assert_match(/resolver credential is missing/, status.write_reason)
  end

  test "an unprobeable credential fails closed rather than open" do
    @fake.fail_with!(500)

    status = build.status

    assert_not status.writable?
    assert_not status.deletable?
    assert_match(/could not be confirmed/, status.write_reason)
  end

  # --- deleting --------------------------------------------------------------

  test "delete removes the key and the variable stops resolving" do
    @secret.write(VALUE)

    result = build.delete

    assert result.ok?, result.message
    assert_nil @chain.get(VARIABLE)
    assert_not build.status.present?
  end

  test "delete is refused without the delete permissions" do
    @secret.write(VALUE)
    @fake.held_permissions = ParameterStore::Capabilities::UPSERT_PERMISSIONS

    status = build.status
    assert status.writable?
    assert_not status.deletable?
    assert_not build.delete.ok?
    assert_equal VALUE, @chain.get(VARIABLE), "the refused delete must not have removed anything"
  end
end
