# frozen_string_literal: true

# One store-backed `${VAR}` that Zimmer itself may create, rotate and delete —
# and may never read back out.
#
# ## The property this class exists to hold
#
# **A value that goes in here does not come out.** There is no accessor for it,
# no method that returns it, and nothing in {#status} derived from it that a
# reader could invert. The value appears in exactly two places: the argument to
# {#write}, and the local inside {#verify} that compares a fingerprint. Both are
# gone when the method returns.
#
# {#status} is what the UI renders, and it is a fixed, small shape: is it set,
# which link of the SecretProviders chain holds it, a truncated SHA-256, and what
# Zimmer's own write log says. The digest is the interesting one — it is not the
# value and not a prefix of it, so it tells a reader who already has a candidate
# key whether the store holds that key, and tells a reader who does not exactly
# nothing. A last-four-characters mask would have leaked four characters; this
# leaks none, and answers a more useful question.
#
# ## Why there is no MCP tool for this
#
# Zimmer's capabilities are normally reachable from both the web UI and the MCP
# surface, and a gap between them is usually a defect. This one is deliberate.
# Setting a key means passing its VALUE as an argument, and an MCP tool argument
# lands in an agent's context and its transcript — which is precisely what the
# deployment's secrets posture forbids ("never by handing the value to an
# agent"). So the write half is a human affordance and stays one.
#
# The READ half is already covered and needs no new tool: Pi's credential shows up
# in `CliStatusService`, which `get_system_health(include_cli_status: true)` and
# `GET /api/v1/clis` both serialize, so a session can learn whether the key is set
# without any surface being able to tell it what the key is.
#
# ## Why a write is verified by reading
#
# The documented trap for this store is a write that is accepted and never read
# by Zimmer — a value in the wrong project, or a parameter with no IAM binding
# letting it dereference its own secret, both of which report success and then
# resolve to nothing forever (see SecretsLocation, and
# docs/operate/secrets-parameter-store "Why step 3 exists"). So {#write} is not
# finished when Google returns 200: it invalidates the resolver's snapshot,
# reads the variable back through the ordinary resolution chain, and compares
# digests. A write that cannot be read back is reported as a FAILURE, loudly,
# with the value already in the store — which is the honest answer, because that
# is the state the deployment is now in.
class ManagedSecret
  # A truncated SHA-256. 12 hex characters is 48 bits: ample to tell two keys
  # apart by eye, and useless for recovering one.
  FINGERPRINT_LENGTH = 12

  # Read-back is not instantaneous — the resolver reads a whole-namespace
  # snapshot and Parameter Manager is eventually consistent across the
  # create/addVersion pair. A handful of quick retries covers the gap without
  # making Save feel like it hung.
  VERIFY_ATTEMPTS = 4
  VERIFY_BACKOFF = 0.4

  Result = Struct.new(:ok, :message, :detail, keyword_init: true) do
    def ok? = !!ok
  end

  # Everything the Pi tab renders. Deliberately a plain, closed struct: a hash
  # of whatever happened to be handy is how a value ends up on a page by
  # accident.
  Status = Struct.new(
    :variable, :present, :provider_label, :provider_badge, :fingerprint,
    :path, :project_id, :location, :last_write,
    :writable, :deletable, :write_reason, :missing_permissions, :writer_identity,
    keyword_init: true
  ) do
    def present? = !!present
    def writable? = !!writable
    def deletable? = !!deletable
  end

  # Pi resolves a provider credential per request from the session environment.
  # OpenRouter is a first-class provider in the pinned Pi (`OPENROUTER_API_KEY`
  # in its provider table), and the one Zimmer is set up to feed it.
  OPENROUTER_API_KEY = "OPENROUTER_API_KEY"

  def self.openrouter_key(**kwargs) = new(OPENROUTER_API_KEY, **kwargs)

  attr_reader :variable

  def initialize(variable, chain: SecretProviders.chain, writer: ParameterStore::Writer.from_env)
    @variable = variable
    @chain = chain
    @writer = writer
  end

  # @return [Status] never carries the value, by construction.
  def status
    provider = provider_for
    store = parameter_store_provider
    capabilities = @writer.configured? ? write_capabilities : nil

    Status.new(
      variable: variable,
      present: !provider.nil?,
      provider_label: provider&.label,
      provider_badge: provider&.badge,
      fingerprint: fingerprint_of(read_value),
      path: store&.path_for(variable),
      project_id: store&.project_id,
      location: store&.location,
      last_write: ManagedSecretWrite.last_success(variable),
      writer_identity: @writer.identity,
      writable: !capabilities.nil? && capabilities.can_upsert?,
      deletable: !capabilities.nil? && capabilities.can_delete?,
      write_reason: write_reason(capabilities),
      missing_permissions: capabilities&.probed? ? capabilities.missing_for_upsert : []
    )
  end

  # Create or rotate the value.
  #
  # @param value [String] never logged, never returned, never stored anywhere
  #   but the store itself.
  # @return [Result]
  def write(value)
    value = value.to_s
    return Result.new(ok: false, message: "Paste a key first — nothing was sent to the store.") if value.strip.empty?

    capabilities = @writer.configured? ? write_capabilities : nil
    unless capabilities&.can_upsert?
      return refusal(ManagedSecretWrite::CREATED, capabilities)
    end

    digest = fingerprint_of(value)
    @writer.client.upsert(variable, value)
    verified, detail = verify(expected: value)

    record(ManagedSecretWrite::CREATED, ok: verified, fingerprint: digest, detail: detail)

    if verified
      Result.new(ok: true, message: "#{variable} saved and read back from #{store_name}.", detail: "Fingerprint #{digest}.")
    else
      Result.new(ok: false, detail: detail,
        message: "#{variable} was written to #{store_name} but Zimmer cannot read it back. " \
                 "The value is in the store and is not reaching sessions — do not assume it works.")
    end
  rescue ParameterStore::AuthError, ParameterStore::StoreError => e
    record(ManagedSecretWrite::CREATED, ok: false, detail: e.message)
    Result.new(ok: false, message: "#{store_name} refused the write.", detail: e.message)
  end

  # @return [Result]
  def delete
    capabilities = @writer.configured? ? write_capabilities : nil
    unless capabilities&.can_delete?
      return refusal(ManagedSecretWrite::DELETED, capabilities)
    end

    @writer.client.delete(variable)
    gone, detail = verify(expected: nil)

    record(ManagedSecretWrite::DELETED, ok: gone, detail: detail)

    if gone
      Result.new(ok: true, message: "#{variable} deleted from #{store_name}.")
    else
      Result.new(ok: false, detail: detail,
        message: "#{variable} was deleted from #{store_name} but still resolves — " \
                 "another link of the chain is holding a copy.")
    end
  rescue ParameterStore::AuthError, ParameterStore::StoreError => e
    record(ManagedSecretWrite::DELETED, ok: false, detail: e.message)
    Result.new(ok: false, message: "#{store_name} refused the delete.", detail: e.message)
  end

  private

  # Read the variable back through the ORDINARY resolution chain — the same path
  # a spawning session takes — rather than through the writer. Anything narrower
  # would verify that Google stored bytes, not that Zimmer can use them.
  #
  # @return [Array(Boolean, String)] [ok, one sentence of detail]
  def verify(expected:)
    want = expected.nil? ? nil : fingerprint_of(expected)

    VERIFY_ATTEMPTS.times do |attempt|
      @chain.invalidate(variable)
      got = fingerprint_of(read_value)
      return [ true, nil ] if got == want

      sleep(VERIFY_BACKOFF) unless attempt == VERIFY_ATTEMPTS - 1
    end

    if expected.nil?
      [ false, "#{variable} still resolves from #{provider_for&.label || 'somewhere'} after the delete." ]
    else
      [ false, "#{variable} did not read back from the store within " \
               "#{(VERIFY_ATTEMPTS * VERIFY_BACKOFF).round(1)}s. The usual cause is the missing IAM " \
               "binding that lets the parameter dereference its own secret — see " \
               "docs/operate/secrets-parameter-store." ]
    end
  rescue ParameterStore::AuthError, ParameterStore::StoreError => e
    [ false, "the store could not be read back: #{e.message}" ]
  end

  # The only place a value is read, and it is never returned to a caller — every
  # use of it goes through fingerprint_of.
  def read_value
    @chain.get(variable)
  rescue ParameterStore::AuthError, ParameterStore::StoreError
    nil
  end

  def fingerprint_of(value)
    return nil if value.nil? || value.to_s.empty?

    Digest::SHA256.hexdigest(value.to_s)[0, FINGERPRINT_LENGTH]
  end

  def provider_for
    @chain.provider_for(variable)
  rescue ParameterStore::AuthError, ParameterStore::StoreError
    nil
  end

  def parameter_store_provider
    @chain.providers.find { |provider| provider.is_a?(SecretProviders::ParameterStoreProvider) }
  end

  def write_capabilities
    @write_capabilities ||= ParameterStore::Capabilities.probe(@writer.client)
  end

  def store_name = SecretsLocation.parameter_store_name

  # Append one audit row. A failure to write the LOG must never turn a write
  # that landed into an exception the caller reports as a refusal — the store is
  # the source of truth here and the table is the convenience beside it.
  def record(action, ok:, detail:, fingerprint: nil)
    store = parameter_store_provider

    ManagedSecretWrite.create!(
      variable: variable,
      action: action,
      outcome: ok ? ManagedSecretWrite::SUCCEEDED : ManagedSecretWrite::FAILED,
      fingerprint: ok ? fingerprint : nil,
      project_id: store&.project_id,
      location: store&.location,
      detail: detail&.truncate(500)
    )
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn "[ManagedSecret] could not record the #{action} of #{variable}: #{e.class}"
  end

  # A refusal never reaches Google, so it is not recorded as an attempted write —
  # nothing was attempted.
  def refusal(action, capabilities)
    Result.new(ok: false, detail: write_reason(capabilities),
      message: "Zimmer cannot #{action == ManagedSecretWrite::DELETED ? 'delete' : 'write'} " \
               "#{variable} in #{store_name}.")
  end

  # One sentence naming exactly what stands between this deployment and a
  # working write. nil when nothing does.
  def write_reason(capabilities)
    return @writer.reason unless @writer.configured?
    return "the credential's permissions could not be confirmed: #{capabilities.reason}" unless capabilities.probed?

    missing = capabilities.missing_for_upsert
    return nil if missing.empty?

    "the #{@writer.dedicated_writer? ? 'writer' : 'resolver'} credential is missing " \
      "#{missing.join(', ')} on this project"
  end
end
