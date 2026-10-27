# frozen_string_literal: true

# Tells the operator, straight from Rails, that a session could not be spawned
# because the Claude Code pool had no account holding a usable access token.
#
# == Why this does not go through a Trigger ==
#
# The per-account `account_needs_reauth` event is delivered by an `ao_event`
# Trigger that spawns an agent session to DM the operator. That is the right
# shape while the pool still has something in it. It is exactly the wrong shape
# when the pool has nothing: the notification session needs a Claude account to
# run, so it is refused for the very reason it was created to report
# (tadasant/zimmer#1399, session 25913). This alert needs no session to run.
#
# == What it does ==
#
# 1. An ERROR log record. That is the page: it ships to the obs stack and trips
#    the Grafana rule on Zimmer's error records, which is what reaches #alerts.
# 2. A push notification (web push and APNs), attached to the session that was
#    refused, so it lands on the operator's phone with a link to something real.
#
# Both carry #diagnosis: what each account in the pool is doing and what, if
# anything, a human has to do about it. An account whose organization disabled
# Claude Code is named as such, because no amount of re-authenticating fixes it
# — someone has to re-enable it in the organization or remove it from the pool.
#
# == Throttle ==
#
# One alert per THROTTLE, claimed by a single conditional UPDATE on
# `app_settings.pool_outage_alerted_at`. During an outage every spawn attempt
# reaches this, and a fleet refused in the same minute must produce one page,
# not one per session. In the database rather than Rails.cache for the reason
# ClaudeAccount#claim_reauth_alert_slot! gives: a cache-backed throttle fails
# open, and an unreachable Redis would turn into a page per spawn.
class PoolOutageAlert
  THROTTLE = 1.hour

  # @param session [Session] the session whose spawn was refused
  # @param park_reason [String, nil] the AuthOutageParkService reason it parked on
  # @return [Boolean] true when this call sent the alert
  def self.alert!(session:, park_reason: nil, runtime: ClaudeAuthProvider::RUNTIME)
    new(session: session, park_reason: park_reason, runtime: runtime).alert!
  end

  def initialize(session:, park_reason:, runtime:)
    @session = session
    @park_reason = park_reason
    @runtime = runtime
  end

  def alert!
    return false unless claim_slot!

    text = message
    Rails.logger.error("[PoolOutageAlert] #{text}")
    push(text)
    true
  rescue => e
    # Never let alerting break the park it rides on.
    Rails.logger.warn("[PoolOutageAlert] Could not send the pool outage alert: #{e.class}: #{e.message}")
    false
  end

  # One line per account, saying what it is doing and what it needs.
  #
  # @return [Array<String>]
  def diagnosis
    accounts = RuntimeAuthProvider.for(@runtime).accounts.order(:priority, :id).to_a
    return [ "The pool has no #{runtime_label} accounts at all — add one at /inference." ] if accounts.empty?

    accounts.map { |account| "#{account.email}: #{account_line(account)}" }
  end

  def message
    lines = [
      "No #{runtime_label} account in the pool holds a usable access token, so sessions cannot start. " \
        "Session ##{@session&.id} and any others refused while this lasts are parked " \
        "(#{@park_reason || 'auth outage'}) and resume automatically when an account becomes usable."
    ]
    lines.concat(diagnosis.map { |line| "- #{line}" })
    lines.join("\n")
  end

  private

  def account_line(account)
    if account.access_disabled?
      "its organization disabled Claude subscription access for Claude Code. Re-authenticating will not fix this — " \
        "re-enable Claude Code for that organization, or remove the account from the pool at /inference."
    elsif account.needs_reauth?
      "needs re-authentication — press Authenticate for it on /inference."
    elsif account.quota_exceeded?
      "over quota#{reset_suffix(account)} — restored automatically when its window resets."
    elsif account.oauth_config.blank? || account.claude_access_token.blank?
      "holds no access token — authenticate it on /inference."
    elsif account.credential_rejected?
      "Anthropic refused its stored access token — re-authenticate it on /inference."
    else
      "active and holding a token (it may have been refused by its probe at spawn time)."
    end
  end

  def reset_suffix(account)
    snapshot = account.latest_snapshot
    reset = [ snapshot&.reset_5h, snapshot&.reset_7d ].compact.select { |t| t > Time.current }.max
    reset ? " until #{reset.utc.iso8601}" : ""
  rescue
    ""
  end

  def runtime_label
    RuntimeRegistry.label_for(@runtime)
  end

  def claim_slot!
    setting = AppSetting.current
    setting.save! unless setting.persisted?

    now = Time.current
    AppSetting
      .where(id: setting.id)
      .where("pool_outage_alerted_at IS NULL OR pool_outage_alerted_at < ?", THROTTLE.ago)
      .update_all(pool_outage_alerted_at: now, updated_at: now) == 1
  end

  def push(text)
    return unless @session

    SendPushNotificationJob.perform_later(@session.id, :custom_message, text.gsub(/\s*\n-?\s*/, " "))
  rescue => e
    Rails.logger.warn("[PoolOutageAlert] Could not enqueue the push: #{e.class}: #{e.message}")
  end
end
