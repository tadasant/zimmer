# frozen_string_literal: true

module LiveConversations
  # The spend caps on the experimental voice engines (LiveSetting
  # `voice_engine_conversation_cap_usd` and `voice_engine_daily_cap_usd`).
  #
  # Spend is the LiveUsageEvent ledger's list price for one engine, even for
  # Claude marked as on a subscription (`voice_claude_billing`): Zimmer calls
  # Claude with a metered API key until a subscription credential is wired, so
  # marking it free must not lift the ceiling on money still being charged.
  # That is: what it has cost this
  # conversation, and what it has cost today in the deployment's time zone,
  # across every conversation. At WARN_SHARE of either cap a call is warned
  # (the warning goes to the front end as quiet context and onto the page);
  # at the cap the engine is refused — a call starting falls back to
  # `openai_realtime`, and a call in progress is told to end, after which the
  # next one starts on the default (VoiceEngine).
  #
  # The default engine is not capped: there is nothing cheaper-and-safe to
  # fall back to, and capping it would leave Live Mode with no voice at all.
  class SpendGuard
    WARN_SHARE = 0.8

    Check = Data.define(:engine, :conversation_spend, :daily_spend, :conversation_cap, :daily_cap) do
      def blocked? = conversation_spend >= conversation_cap || daily_spend >= daily_cap

      def warn? = !blocked? && (conversation_spend >= conversation_cap * WARN_SHARE || daily_spend >= daily_cap * WARN_SHARE)

      def reason
        return nil unless blocked?

        if conversation_spend >= conversation_cap
          "#{engine} reached its per-conversation cap (#{money(conversation_spend)} of #{money(conversation_cap)})"
        else
          "#{engine} reached its daily cap (#{money(daily_spend)} of #{money(daily_cap)} today)"
        end
      end

      def warning
        return nil unless warn?

        "#{engine} has used #{money(conversation_spend)} of its #{money(conversation_cap)} per-conversation cap and " \
          "#{money(daily_spend)} of its #{money(daily_cap)} daily cap. At either cap the call ends and Live Mode goes back to OpenAI Realtime."
      end

      def as_api_json
        { engine: engine, conversation_spend_usd: conversation_spend.round(4), daily_spend_usd: daily_spend.round(4),
          conversation_cap_usd: conversation_cap, daily_cap_usd: daily_cap, warn: warn?, blocked: blocked?, reason: reason }
      end

      private

      def money(value) = format("$%.2f", value)
    end

    def self.check(engine:, conversation:, setting: LiveSetting.current, now: Time.current)
      new(engine: engine, conversation: conversation, setting: setting, now: now).check
    end

    def initialize(engine:, conversation:, setting: LiveSetting.current, now: Time.current)
      @engine = engine.to_s
      @conversation = conversation
      @setting = setting
      @now = now
    end

    # @return [Check]
    def check
      scope = LiveUsageEvent.for_engine(@engine)
      Check.new(
        engine: @engine,
        conversation_spend: @conversation&.id ? scope.where(live_conversation_id: @conversation.id).sum(:cost_usd).to_f : 0.0,
        daily_spend: scope.where(occurred_at: @now.beginning_of_day..).sum(:cost_usd).to_f,
        conversation_cap: @setting.effective(:voice_engine_conversation_cap_usd).to_f,
        daily_cap: @setting.effective(:voice_engine_daily_cap_usd).to_f
      )
    end
  end
end
