# frozen_string_literal: true

# Zimmer as an OAuth 2.1 authorization server for its own `POST /mcp`.
#
# A remote MCP client — Claude.ai's custom connectors, the MCP Inspector — finds
# this server through `/.well-known/oauth-protected-resource/mcp`, registers itself
# (Dynamic Client Registration, or a Client ID Metadata Document), sends the human
# through `/oauth/authorize`, and calls `/mcp` with the access token it gets back.
# The static API key keeps working beside it.
#
# Not to be confused with McpOauthService and McpOauthCredential, which are the
# other direction: Zimmer as an OAuth *client* of somebody else's MCP server.
#
# docs/src/content/docs/auth/mcp-authorization-server.md is the prose.
module OauthServer
  def self.table_name_prefix
    "oauth_server_"
  end

  # The scope every grant carries. A token opens `/mcp` — what an `api` key opens
  # there — and nothing else.
  SCOPE = "mcp"

  # The second scope, and the only one that changes what a grant MEANS rather
  # than what it reaches: a grant holding it "acts on behalf of" the human who
  # approved it, so a message its client delivers into a session is recorded as
  # that human's (HumanMessageCapture.record_assistant_message). It opens no tool
  # an `mcp` grant does not.
  #
  # The human chooses it on the consent screen, not the client: RFC 6749 §3.3
  # lets the server issue a scope other than the one requested, so a client that
  # asks only for `mcp` — Claude.ai does — still gets this one if the human
  # picks it, and a client that asks for it gets nothing unless they do.
  ACT_AS_HUMAN_SCOPE = "zimmer:act-as-human"

  SCOPES_SUPPORTED = [ SCOPE, ACT_AS_HUMAN_SCOPE ].freeze

  # The two privilege levels the consent screen and the connections page offer,
  # by the scope string a grant carries for each.
  ACT_AS_HUMAN = "act_as_human"
  RELAY_ONLY = "relay_only"
  PRIVILEGES = [ ACT_AS_HUMAN, RELAY_ONLY ].freeze

  def self.scope_for(privilege)
    case privilege.to_s
    when ACT_AS_HUMAN then "#{SCOPE} #{ACT_AS_HUMAN_SCOPE}"
    when RELAY_ONLY then SCOPE
    else raise ArgumentError, "unknown privilege #{privilege.inspect}"
    end
  end

  def self.scope_tokens(scope)
    scope.to_s.split
  end

  ACCESS_TOKEN_PREFIX = "zmr_oat_"
  REFRESH_TOKEN_PREFIX = "zmr_ort_"

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
