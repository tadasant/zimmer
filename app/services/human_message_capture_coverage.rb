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
# Which channels count as "instrumented" is not a judgement — it is the same
# lookup capture itself performs, run ahead of time. Web-UI capture attributes to
# `User.admin`; Slack capture attributes through `User.for_slack_user_id`. When
# the roster cannot answer, capture writes nothing, and this class says so.
#
# == Why genesis, and why only two of the kinds
#
# `HumanMessage::CHANNELS` names the two boundaries Zimmer establishes a human
# actor at, and `CHANNEL_BY_GENESIS` maps each to the genesis whose sessions
# arrive through it. Every other genesis — a GitHub issue or label, a schedule, a
# session-state or system event, an API spawn — has NO human actor at its
# boundary by construction, and an empty record there is the correct, intended
# answer rather than a gap. Widening this to those kinds would replace an
# affirmative absence with "cannot say" on nearly every hierarchy in the fleet,
# which destroys the signal the record exists to carry.
class HumanMessageCaptureCoverage
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
      else channel
      end
    end
  end

  class << self
    # True when capture can establish an author on this channel at all. Exactly
    # the lookup HumanMessageCapture performs, so the two cannot disagree about
    # what "configured" means.
    def configured?(channel)
      case channel
      when HumanMessage::WEB_UI then User.admin.present?
      when HumanMessage::SLACK then User.with_slack_mapping.exists?
      else true
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
      else
        "Capture is not configured for this channel."
      end
    end

    def remedy(channel)
      case channel
      when HumanMessage::WEB_UI
        "Add a row with that key at /supervisor/users, or point #{User::ADMIN_ENV_KEY} at a key that exists."
      when HumanMessage::SLACK
        "Fill in the human's Slack user ID at /supervisor/users. It is a row edit, not a deploy."
      else
        "Configure capture for this channel."
      end
    end
  end

  attr_reader :hierarchy

  def initialize(hierarchy)
    @hierarchy = hierarchy
  end

  # Every input channel this hierarchy used that capture cannot write for,
  # ordered by channel so two renderings of the same record agree.
  def gaps
    @gaps ||= sessions_by_channel.filter_map do |channel, session_ids|
      next if self.class.configured?(channel)

      Gap.new(
        channel: channel,
        genesis: CHANNEL_BY_GENESIS.key(channel),
        session_ids: session_ids,
        reason: self.class.reason(channel),
        remedy: self.class.remedy(channel)
      )
    end
  end

  def any? = gaps.any?

  private

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
