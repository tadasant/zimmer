# frozen_string_literal: true

# Reaps zombie subprocesses by calling Process.waitpid with WNOHANG until ECHILD.
#
# Defense in depth alongside the tini init shim (`init: true` in deploy*.yml).
# If the init shim is in place, this loop typically finds nothing — it's
# present so that any zombie regression doesn't silently grow over days.
#
# See tadasant/zimmer-catalog#3549 for the original incident: 6,032 zombies
# accumulated under the worker over ~2 days, degrading session startup
# until the worker container was restarted.
#
# Known race with ProcessLifecycleManager#wait_nonblock(specific_pid):
#   AgentSessionJob's monitoring loop calls wait_nonblock on a specific pid
#   to learn the child's exit status and route through handle_exit (which
#   implements SIGTERM retry, /compact retry on context-length errors, API
#   server-error backoff, and failure_reason mapping). If this reaper wins
#   the race and reaps a tracked child first, that wait_nonblock raises
#   ECHILD and the loop falls through to the signal-based fallback at
#   agent_session_job.rb (search "Fallback process detection using signal 0"),
#   which calls session.pause! directly — bypassing handle_exit's recovery
#   branches.
#
# Why this is tolerable: the fallback degrades gracefully to needs_input,
# and with the tini init shim active this loop should reap nothing in the
# common case. If the warn-level "Reaped N zombie(s)" log fires repeatedly
# in production, that's the signal to revisit (either fix the upstream
# leak or make this reaper pid-aware via ProcessRegistry).
class ZombieReaperJob < ApplicationJob
  queue_as :default

  def perform
    reaped = 0

    loop do
      pid = Process.waitpid(-1, Process::WNOHANG)
      break if pid.nil?
      reaped += 1
    end
  rescue Errno::ECHILD
    # No more children to reap. Expected — this is the loop's exit condition
    # when there are no waitable children left.
  ensure
    if reaped > 0
      Rails.logger.warn "[ZombieReaperJob] Reaped #{reaped} zombie subprocess(es). " \
        "If this is non-zero in production, the tini init shim may not be active " \
        "or some descendants are escaping it — investigate."
    else
      Rails.logger.info "[ZombieReaperJob] No zombies to reap"
    end
  end
end
