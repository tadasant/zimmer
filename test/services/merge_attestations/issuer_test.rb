# frozen_string_literal: true

require "test_helper"

# Minting is LiveConversations::AuthorizeMerge's confirm step and nothing else.
class MergeAttestations::IssuerTest < ActiveSupport::TestCase
  PR = "https://github.com/example-org/example-repo/pull/42"

  setup { setup_merge_attestation_env }
  teardown { teardown_merge_attestation_env }

  # The line this whole feature stands on: no MCP tool, controller or job can
  # sign. A new caller of the issuer or the signing key has to be added here
  # on purpose, in a diff a reviewer reads. Remote reads the public key id
  # only, to ask the receiver whether that key is pinned.
  test "only authorize_merge mints, and only the issuer and the JWKS touch the signing key" do
    app = Rails.root.join("app")
    callers = ->(pattern) { Dir[app.join("**/*.rb")].select { |f| File.read(f).match?(pattern) }.map { |f| f.delete_prefix("#{app}/") }.sort }

    assert_equal %w[services/live_conversations/authorize_merge.rb], callers.call(/Issuer\.mint!/)
    assert_equal %w[controllers/merge_attestation_keys_controller.rb services/live_conversations/authorize_merge.rb
                    services/merge_attestations/issuer.rb services/merge_attestations/remote.rb
                    services/merge_attestations/signing_key.rb],
                 callers.call(/SigningKey\b/)
  end

  test "it signs only for a recorded live_mode yes on the driving session" do
    session = Session.create!(agent_runtime: "claude_code", prompt: "initial", git_root: "https://github.com/test/repo.git",
                              branch: "main", status: :needs_input)
    other = Session.create!(agent_runtime: "claude_code", prompt: "initial", git_root: "https://github.com/test/repo.git",
                            branch: "main", status: :needs_input)
    target = MergeAttestations::Remote::Target.new(pr_url: PR, repo: "example-org/example-repo", pr_number: 42, head_sha: HEAD,
                                                   session_url: nil, title: nil, blocked_reason: nil, gate_hold_reason: nil,
                                                   audience: AUDIENCE, trusts_issuer: true, merge_authorized_at: nil)
    remote = MergeAttestations::Remote.new("remote-zimmer", audience: AUDIENCE, catalog_server: Object.new)
    typed = session.human_messages.create!(author: "tadasant", channel: HumanMessage::WEB_UI, content: "merge it", occurred_at: Time.current)
    spoken = session.human_messages.create!(author: "tadasant", channel: HumanMessage::LIVE_MODE, content: "Yes.",
                                            occurred_at: Time.current, provenance: { "surface" => "carplay", "heard" => "spoken" })

    assert_raises(ArgumentError) { MergeAttestations::Issuer.mint!(session: session, human_message: typed, target: target, remote: remote, read_back: "q") }
    assert_raises(ArgumentError) { MergeAttestations::Issuer.mint!(session: other, human_message: spoken, target: target, remote: remote, read_back: "q") }

    token, row = MergeAttestations::Issuer.mint!(session: session, human_message: spoken, target: target, remote: remote, read_back: "Merge it?")
    claims = MergeAttestations::Verifier.new.verify!(token)
    assert_equal PR, claims.pr_url
    assert_equal "carplay", claims.surface
    assert_equal "Merge it?", claims.read_back
    assert_equal row.jti, claims.jti
    assert_equal MergeAttestations::LIFETIME.to_i, claims.expires_at.to_i - claims.issued_at.to_i
    assert_equal AUDIENCE, claims.aud, "addressed to the audience pinned for the remote"
  end

  test "remote servers are name=audience pairs, and an entry without an audience is ignored" do
    ENV[MergeAttestations::REMOTE_SERVERS_ENV] = "remote-zimmer=https://remote.test, bare-name ,other=https://o.test"
    assert_equal({ "remote-zimmer" => "https://remote.test", "other" => "https://o.test" }, MergeAttestations.remote_servers)
  end
end
