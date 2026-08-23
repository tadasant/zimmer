# ActionCable logs an ERROR whenever a WebSocket socket operation raises. The
# vast majority of those raises are benign client disconnects: a browser tab
# closes, a laptop sleeps, or a network drops *while the server is mid-write to
# the socket*. `Connection::ClientSocket#write` rescues the resulting
# `Errno::EPIPE` ("Broken pipe") / `Errno::ECONNRESET` ("Connection reset by
# peer") and routes it to `Connection::Base#on_error`, which logs it at `.error`
# (`WebSocket error occurred: <message>`).
#
# The client is already gone, so there is nothing we can fix or retry — it is not
# broken server behavior. Per the repo logging philosophy (benign/expected ->
# debug/info; genuinely broken -> error), a peer-disconnect-mid-write should not
# page us. Left at `.error`, a single "Broken pipe" line trips the critical
# `Zimmer backend logging errors (excludes staging)` alert even though nothing is
# broken. This override downgrades the known benign disconnect signatures to
# `.debug` while every other WebSocket error still surfaces at `.error` for
# diagnosability.
#
# The same reasoning applies to `#dispatch_websocket_message`, patched below: a
# frame that lands after the socket closed is the same "client already gone" race
# arriving through the inbound path instead of an exception.
#
# This is scoped to `on_error`'s message classification and
# `dispatch_websocket_message`'s closed-socket branch — the log text of both is
# preserved verbatim; only the level changes. It mirrors the sibling patch in
# config/initializers/action_cable_idempotent_unsubscribe.rb.
#
# Verified against actioncable 8.1.3's `Connection::Base#on_error`, which does
# exactly one observable thing this override reproduces: `logger.error "WebSocket
# error occurred: #{message}"`. If a Rails upgrade changes that method, re-check
# this patch — test/initializers/action_cable_benign_socket_error_log_level_test.rb
# covers the contract.
require "action_cable/connection/base"

module ActionCable
  module Connection
    class Base
      # Errno classes a socket read/write raises once the peer has gone away.
      # None are server defects and none are retryable — the connection is dead.
      # Message fragments are derived from the constants themselves (rather than
      # hardcoded English) so they stay correct regardless of the platform's
      # canonical strerror text.
      BENIGN_SOCKET_DISCONNECT_ERRNOS = [
        Errno::EPIPE,        # "Broken pipe" — wrote to a socket the client closed
        Errno::ECONNRESET,   # "Connection reset by peer"
        Errno::ECONNABORTED, # "Software caused connection abort"
        Errno::ENOTCONN,     # "Transport endpoint is not connected" (Linux)
        Errno::ESHUTDOWN,    # "Cannot send after transport endpoint shutdown"
        Errno::ETIMEDOUT,    # "Connection timed out"
        Errno::EHOSTUNREACH, # "No route to host"
        Errno::ENETUNREACH   # "Network is unreachable"
      ].freeze

      # Lowercased message fragments that mark a benign client disconnect: the
      # Errno strings above plus the non-Errno stream-teardown cases (EOFError,
      # IOError) that surface the same "client went away mid-write" condition.
      BENIGN_SOCKET_DISCONNECT_FRAGMENTS = (
        BENIGN_SOCKET_DISCONNECT_ERRNOS.map { |klass| klass.new.message.downcase } +
        [ "end of file reached", "closed stream", "stream closed" ]
      ).uniq.freeze

      def on_error(message) # :nodoc:
        # log errors to make diagnosing socket errors easier
        if benign_socket_disconnect?(message)
          logger.debug "WebSocket error occurred: #{message}"
        else
          logger.error "WebSocket error occurred: #{message}"
        end
      end

      # `#receive` hands every inbound frame to `send_async
      # :dispatch_websocket_message`, so frames are dispatched on the async
      # worker pool rather than inline. When a client's socket closes between
      # enqueue and dispatch — a tab that navigates away or reconnects with
      # subscribe frames still in flight — every queued frame takes the
      # closed-socket branch and logs one line. The client is already gone and
      # the ActionCable consumer re-subscribes on reconnect, so there is nothing
      # to fix and nothing to retry; it is the same benign disconnect `#on_error`
      # above handles, reaching us as a stale frame rather than as an exception.
      #
      # Verified against actioncable 8.1.3's
      # `Connection::Base#dispatch_websocket_message`, which does exactly two
      # observable things this override reproduces: `handle_channel_command
      # decode(...)` when the socket is alive, and a single log line (upstream:
      # `.error`) when it is not. The message text — including upstream's stray
      # trailing `)` — is preserved verbatim; only the level changes. If a Rails
      # upgrade changes that method, re-check this patch —
      # test/initializers/action_cable_benign_socket_error_log_level_test.rb
      # covers the contract but cannot detect new upstream side effects on the
      # alive-socket path.
      def dispatch_websocket_message(websocket_message) # :nodoc:
        if websocket.alive?
          handle_channel_command decode(websocket_message)
        else
          logger.debug "Ignoring message processed after the WebSocket was closed: #{websocket_message.inspect})"
        end
      end

      private

      def benign_socket_disconnect?(message)
        downcased = message.to_s.downcase
        BENIGN_SOCKET_DISCONNECT_FRAGMENTS.any? { |fragment| downcased.include?(fragment) }
      end
    end
  end
end
