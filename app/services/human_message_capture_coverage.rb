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
# == Why genesis, and why only two of the kinds
#
# `CHANNEL_BY_GENESIS` maps each of the two channels in `HumanMessage::CHANNELS`
# to the genesis whose sessions arrive over it. The other genesis kinds split two
# ways. A GitHub issue or label, a schedule, a session-state or system event, an
# API spawn: no human actor at the boundary by construction, so an empty record
# there is the correct, intended answer rather than a gap. `unknown` is the
# exception and is a blind spot rather than a construction — it means the origin
# could not be established (chiefly rows predating the genesis column), so a
# Slack-origin session sitting on `unknown` reports no gap.
#
# Widening this to every kind would replace an affirmative absence with "cannot
# say" on nearly every hierarchy in the fleet, which destroys the signal the
# record exists to carry.
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
      else
        "Give this channel a check in HumanMessageCaptureCoverage.configured?."
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
