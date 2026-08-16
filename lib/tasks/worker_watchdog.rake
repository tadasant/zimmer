# frozen_string_literal: true

namespace :zimmer do
  desc "Page #eng-alerts about a wedged worker, from the watchdog incident JSON on stdin"
  # The host-side watchdog's delivery path:
  #   docker exec -i <web> bin/rails zimmer:worker_wedge_alert  < incident.json
  #
  # It runs in the WEB container on purpose -- the worker is the thing that is broken,
  # and web holds the same credentials. See app/services/worker_wedge_alert.rb.
  #
  # Exits 0 whether or not the alert reaches Slack. A suppressed duplicate, an
  # environment that does not own the alert channel, and a Slack outage are all
  # outcomes the watchdog should log rather than retry: it has already written the
  # incident to disk and to journald, which is the record that does not depend on
  # anything being up.
  task worker_wedge_alert: :environment do
    payload = $stdin.read

    if WorkerWedgeAlert.report(payload)
      puts "worker wedge alert sent"
    else
      puts "worker wedge alert NOT sent (suppressed as a duplicate, gated by environment, or Slack unavailable)"
    end
  end
end
