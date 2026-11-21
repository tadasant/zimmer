# frozen_string_literal: true

# Keys, env and tokens for MergeAttestations tests. One test process plays
# both deployments: ISSUER signs, AUDIENCE receives, and the trust config pins
# the issuer's own public key, so a token goes through the real JWS code end
# to end.
module MergeAttestationHelpers
  ISSUER = "https://zimmer.test"
  AUDIENCE = "https://remote.test"
  HEAD = "a" * 40
  ENV_KEYS = [ MergeAttestations::SIGNING_KEY_ENV, MergeAttestations::ISSUER_ENV, MergeAttestations::REMOTE_SERVERS_ENV,
               MergeAttestations::AUDIENCE_ENV, MergeAttestations::TRUSTED_ISSUERS_ENV ].freeze

  def setup_merge_attestation_env(remote_servers: "remote-zimmer=#{AUDIENCE}", approvers: { "tadasant" => "tadasant" }, repos: nil)
    @saved_attestation_env = ENV_KEYS.index_with { |k| ENV[k] }
    @attestation_key = OpenSSL::PKey.generate_key("ED25519")
    ENV[MergeAttestations::SIGNING_KEY_ENV] = @attestation_key.private_to_pem
    ENV[MergeAttestations::ISSUER_ENV] = ISSUER
    ENV[MergeAttestations::AUDIENCE_ENV] = AUDIENCE
    ENV[MergeAttestations::REMOTE_SERVERS_ENV] = remote_servers
    trust_issuer(approvers: approvers, repos: repos)
  end

  def trust_issuer(approvers: { "tadasant" => "tadasant" }, repos: nil, keys: [ signing_key.public_jwk ])
    entry = { "keys" => keys, "approvers" => approvers }
    entry["repos"] = repos if repos
    ENV[MergeAttestations::TRUSTED_ISSUERS_ENV] = { ISSUER => entry }.to_json
  end

  def teardown_merge_attestation_env
    @saved_attestation_env&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def signing_key = MergeAttestations::SigningKey.current

  def attestation_claims(pr_url, now: Time.current, **overrides)
    repo, number = MergeAttestations.parse_pr_url(pr_url)
    {
      "iss" => ISSUER, "aud" => AUDIENCE, "sub" => pr_url, "jti" => SecureRandom.uuid,
      "iat" => now.to_i, "exp" => now.to_i + 300, "ver" => 1, "repo" => repo, "pr_number" => number,
      "head_sha" => HEAD, "approver" => "tadasant", "approver_name" => "Tadas", "channel" => "live_mode",
      "surface" => "carplay", "heard" => "spoken", "read_back" => "Merge #{repo.split('/').last} pull request #{number}?",
      "answer" => "Yes.", "approved_at" => now.utc.iso8601
    }.merge(overrides.transform_keys(&:to_s))
  end

  def sign_attestation(claims, header: nil, key: @attestation_key)
    return signing_key.sign(claims) unless header

    b64 = ->(v) { Base64.urlsafe_encode64(v, padding: false) }
    input = "#{b64.call(header.to_json)}.#{b64.call(claims.to_json)}"
    "#{input}.#{b64.call(key.sign(nil, input))}"
  end

  # A Github::PrSnapshot stand-in: what GitHub says about the PR right now.
  def github_reading(state: "OPEN", head_sha: HEAD)
    ->(_ref) { Struct.new(:state, :head_sha).new(state, head_sha) }
  end

  def green_pr_metadata(url)
    { "github_pull_request_urls" => [ url ], "github_pull_request_statuses" => { url => "open" },
      "github_pull_request_ci_statuses" => { url => "pass" } }
  end

  # The other Zimmer, in process: answers the two receiving tools exactly as
  # its MCP surface would, through the real tool classes. With a `prefix`, it
  # behaves like a gateway that namespaces every tool as `<prefix>__<tool>`
  # and refuses the bare name, as strad does.
  class LoopbackRemote
    TOOLS = { MergeAttestations::TARGET_TOOL => Mcp::Tools::GetMergeAttestationTarget,
              MergeAttestations::SUBMIT_TOOL => Mcp::Tools::SubmitMergeAttestation }.freeze

    attr_reader :calls

    def initialize(prefix: nil, extra_tools: [])
      @calls = []
      @prefix = prefix
      @extra_tools = extra_tools
    end

    def list_tools
      names = TOOLS.keys.map { |tool| @prefix ? "#{@prefix}__#{tool}" : tool } + @extra_tools
      names.map { |name| LiveConversations::CatalogServer::Tool.new(name, "", {}) }
    end

    def call_tool(name, arguments)
      @calls << [ name, arguments ]
      tool = @prefix ? name.delete_prefix("#{@prefix}__") : name
      raise LiveConversations::CatalogServer::Unavailable, "#{name} is not namespaced as <server>__<tool>" if @prefix && tool == name

      [ TOOLS.fetch(tool).new(context: Mcp::Context.new).call(arguments), false ]
    end
  end
end

ActiveSupport::TestCase.include(MergeAttestationHelpers)
