# frozen_string_literal: true

# Where Zimmer keeps copies of old transcripts: a private Google Cloud Storage bucket.
#
# Configured by two values, both resolved through SecretProviders.chain so the credential
# lives in the Parameter Store and never in a deploy file:
#
#   TRANSCRIPT_STORAGE_BUCKET                     the bucket's name (not a secret)
#   TRANSCRIPT_STORAGE_SERVICE_ACCOUNT_KEY_JSON   a service account that may create and
#                                                 read objects, and neither overwrite nor
#                                                 delete them
#
# ABSENCE IS A NORMAL STATE: with neither set nothing is copied and nothing warns. One
# without the other, or a key that does not parse, is a misconfiguration and says so.
module TranscriptStorage
  class Error < StandardError; end
  # The store could not be reached, refused, or answered something unusable: it is the
  # store's trouble, not one session's. Never carries a response body.
  class RequestFailed < Error; end
  # What the store holds under one name is not what was sent, or it would not take it:
  # that session's trouble.
  class VerificationFailed < Error; end

  BUCKET = "TRANSCRIPT_STORAGE_BUCKET"
  KEY_JSON = "TRANSCRIPT_STORAGE_SERVICE_ACCOUNT_KEY_JSON"
  # Test seams, so a test can point the production client at a local fake.
  API_BASE = "TRANSCRIPT_STORAGE_API_BASE"
  TOKEN_URL = "TRANSCRIPT_STORAGE_TOKEN_URL"

  # GCS bucket names; also what makes the value safe to put in a URL.
  BUCKET_PATTERN = /\A[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]\z/

  # `problem` is a sentence for a human and never contains a value of the key.
  # `unread` is that the secret store could not be asked, so nothing is known.
  Configuration = Struct.new(:bucket, :client, :problem, :unread, keyword_init: true) do
    include RedactedInspect

    def redacted_inspect_fields = { bucket: bucket, problem: problem }
    def configured? = client.present?
    def off? = client.nil? && problem.nil?
  end

  # What the health report needs to know of a Configuration: no client, no key.
  Recorded = Data.define(:configured, :bucket, :problem) do
    def configured? = configured
    def off? = !configured && problem.nil?
  end

  RECORDED_KEY = "transcript_storage:recorded_configuration"
  # Outlives a stopped job by enough that the health report's stalled-backlog warning,
  # which needs the bucket, still fires.
  RECORDED_TTL = 1.day

  module_function

  # The configuration as TranscriptCopyJob last resolved it, or nil when it has not lately.
  #
  # For a reader that must not resolve it. These two names are unset by design on most
  # deployments, and SecretProviders answers a name it does not hold by reading the whole
  # store again over the network, which takes seconds. The health report is polled.
  def recorded_configuration
    values = Rails.cache.read(RECORDED_KEY)
    values && Recorded.new(**Recorded.members.index_with(nil), **values.slice(*Recorded.members))
  end

  # Resolves the configuration and leaves it where #recorded_configuration reads it.
  def record_configuration
    configuration.tap do |current|
      # A store that could not be asked says nothing about what is configured.
      next if current.unread && recorded_configuration

      Rails.cache.write(RECORDED_KEY,
        { configured: current.configured?, bucket: current.bucket, problem: current.problem }, expires_in: RECORDED_TTL)
    rescue StandardError => e
      Rails.logger.warn("[TranscriptStorage] could not record the configuration: #{e.class}")
    end
  end

  def configuration(chain: SecretProviders.chain, env: ENV)
    bucket = chain.get(BUCKET).to_s.strip.presence
    key = chain.get(KEY_JSON).presence
    return Configuration.new if bucket.nil? && key.nil?
    return Configuration.new(problem: "#{KEY_JSON} is set but #{BUCKET} is not") if bucket.nil?
    # Ahead of anything that repeats the value: a key pasted into the wrong variable is not one.
    return Configuration.new(problem: "#{BUCKET} is not a bucket name") unless bucket.match?(BUCKET_PATTERN)
    return Configuration.new(bucket: bucket, problem: "#{BUCKET} is set but #{KEY_JSON} is not") if key.nil?

    account, reason = ParameterStore::ServiceAccount.parse(key, token_url: env[TOKEN_URL])
    return Configuration.new(bucket: bucket, problem: "#{KEY_JSON} #{reason}") if account.nil?
    return Configuration.new(bucket: bucket, problem: "#{KEY_JSON} holds a private key that cannot be read") unless account.usable_key?

    client = GcsClient.new(bucket: bucket, account: account, api_base: env[API_BASE].presence || GcsClient::API_BASE)
    Configuration.new(bucket: bucket, client: client)
  rescue StandardError => e
    # A provider that cannot be reached raises. That is not "off".
    Configuration.new(problem: "the secret store could not be read (#{e.class})", unread: true)
  end
end
