# frozen_string_literal: true

# RuntimeMcpCredentialWriter — the contract every agent-runtime MCP credential
# writer implements.
#
# Zimmer resolves a session's active MCP OAuth tokens in a runtime-agnostic way: the
# OAuth discovery / DCR / refresh machinery and McpOauthCredentialInjector
# produce ResolvedMcpCredential value objects. The *sink* — where those tokens
# are written so the spawned CLI can read them — is the one runtime-specific
# piece. Claude Code reads ~/.claude/.credentials.json (and, on macOS, the
# Keychain); OpenAI Codex reads ~/.codex/.credentials.json with a different
# schema (see #3782). This module is the single seam the injector writes
# through, so adding a runtime means implementing this contract rather than
# branching the injector.
#
# == Required methods (must be implemented by including classes) ==
#
# write!(working_directory:, credentials:) -> String, nil
#   Persist the resolved credentials to the runtime's on-disk credential store.
#   `credentials` is an Array<ResolvedMcpCredential>. `working_directory` is the
#   session clone (Claude writes to ~/.<runtime>; other runtimes may write into
#   the clone). Returns the primary path written (for logging), or nil if nothing
#   was written.
#
# credential_key_for(server_name, server_config) -> String
#   The key under which a server's token is stored in the runtime's credential
#   file. `server_config` is a Hash with :type, :url, :headers. Runtimes that key
#   by a hashed config (Claude) compute it here; others may return a plain name.
#   The injector calls this when building each ResolvedMcpCredential so the key
#   shape stays owned by the runtime, while the protocol-level DB identity
#   (McpOauthCredential.compute_credential_key) stays runtime-agnostic.
#
# read_runtime_credentials -> Hash{String => RuntimeMcpTokenSnapshot}
#   The read-side mirror of #write!: parse the runtime's on-disk credential store
#   and return whatever token pairs it currently holds, keyed by the same
#   credential key #write! stored them under. This is how Zimmer captures a token
#   the runtime refreshed and rotated mid-session back into its DB
#   (McpOauthRuntimeReconciler). Returns {} when the store is absent or
#   unreadable — a missing store means "nothing to adopt", never an error.
#
# clear_needs_auth_cache(server_names) -> Array<String>
#   Drop any runtime-side "this server needs auth" memo for the named servers, so
#   the CLI actually retries them with the token #write! just stored. Claude Code
#   keeps such a memo in a host-global file and skips the connection entirely
#   while an entry is present, which makes a freshly-injected credential
#   invisible; runtimes without that behavior implement this as a no-op returning
#   []. Best-effort — a missing store means "nothing suppressing it", never an
#   error. Returns the names actually cleared.
#
# The shared contract is exercised by
# test/contracts/runtime_mcp_credential_writer_contract_test.rb against every
# writer.
module RuntimeMcpCredentialWriter
end
