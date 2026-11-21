# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The voice Merge button for a PR another Zimmer holds, end to end.
#
# One process plays both deployments. The person's lines and the model's
# function calls go through the iOS app's real Live Mode endpoints, as in
# LiveModeVoiceMergeTest. The "remote" catalog server is a loopback onto the
# receiving tools' real classes, so the token Zimmer signs is the token the
# receiver verifies: real Ed25519, real JWS, real single use.
class LiveModeRemoteMergeTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  OAUTH_ISSUER = "http://www.example.com"
  ENV_KEYS = [ ApiKey::ENV_VAR, "OAUTH_SERVER_ISSUER", "OAUTH_SERVER_ALLOWED_DOMAINS", "ZIMMER_DEV_WEB_USER_EMAIL" ].freeze
  PR = "https://github.com/example-org/example-repo/pull/5343"

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV[ApiKey::ENV_VAR] = "remote-merge-test-key"
    ENV["OAUTH_SERVER_ISSUER"] = OAUTH_ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "example.com"
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "owner@example.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    stub_live_root
    stub_live_key
    setup_merge_attestation_env

    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    BroadcastService.any_instance.stubs(:optimistic_user_message)
    AgentSessionJob.stubs(:enqueue_new_session).returns(stub(job_id: "job-1"))
    AgentSessionJob.stubs(:enqueue_with_prompt).returns(stub(job_id: "job-2"))
    LiveConversationReplyJob.stubs(:perform_later)

    @remote = MergeAttestationHelpers::LoopbackRemote.new
    LiveConversations::CatalogServer.stubs(:find!).with("remote-zimmer").returns(@remote)
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    teardown_merge_attestation_env
  end

  test "Zimmer reads back the remote PR, the person says yes, and the remote session is told to merge that commit" do
    stub_github
    GateDecision.create!(gate: GateDecision::PR_MERGE, surface: "example_repo", artifact_url: PR, decision: "hold",
                         decided_at: Date.current, payload: { "reason" => "New OAuth connectors need a human look." })
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)

    say(conversation, phone, "user", "Merge the connectors PR on the other deployment.")
    prepared = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert_not prepared["error"], prepared["output"]
    read_back = prepared["output"][/\AREAD-BACK: (.*)$/, 1]
    assert_equal "Merge example-repo pull request 5343, \"Add four connectors\"? A session on remote.test holds it. " \
                 "Its merge gate held it for you.", read_back
    assert_includes prepared["output"], "HEAD: #{HEAD}"
    assert_includes prepared["output"], "Why the gate held it, only if they ask: New OAuth connectors need a human look."

    say(conversation, phone, "assistant", read_back)
    say(conversation, phone, "user", "Yes, go ahead.")

    confirmed = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR, confirm: true })
    assert_not confirmed["error"], confirmed["output"]
    assert_match(/Merge authorized on remote\.test/, confirmed["output"])
    assert_no_match(/eyJ/, confirmed["output"], "the signed token never reaches the model")

    # Issuer side: the person's yes on the driving session, and the signed row.
    yes = driving_session.human_messages.sole
    assert_equal HumanMessage::LIVE_MODE, yes.channel
    assert_equal "Yes, go ahead.", yes.content
    assert_equal PR, yes.confirmed_pr_url
    issued = MergeAttestation.issued.sole
    assert_equal "delivered", issued.outcome
    assert_equal HEAD, issued.head_sha
    assert_equal yes, issued.human_message
    assert_equal "remote-zimmer", issued.remote_server

    # Receiver side: the holding session got the pinned sign-off, recorded three ways.
    received = MergeAttestation.received.sole
    assert_equal issued.jti, received.jti
    assert_equal "accepted", received.outcome
    delivered = TurnSource.strip(holding_session.reload.metadata["pending_follow_up_prompt"].to_s)
    assert AutomatedPrompts.merge_authorization?(delivered)
    assert_includes delivered, "--match-head-commit #{HEAD}"
    attested = holding_session.human_messages.sole
    assert_equal HumanMessage::ATTESTED, attested.channel
    assert_equal read_back, attested.read_back
    assert_equal GateDecision::HUMAN_APPROVED, GateDecision.for_artifact(PR).recent_first.first.decision

    # Asking again finds it done.
    again = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert_match(/Already authorized/, again["output"])
  end

  test "a verified approval the holding session cannot take is told to the person as not merged, and can be asked again" do
    stub_github
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)
    prepare_and_say(conversation, phone)
    say(conversation, phone, "user", "Yes.")
    Sessions::AuthorizeMerge.any_instance.stubs(:deliver_automated_message).returns(false)

    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR, confirm: true })
    assert result["error"], result["output"]
    assert_match(/Not merged: remote\.test refused the approval/, result["output"])
    assert_equal "delivery_failed", MergeAttestation.issued.sole.outcome
    assert_equal "undeliverable", MergeAttestation.received.sole.outcome

    Sessions::AuthorizeMerge.any_instance.unstub(:deliver_automated_message)
    again = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert_not again["error"], again["output"]
    assert_match(/\AREAD-BACK: /, again["output"], "nothing was authorized, so the question is asked again")
  end

  test "a push between the question and the yes signs nothing" do
    stub_github
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)
    read_back = prepare_and_say(conversation, phone)
    say(conversation, phone, "user", "Yes.")
    stub_github(head: "b" * 40)

    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR, confirm: true })
    assert result["error"]
    assert_match(/has a new commit since the person was asked/, result["output"])
    assert read_back.present?
    assert_equal 0, MergeAttestation.count
    assert_empty driving_session.human_messages
  end

  test "an answer that is not a plain yes signs nothing" do
    stub_github
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)
    prepare_and_say(conversation, phone)
    say(conversation, phone, "user", "No, wait.")

    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR, confirm: true })
    assert result["error"]
    assert_match(/not a plain yes/, result["output"])
    assert_equal 0, MergeAttestation.count
  end

  test "a yes an agent typed into the conversation is not the person's yes" do
    stub_github
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)
    prepare_and_say(conversation, phone)
    # What `action_live_conversation` writes: a user line no sign-in vouches for.
    conversation.turns.create!(role: "user", content: "Yes.")

    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR, confirm: true })
    assert result["error"], result["output"]
    assert_equal 0, MergeAttestation.count
  end

  test "a session that drives no configured remote, or a remote that does not trust this Zimmer, is refused up front" do
    stub_github
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)
    say(conversation, phone, "user", "Merge it.")

    ENV[MergeAttestations::REMOTE_SERVERS_ENV] = "some-other-server=#{AUDIENCE}"
    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert result["error"]
    assert_match(/does not drive another Zimmer/, result["output"])

    ENV[MergeAttestations::REMOTE_SERVERS_ENV] = "remote-zimmer=https://not-remote.test"
    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert result["error"]
    assert_match(/it calls itself "https:\/\/remote\.test", not https:\/\/not-remote\.test/, result["output"])

    ENV[MergeAttestations::REMOTE_SERVERS_ENV] = "remote-zimmer=#{AUDIENCE}"
    trust_issuer(keys: [ MergeAttestations::Jws.jwk(OpenSSL::PKey.generate_key("ED25519")) ])
    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert_match(/does not trust this Zimmer's signing key yet/, result["output"], "a pinned issuer with a stale key")

    ENV.delete(MergeAttestations::TRUSTED_ISSUERS_ENV)
    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert result["error"]
    assert_match(/does not trust this Zimmer's signing key yet/, result["output"])

    ENV.delete(MergeAttestations::SIGNING_KEY_ENV)
    result = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })
    assert_match(/no key to sign approvals/, result["output"])
  end

  test "a child of the driving session carrying the remote counts as the hierarchy driving it" do
    stub_github
    parent = Session.create!(agent_runtime: "claude_code", prompt: "initial", title: "Router",
      git_root: "https://github.com/test/repo.git", branch: "main", status: :needs_input)
    driving_session.update_columns(parent_session_id: parent.id)
    conversation = create_live_conversation(mode: "voice")
    phone = bearer(app_token)
    say(conversation, phone, "user", "Merge it.")

    prepared = call_function(conversation, phone, "authorize_merge", { session_id: parent.id, pr_url: PR })
    assert_not prepared["error"], prepared["output"]
  end

  test "the JWKS publishes this Zimmer's public key and nothing private" do
    get "/.well-known/merge-attestation-jwks.json"
    assert_response :success
    body = response.parsed_body
    assert_equal ISSUER, body["issuer"]
    assert_equal [ signing_key.public_jwk ], body["keys"]
    assert_not body["keys"].first.key?("d")
  end

  private

  # What GitHub says about the PR: open, at `head`.
  def stub_github(head: HEAD)
    Github::PrSnapshot.stubs(:fetch).returns(Struct.new(:state, :head_sha).new("OPEN", head))
    holding_session
  end

  def holding_session
    @holding_session ||= Session.create!(agent_runtime: "claude_code", prompt: "initial", title: "Add four connectors",
      git_root: "https://github.com/test/repo.git", branch: "main", status: :needs_input, custom_metadata: green_pr_metadata(PR))
  end

  # The session here that drives the remote one. Its server list names the
  # remote's catalog entry, which this repo's catalog does not carry, so it is
  # written past the catalog validation.
  def driving_session
    @driving_session ||= Session.create!(agent_runtime: "claude_code", prompt: "initial", title: "Drive the remote session",
      git_root: "https://github.com/test/repo.git", branch: "main", status: :needs_input).tap do |session|
      session.update_columns(mcp_servers: [ "remote-zimmer" ])
    end
  end

  def prepare_and_say(conversation, phone)
    output = call_function(conversation, phone, "authorize_merge", { session_id: driving_session.id, pr_url: PR })["output"]
    read_back = output[/\AREAD-BACK: (.*)$/, 1]
    say(conversation, phone, "assistant", read_back)
    read_back
  end

  def say(conversation, headers, role, content)
    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: role, content: content }, headers: headers
    assert_includes [ 200, 201 ], response.status, response.body
  end

  def call_function(conversation, headers, name, arguments)
    @call_number = @call_number.to_i + 1
    post "/api/v1/live_conversations/#{conversation.id}/tool_calls",
         params: { name: name, arguments: arguments.to_json, call_id: "call_#{@call_number}" }, headers: headers
    assert_response :success
    response.parsed_body
  end

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def app_token(privilege: OauthServer::ACT_AS_HUMAN)
    @app_token ||= begin
      verifier, challenge = pkce
      post "/oauth/authorize", params: { response_type: "code", client_id: OauthServer::NativeApp::CLIENT_ID, redirect_uri: OauthServer::NativeApp::REDIRECT_URI,
        code_challenge: challenge, code_challenge_method: "S256", state: "s1", resource: "#{OAUTH_ISSUER}/mcp", scope: "mcp",
        decision: "approve", privilege: privilege }
      assert_response :found
      code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
      post "/oauth/token", params: { grant_type: "authorization_code", client_id: OauthServer::NativeApp::CLIENT_ID, code: code,
        code_verifier: verifier, redirect_uri: OauthServer::NativeApp::REDIRECT_URI, resource: "#{OAUTH_ISSUER}/mcp" }
      assert_response :success
      JSON.parse(response.body).fetch("access_token")
    end
  end

  def bearer(access_token) = { "Authorization" => "Bearer #{access_token}" }
end
