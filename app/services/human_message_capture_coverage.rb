# frozen_string_literal: true

# Whether Zimmer *could* have recorded a human message at all, for the input
# channels a hierarchy actually came in through.
#
# The human-message record answers "did a human ask for this?" as a lookup, and
# its most load-bearing reading is the empty one. But an empty record has two
# completely different causes and, until this class existed, one rendering:
#
#   * Zimmer looked and no named human spoke — an affirmative absence.
#   * Zimmer could not have seen the human even if they spoke, because the
#     channel they spoke on is not instrumented in this deployment.
#
# The second case is not hypothetical. `slack_user_ids` is deployment
# configuration and this repository is public, so the seeded roster ships with
# an EMPTY array and a deployment fills it in at /supervisor/users. Until it
# does, `User.for_slack_user_id` resolves nobody, `HumanMessageCapture` records
# nothing for every Slack message, and a Slack-originated hierarchy rendered
# exactly like one where nobody ever spoke (#658).
#
# What "instrumented" means here is a DEPLOYMENT-WIDE question, deliberately, and
# it is narrower than the per-message question capture asks. Capture asks "does
# THIS Slack user ID resolve to a row?"; this asks "could ANY Slack message have
# resolved to anybody?" — `User.admin` for the web UI, `User.with_slack_mapping`
# for Slack. That is answerable without the message, which is the whole point: the
# message Zimmer did not record is the one that cannot be consulted.
#
# The residual, stated plainly because the record's value is that it does not
# overclaim: a roster with SOME Slack IDs mapped and not others reports no gap,
# and an unmapped human speaking there still renders as an affirmative absence.
# Every `reason` string below says "no row maps ANY Slack user ID" rather than
# claiming the actor was checked. See docs/src/content/docs/limitations.md.
#
# == Why genesis, and why only some of the kinds
#
# `CHANNEL_BY_GENESIS` maps two of the channels in `HumanMessage::CHANNELS`
# to the genesis whose sessions arrive over them. `mcp_event` is the one kind
# answered per session instead — see "MCP events" below. The other genesis kinds
# split two ways. A GitHub issue or label, a schedule, a session-state or system event, an
# API spawn: no human actor at the boundary by construction, so an empty record
# there is the correct, intended answer rather than a gap. `unknown` is the
# exception and is a blind spot rather than a construction — it means the origin
# could not be established (chiefly rows predating the genesis column), so a
# Slack-origin session sitting on `unknown` reports no gap.
#
# Widening this to every kind would replace an affirmative absence with "cannot
# say" on nearly every hierarchy in the fleet, which destroys the signal the
# record exists to carry.
#
# `attested` has no genesis either: a signed approval lands in a session that
# already exists. The other two such channels, `assistant` and `live_mode`, have no genesis of their
# own. A session an OAuth client or Live Mode starts is `api` like any other
# parentless API spawn, and an `api` session's empty record stays an
# affirmative answer: a grant acting on its approver's behalf, or Live Mode
# answering an authenticated person, records what it sends, and a relay-only
# grant records nothing by design — the human chose that. Both channels still
# have their own arms below, so a gap is never reported for them by the generic fallback.
#
# == MCP events
#
# An `mcp_event` trigger relays whatever a catalog MCP server publishes: a Slack
# message, a mail, a CI run. Some of those a person wrote, and only a Slack message
# Zimmer read back from Slack can be attributed to them (McpEvents::HumanCapture).
# So there is no deployment-wide answer. The question is asked of each session, and
# the default is that the author was NOT established: an event-started session is a
# gap unless McpEvents::HumanCapture marked every event that started it as attributed.
# A session with genesis `mcp_event` and no event of its own inherited the genesis,
# and is answered by the ancestor that has one, or is itself a gap when this
# hierarchy shows none.
#
# The marker is session metadata, which an agent with the API can write. Forging it
# turns "could not be established" into "nobody spoke", which authorizes less; the
# records themselves stay unforgeable.
class HumanMessageCaptureCoverage
  # The gap channel for events from an MCP server. Not a HumanMessage channel: a
  # message captured off one is a `slack` record.
  MCP_EVENT = SessionGenesis::MCP_EVENT

  # Session genesis => the HumanMessage channel its input boundary writes.
  CHANNEL_BY_GENESIS = {
    SessionGenesis::WEB_UI => HumanMessage::WEB_UI,
    SessionGenesis::SLACK => HumanMessage::SLACK
  }.freeze

  # One channel this hierarchy came in through that capture cannot write for.
  #
  # `session_ids` is the evidence: the sessions in this hierarchy whose genesis
  # routes through the channel. Naming them is what turns "capture might be off"
  # into "these specific sessions arrived over a channel nothing could record".
  Gap = Data.define(:channel, :genesis, :session_ids, :reason, :remedy) do
    def session_count = session_ids.size

    def channel_label
      case channel
      when HumanMessage::WEB_UI then "the Zimmer web UI"
      when HumanMessage::SLACK then "Slack"
      when HumanMessage::ASSISTANT then "an assistant acting on a human's behalf"
      when HumanMessage::LIVE_MODE then "Live Mode"
      when HumanMessage::ATTESTED then "a signed approval from another Zimmer"
      when MCP_EVENT then "MCP events"
      else channel
      end
    end
  end

  class << self
    # True when capture could establish an author on this channel AT ALL — see the
    # deployment-wide caveat at the top of this file.
    #
    # A channel with no arm here is reported as a GAP, not as instrumented. That
    # is the safe direction on a surface whose entire value is that silence can be
    # trusted: a channel added to CHANNEL_BY_GENESIS without an arm should be
    # loudly unanswerable rather than quietly affirmative. `channels_are_covered`
    # in the test suite makes it unreachable anyway.
    def configured?(channel)
      case channel
      when HumanMessage::WEB_UI then User.admin.present?
      when HumanMessage::SLACK then User.with_slack_mapping.exists?
      when HumanMessage::ASSISTANT then assistant_grant_resolves?
      when HumanMessage::LIVE_MODE then User.admin.present? || assistant_grant_resolves?
      when HumanMessage::ATTESTED then MergeAttestations::Trust.current.any?
      else false
      end
    end

    def reason(channel)
      case channel
      when HumanMessage::WEB_UI
        "The configured admin key (#{User::ADMIN_ENV_KEY}, currently `#{User.admin_key}`) names no row in this " \
        "deployment's roster, so nothing typed into the web UI resolves to a human and none of it was recorded."
      when HumanMessage::SLACK
        "No row in this deployment's roster maps any Slack user ID, so every Slack message resolved to nobody and " \
        "recorded nothing — whoever sent it."
      when HumanMessage::ASSISTANT
        "No live OAuth connection both acts on its approver's behalf and was approved by an email in this " \
        "deployment's roster, so nothing an assistant relayed was recorded as a human's."
      when HumanMessage::LIVE_MODE
        "Neither the configured admin key (#{User::ADMIN_ENV_KEY}) nor the approver of any OAuth connection acting " \
        "on its approver's behalf names a row in this deployment's roster, so nothing said in Live Mode was recorded."
      when HumanMessage::ATTESTED
        "This deployment trusts no other Zimmer's signing key (#{MergeAttestations::TRUSTED_ISSUERS_ENV} is unset), " \
        "so no approval signed elsewhere was accepted or recorded."
      when MCP_EVENT
        "An event from an MCP server reached this hierarchy and Zimmer did not establish who wrote what it carried. " \
        "Zimmer never takes an author from an event's payload. It records one only for a Slack message from a server " \
        "named in #{McpEvents::SlackMessage::SERVERS_ENV}, once Slack itself has answered that a person on the " \
        "roster wrote it. Mail, WhatsApp and every other event are never attributed."
      else
        "Zimmer has no configuration check for this channel, so it cannot say whether a message on it would have " \
        "been recorded."
      end
    end

    def remedy(channel)
      case channel
      when HumanMessage::WEB_UI
        "Add a row with that key at /supervisor/users, or point #{User::ADMIN_ENV_KEY} at a key that exists."
      when HumanMessage::SLACK
        "Fill in the human's Slack user ID at /supervisor/users. It is a row edit, not a deploy."
      when HumanMessage::ASSISTANT
        "Let the connection act on your behalf on Settings → API keys, and make sure its approver's email is " \
        "on their row at /supervisor/users."
      when HumanMessage::LIVE_MODE
        "Add the admin's row at /supervisor/users, or sign the iOS app in again allowing it to act as you."
      when HumanMessage::ATTESTED
        "Pin the issuing Zimmer's public key in #{MergeAttestations::TRUSTED_ISSUERS_ENV} (see Merge approvals " \
        "across deployments in the docs)."
      when MCP_EVENT
        "Nothing can attribute an event after the fact. For Slack events to come, name the server in " \
        "#{McpEvents::SlackMessage::SERVERS_ENV} and fill in the human's Slack user ID at /supervisor/users."
      else
        "Give this channel a check in HumanMessageCaptureCoverage.configured?."
      end
    end
  end

  # Whether any live grant holding OauthServer::ACT_AS_HUMAN_SCOPE was approved
  # by an email the roster knows — the deployment-wide question for `assistant`.
  def self.assistant_grant_resolves?
    OauthServer::Grant.active.select(&:acts_as_human?).any? { |grant| User.for_email(grant.user_email).present? }
  end

  attr_reader :hierarchy

  def initialize(hierarchy)
    @hierarchy = hierarchy
  end

  # Every input channel this hierarchy used that capture cannot write for,
  # ordered by channel so two renderings of the same record agree.
  def gaps
    @gaps ||= begin
      uncaptured = sessions_by_channel.reject { |channel, _ids| self.class.configured?(channel) }
      uncaptured[MCP_EVENT] = unattributed_event_session_ids
      uncaptured.reject { |_channel, ids| ids.empty? }.sort.map { |channel, ids| gap(channel, ids) }
    end
  end

  def any? = gaps.any?

  private

  def gap(channel, session_ids)
    Gap.new(
      channel: channel,
      genesis: CHANNEL_BY_GENESIS.key(channel) || channel,
      session_ids: session_ids,
      reason: self.class.reason(channel),
      remedy: self.class.remedy(channel)
    )
  end

  # The hierarchy's sessions an MCP event reached whose author Zimmer did not
  # establish. See "MCP events" above.
  def unattributed_event_session_ids
    captures = event_captures
    nodes = hierarchy.nodes.index_by(&:id)

    nodes.values.filter_map do |node|
      unattributed = if captures.key?(node.id)
        captures[node.id] != McpEvents::HumanCapture::COMPLETE
      else
        node.genesis == SessionGenesis::MCP_EVENT && !descends_from_an_event?(node, nodes, captures)
      end
      node.id if unattributed
    end.sort
  end

  # Session id => McpEvents::HumanCapture's marker, or nil when it carries none, for
  # the sessions an MCP event started or reached. Read from the rows because a
  # hierarchy node carries no metadata.
  def event_captures
    Session.where(id: hierarchy.nodes.map(&:id))
      .where("metadata ?| array[:keys]", keys: [ "mcp_event_server", McpEvents::HumanCapture::METADATA_KEY ])
      .pluck(:id, Arel.sql("metadata->>'#{McpEvents::HumanCapture::METADATA_KEY}'"))
      .to_h
  end

  def descends_from_an_event?(node, nodes, captures)
    seen = Set.new
    while (node = nodes[node.parent_id]) && seen.add?(node.id)
      return true if captures.key?(node.id)
    end
    false
  end

  # Channel => the hierarchy's session ids that arrive over it. A node with no
  # genesis, or one whose genesis has no human boundary, contributes nothing.
  def sessions_by_channel
    hierarchy.nodes.each_with_object({}) do |node, by_channel|
      channel = CHANNEL_BY_GENESIS[node.genesis]
      next if channel.nil?

      (by_channel[channel] ||= []) << node.id
    end.sort.to_h
  end
end
