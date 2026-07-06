# ActionCable logs an ERROR when a client sends an `unsubscribe` command for a
# subscription the server-side connection no longer holds. `Subscriptions#remove`
# routes through `find`, which raises `RuntimeError - Unable to find subscription
# with identifier: {...}`; `execute_command`'s catch-all rescue then logs that at
# `.error`.
#
# That condition is a benign, expected client/server race — a browser sending a
# stale or duplicate unsubscribe on reconnect, a tab closing, or a double
# unsubscribe — not a failure we control or can retry. Per the repo logging
# philosophy (benign/expected -> debug/info; genuinely broken -> error), removing
# a subscription should be idempotent: a no-op (logged at `.debug`) when the
# subscription is already gone, rather than an ERROR that trips the
# `agent-orchestrator-errors` and `Rails ERROR logs present (prod)` alerts.
#
# This is scoped to the unsubscribe/remove path only. Every other ActionCable
# command error — unrecognized commands, and `find` failures on the `message`
# (perform_action) path — still surfaces at `.error`.
#
# Verified against actioncable 8.1.3's `Connection::Subscriptions#remove`, which
# does exactly two observable things this override reproduces: an `.info`
# "Unsubscribing from channel" log, then `remove_subscription` when the
# subscription exists. If a Rails upgrade changes that method, re-check this
# patch — test/initializers/action_cable_idempotent_unsubscribe_test.rb covers
# the contract but cannot detect new upstream side effects on the happy path.
require "action_cable/connection/subscriptions"

module ActionCable
  module Connection
    class Subscriptions
      def remove(data)
        logger.info "Unsubscribing from channel: #{data["identifier"]}"
        subscription = subscriptions[data["identifier"]]
        if subscription
          remove_subscription subscription
        else
          logger.debug "Ignoring unsubscribe for unknown subscription identifier: #{data["identifier"]}"
        end
      end
    end
  end
end
