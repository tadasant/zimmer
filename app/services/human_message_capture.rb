# frozen_string_literal: true

# Writes HumanMessage records.
#
# This is the ONLY way one is created, and it exists so the rule can be stated
# in one place: capture keys off the *authenticated actor at the input
# boundary*, never off the text of the message.
#
# That distinction is the whole feature. `follow_up` issued by Tadas in the
# browser and `follow_up` issued by another agent session over MCP arrive as the
# same kind of `user` turn and end up in the same delivery path — the only thing
# that tells them apart is which controller/tool accepted the request. So the
# boundaries call in explicitly:
#
#   * SessionsController / EnqueuedMessagesController (the browser)
#       → User.admin, because Zimmer has no login and exactly one human can
#         reach the UI. Which user that is comes from the ZIMMER_ADMIN_USER
#         deployment config, not from anything in the request.
#   * SlackTriggerPollerJob (a real Slack message)
#       → User.for_slack_user_id(message.user).
#   * Api::V1::QuickRouterController (the browser extension)
#       → User.admin, the same way as the web UI. It is an API controller, but
#         the credential it takes is not the fleet's: a `quick_router` ApiKey is
#         minted, so no agent session's environment carries it, and it opens
#         nothing but that one endpoint. Its only holder is the browser of the
#         one human the deployment serves, which is what makes the actor at
#         that boundary as established as it is in the web UI.
#   * The MCP tools that deliver words into a session — action_session
#     `follow_up`, start_session, quick_router, manage_enqueued_messages — when
#     the request authenticated with an OAuth grant holding
#     OauthServer::ACT_AS_HUMAN_SCOPE
#       → User.for_email(grant.user_email), the human who approved the client
#         at /oauth/authorize behind the web sign-in wall and chose, there or on
#         the connections page, to let it act on their behalf. A grant without
#         that scope is "relay only" and records nothing.
#   * The same MCP tools called by the Live Mode assistant, through
#     LiveConversations::ToolBridge (in process — never POST /mcp)
#       → the author stamped on the conversation's latest `user` turn by the
#         boundary that accepted it: the web UI (User.admin) or the iOS app on a
#         grant acting as its person (User.for_email). Channel `live_mode`. A turn
#         the `action_live_conversation` MCP tool wrote has no author, and a
#         delivery that follows one records nothing.
#   * Api::V1::SessionsController#follow_up and #authorize_merge, and
#     Api::V1::QuickRouterController, on the iOS app's bearer token
#     (`accepts_native_app_tokens`)
#       → the same record_assistant_message, through the app's grant, with the
#         same fences.
#
# Sessions carry an `auth_identity_email` in metadata that often matches a
# User#email, and it is tempting to attribute from it. It is NOT wired here:
# AuthRecoveryCoordinator writes it to name the pooled Claude login the *agent
# process* was spawned with, so it describes a machine's credentials, not the
# person who typed. Attributing from it would say a human asked for something
# every time an agent ran under Tadas's account. If Zimmer ever
# grows real per-human login, the request's authenticated email is what would
# resolve through User.for_email — at the boundary, from the actor, same rule.
#
# Nothing else calls this. The other Api::V1 controllers, and McpController on
# an API key, authenticate a full-API key, not a person: that key is shared by
# the whole fleet and establishes no human author, so those paths deliberately
# record nothing.
#
# The `assistant` channel is a trust decision the human made, not a fact Zimmer
# established about the words. The arguments of an OAuth client's call are
# written by that client's model, which may be relaying what the human said
# aloud, paraphrasing it, or acting on text that steered it. A grant holding
# OauthServer::ACT_AS_HUMAN_SCOPE is the human saying "treat what this assistant
# sends as mine"; the record says so by naming the grant and the client, so a
# reader can always tell it from a message typed into the web UI. No agent
# session reaches it through the tools it is handed: the fleet authenticates
# with API keys, and a grant is only issued — or raised to this level — by a
# browser signed in at the web sign-in wall. A session's shell on the app host
# can forge that sign-in, which is the same hole that already lets it forge a
# `web_ui` message (docs: limitations, "The web UI does not keep agent sessions
# out"); this channel does not widen it.
#
# Every method is best-effort: a capture failure must never break the delivery
# of the message it was describing. A missing record is a safe outcome.
class HumanMessageCapture
  class << self
    # Record a message typed by a human into the Zimmer web UI.
    #
    # @param session [Session] the session the human was speaking TO
    # @param content [String] the human's own words
    # @param entry_point [String] the specific boundary, e.g. "web_ui.follow_up"
    def record_web_ui_message(session:, content:, entry_point:, occurred_at: Time.current)
      record(
        session: session,
        author: User.admin,
        channel: HumanMessage::WEB_UI,
        content: content,
        occurred_at: occurred_at,
        provenance: { "entry_point" => entry_point }
      )
    end

    # Record a Slack message that resolved to a known human.
    #
    # `slack_user_id` is resolved through the configured map, NOT trusted as a
    # name: an unmapped ID (another workspace member, a bot, an app posting with
    # a bot token) yields nil and records nothing.
    def record_slack_message(session:, slack_user_id:, content:, entry_point:,
                             slack_channel: nil, slack_permalink: nil, occurred_at: Time.current)
      record(
        session: session,
        author: User.for_slack_user_id(slack_user_id),
        channel: HumanMessage::SLACK,
        content: content,
        occurred_at: occurred_at,
        provenance: {
          "entry_point" => entry_point,
          "slack_user_id" => slack_user_id,
          "slack_channel" => slack_channel,
          "slack_permalink" => slack_permalink
        }.compact
      )
    end

    # Record a message an OAuth client delivered on behalf of the human who
    # approved it. Records nothing unless the grant is live, holds
    # OauthServer::ACT_AS_HUMAN_SCOPE, and its approver's email resolves to a
    # roster row.
    #
    # @param grant [OauthServer::Grant, nil] the grant the request authenticated with
    # @param entry_point [String] e.g. "oauth.follow_up"
    def record_assistant_message(session:, grant:, content:, entry_point:, occurred_at: Time.current)
      return nil if grant.nil? || !grant.acts_as_human?

      record(
        session: session,
        author: User.for_email(grant.user_email),
        channel: HumanMessage::ASSISTANT,
        content: content,
        occurred_at: occurred_at,
        provenance: {
          "entry_point" => entry_point,
          "oauth_grant_id" => grant.id,
          "oauth_client_id" => grant.client.client_id,
          "oauth_client_name" => grant.client.client_name.presence,
          "grant_scope" => grant.scope,
          "grant_user_email" => grant.user_email
        }.compact
      )
    end

    # How recent the person's words have to be for a Live Mode delivery to be
    # recorded as theirs. A live model acts within seconds of being spoken to;
    # one acting long after the person last said anything is acting on its own.
    LIVE_MODE_WORDS_FRESH_FOR = 5.minutes
    # Characters of the assistant's relayed text kept beside the person's words.
    LIVE_MODE_RELAYED_LIMIT = 4_000
    # Characters kept of the assistant line a person's words were answering.
    LIVE_MODE_REPLYING_TO_LIMIT = 1_000

    # What live_mode_words answers. `declined` is a sentence fragment saying why
    # there are no words to record ("this conversation has …"), or nil.
    LiveModeWords = Data.define(:turns, :replying_to, :declined) do
      def self.declined(reason) = new(turns: [], replying_to: nil, declined: reason)
    end

    # Record a message the Live Mode assistant delivered into a session, as the
    # words of the person it was talking to.
    #
    # The author comes from the conversation's own `user` turns, never from the
    # tool call: each one is stamped at the boundary that accepted it
    # (LiveConversations::Author — the web UI's sign-in, or the iOS app's grant
    # acting as its person), and a turn written any other way (the
    # `action_live_conversation` MCP tool) carries no author. So this records
    # only when the newest thing a person said in the conversation is
    # authenticated, recent, and therefore what the assistant is acting on.
    #
    # Two things an agent session could write that the live model reads make a
    # conversation ineligible altogether, because either could tell the model to
    # deliver something whenever the person next speaks:
    #
    # * a `user` turn anywhere in the conversation that no boundary established
    #   as a person, such as text the `action_live_conversation` tool typed, which
    #   stays in the model's context (LiveConversation#agent_written?, which also
    #   says why a spoken line from before authors were recorded is not one);
    # * Live mode guidance last written by an agent session, which is in every
    #   conversation's system prompt (LiveSettingChange.guidance_written_by_an_agent?).
    #
    # The content is the person's own words — typed, or their speech as
    # transcribed — not the assistant's rewording of them. What the assistant
    # actually delivered rides in provenance as `relayed_message`, and every
    # rendering shows both, so a reader can see what was said and what the
    # session was told.
    #
    # @param conversation [LiveConversation] the conversation whose tool call delivered it
    # @param content [String] what the assistant delivered into the session
    # @param entry_point [String] e.g. "live_mode.follow_up"
    def record_live_mode_message(session:, conversation:, content:, entry_point:, occurred_at: Time.current)
      return nil if conversation.nil?

      words = live_mode_words(conversation, now: occurred_at)
      return nil if words.declined

      speaker = words.turns.last
      record(
        session: session,
        author: User.for_key(speaker.author),
        channel: HumanMessage::LIVE_MODE,
        content: words.turns.map(&:content).join("\n"),
        occurred_at: occurred_at,
        provenance: live_mode_provenance(conversation, words, entry_point).merge(
          "relayed_message" => content.to_s.strip.truncate(LIVE_MODE_RELAYED_LIMIT)
        )
      )
    rescue => e
      Rails.logger.error("[HumanMessageCapture] Failed to read live conversation #{conversation&.id}: #{e.class}: #{e.message}")
      nil
    end

    # Record the person's spoken or typed "yes" to Zimmer's read-back of a pull
    # request, as the sign-off LiveConversations::AuthorizeMerge delivered on the
    # strength of it. The voice counterpart of the app's Merge button, and recorded
    # in the session holding the PR, the way the button's click is.
    #
    # The caller has already established `words` (live_mode_words, answering the
    # read-back) and checked they say yes. This only writes the record, with
    # what makes a short reply's referent checkable: the PR Zimmer named, the
    # read-back Zimmer composed, and the line the assistant actually said.
    #
    # @param words [LiveModeWords] the person's answer, not declined
    # @param pr_url [String] the PR Zimmer read back and the session was told to merge
    # @param read_back [String] the sentence Zimmer composed and told the model to say
    # @param relayed [String] what was delivered into the session
    def record_live_mode_merge_approval(session:, conversation:, words:, pr_url:, read_back:, relayed:, occurred_at: Time.current)
      return nil if conversation.nil? || words.nil? || words.declined

      record(
        session: session,
        author: User.for_key(words.turns.last.author),
        channel: HumanMessage::LIVE_MODE,
        content: words.turns.map(&:content).join("\n"),
        occurred_at: occurred_at,
        provenance: live_mode_provenance(conversation, words, "live_mode.authorize_merge").merge(
          "confirmed_pr_url" => pr_url,
          "read_back" => read_back.to_s.strip.truncate(LIVE_MODE_RELAYED_LIMIT),
          "relayed_message" => relayed.to_s.strip.truncate(LIVE_MODE_RELAYED_LIMIT)
        )
      )
    rescue => e
      Rails.logger.error("[HumanMessageCapture] Failed to record a Live Mode merge approval for session #{session&.id}: #{e.class}: #{e.message}")
      nil
    end

    # The person's words a Live Mode delivery would be recorded as, or why there
    # are none.
    #
    # `turns`: the newest run of things a person said, oldest first: the latest
    # `user` turn and the `user` turns just before it, back to the assistant's
    # previous answer, each under LIVE_MODE_WORDS_FRESH_FOR old. Assistant lines
    # after that latest turn are skipped, not a stop: on a voice call the model
    # often says "sending that now" before its tool call, and the client records
    # that line first.
    #
    # `replying_to`: the assistant line just before that run, which is what a
    # short reply ("merge it", "yes") was answering. On a voice call it is the
    # transcript of what the person heard. It is recorded beside their words so a
    # reader can see what "it" was, and it is the model's text, so it is shown as
    # that and never as theirs.
    #
    # `declined`: a sentence saying why nothing would be recorded, or nil. Two
    # things an agent session could write that the live model reads make a
    # conversation ineligible altogether, because either could tell the model to
    # deliver something whenever the person next speaks: a `user` line no
    # boundary established as a person (LiveConversation#agent_written?), and
    # Live mode guidance last written by an agent session
    # (LiveSettingChange.guidance_written_by_an_agent?). Then the run has to be
    # one person's alone, and fresh.
    #
    # @param after_turn_id [Integer, nil] only turns after this one count as the
    #   person's words, so an answer to a question is never something said
    #   before the question
    # @return [LiveModeWords]
    def live_mode_words(conversation, now: Time.current, after_turn_id: nil)
      if (old = conversation.unattributable_user_turns.order(:id).pluck(:id)).any?
        return LiveModeWords.declined(
          "this conversation has #{old.size == 1 ? 'a line' : "#{old.size} lines"} that no sign-in vouches for " \
          "(turn#{'s' if old.size > 1} #{old.first(5).join(', ')}#{', …' if old.size > 5}), written by an agent or " \
          "typed before Zimmer recorded who typed what, so nothing relayed from it counts as the person's. " \
          "A new Live conversation does not have this problem"
        )
      end
      if LiveSettingChange.guidance_written_by_an_agent?
        return LiveModeWords.declined("the Live mode guidance was last written by an agent session, so nothing relayed " \
                                      "counts as the person's until a person saves the guidance again")
      end

      run = []
      replying_to = nil
      scope = conversation.turns.where(role: %w[user assistant]).reorder(id: :desc).limit(40)
      scope.each do |turn|
        if turn.user?
          run.unshift(turn)
        elsif run.any?
          replying_to = turn
          break
        end
      end
      return LiveModeWords.declined("nobody has said anything in this conversation yet") if run.empty?

      authors = run.map(&:author).uniq
      if authors.size != 1 || authors.first.blank?
        return LiveModeWords.declined("the person's latest words are not one signed-in person's alone")
      end

      fresh = run.select { |turn| turn.created_at >= now - LIVE_MODE_WORDS_FRESH_FOR }
      fresh = fresh.select { |turn| turn.id > after_turn_id } if after_turn_id
      if fresh.empty?
        return LiveModeWords.declined(after_turn_id ? "the person has not answered since that was said" :
                                        "the person's latest words are more than #{LIVE_MODE_WORDS_FRESH_FOR.inspect} old")
      end

      LiveModeWords.new(turns: fresh, replying_to: replying_to, declined: nil)
    end

    private

    # Who said it, where, and what they were answering: the part of a `live_mode`
    # record every Live Mode entry point shares.
    def live_mode_provenance(conversation, words, entry_point)
      speaker = words.turns.last
      replying_to = words.replying_to
      {
        "entry_point" => entry_point,
        "live_conversation_id" => conversation.id,
        "live_turn_ids" => words.turns.map(&:id),
        "heard" => speaker.source,
        "replying_to" => replying_to&.content.to_s.strip.truncate(LIVE_MODE_REPLYING_TO_LIMIT).presence,
        "replying_to_turn_id" => replying_to&.id
      }.merge(speaker.author_provenance.to_h.slice("via", "surface", "oauth_grant_id", "grant_user_email")).compact
    end

    # @return [HumanMessage, nil] nil whenever the actor could not be
    #   established, the content is empty, or the write failed.
    def record(session:, author:, channel:, content:, occurred_at:, provenance:)
      return nil if session.nil? || !session.persisted?
      return nil if author.nil?

      body = content.to_s.strip
      return nil if body.blank?

      # Truncate rather than reject: an over-long message is still evidence a
      # human asked for something, and losing it entirely would be the worse
      # failure. The marker keeps the rendering honest about it.
      if body.length > HumanMessage::MAX_CONTENT_LENGTH
        body = "#{body[0, HumanMessage::MAX_CONTENT_LENGTH - 20]}\n…[truncated]"
      end

      # The savepoint is what makes the rescue below actually best-effort.
      #
      # Two of the call sites (SessionsController#follow_up, and any future one
      # inside an ActiveRecord::Base.transaction block) run with an enclosing
      # transaction open. In PostgreSQL a failed statement aborts the whole
      # transaction: rescuing the Ruby exception does NOT un-abort it, and every
      # later statement raises PG::InFailedSqlTransaction. Without
      # `requires_new: true` a capture failure would therefore take down the
      # follow-up delivery it was only supposed to describe — the exact opposite
      # of the guarantee this method is written to provide. The savepoint scopes
      # the rollback to this INSERT and leaves the caller's transaction usable.
      HumanMessage.transaction(requires_new: true) do
        session.human_messages.create!(
          author: author.key,
          channel: channel,
          content: body,
          occurred_at: occurred_at,
          provenance: provenance
        )
      end
    rescue => e
      # Capture is observational. If it fails, the message it describes still
      # has to reach the agent.
      Rails.logger.error("[HumanMessageCapture] Failed to record for session #{session&.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
