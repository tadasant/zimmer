# frozen_string_literal: true

namespace :zimmer do
  desc "Report a wedged worker through the obs pipeline, from the watchdog incident JSON on stdin"
  # The host-side watchdog's delivery path:
  #   docker exec -i <web> bin/rails zimmer:worker_wedge_alert  < incident.json
  #
  # It runs in the WEB container on purpose -- the worker is the thing that is broken,
  # and web holds the same credentials. See app/services/worker_wedge_alert.rb.
  #
  # Exits 0 whether or not the report reaches the obs stack. An unreachable collector
  # or GlitchTip is an outcome the watchdog should log rather than retry: it has
  # already written the incident to disk and to journald, which is the record that
  # does not depend on anything being up.
  task worker_wedge_alert: :environment do
    payload = $stdin.read

    WorkerWedgeAlert.report(payload)
    puts "worker wedge incident recorded (ERROR log record + GlitchTip event)"
  end
end
