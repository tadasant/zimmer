# frozen_string_literal: true

# Deletes console login tokens that are long past their expiry (tadasant/zimmer#220).
# Runs hourly via GoodJob cron.
#
# Nothing in the exchange path depends on this: an expired row refuses on its own,
# through the `expires_at > now` half of the exchange's conditional UPDATE, and a
# consumed or revoked row refuses by status. This job only bounds the table. A CI
# job that mints a token per run would otherwise grow it without limit.
#
# Rows are kept for ConsoleLoginToken::RETENTION past their expiry, whatever their
# status, because a consumed row — who logged in, when, from where — is the audit
# trail. The WARN log lines the mint, exchange and revoke each write are the durable
# copy; the table is the one you can query.
class ConsoleLoginTokenReaperJob < ApplicationJob
  include DatabaseRetry
  include SingletonSweep

  # `default`, with the other quick table sweeps (CleanupExpiredElicitationsJob): one
  # indexed DELETE, not the long-running cleanup `maintenance` is fenced off for.
  queue_as :default

  def perform
    deleted = with_db_retry { ConsoleLoginToken.reapable.delete_all }

    Rails.logger.info "[ConsoleLoginTokenReaperJob] deleted #{deleted} console login token(s) expired more than #{ConsoleLoginToken::RETENTION.inspect} ago" if deleted > 0
  end
end
