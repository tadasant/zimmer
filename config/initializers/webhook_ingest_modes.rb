# frozen_string_literal: true

# Reads every inbound webhook mode once at boot, so a deployment still configured with a mode
# Zimmer no longer accepts says so in the boot log (Webhooks::Source#mode WARNs once per process)
# instead of on the first poll or delivery. The read changes nothing: each source resolves its
# mode again on every use. Never fatal — a boot must not fail over a log line.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  [ *Webhooks::Source.all, Webhooks::Source.github_prs ].each(&:mode)
rescue => e
  Rails.logger.warn("[webhook_ingest_modes] Could not read the inbound webhook modes at boot: #{e.class}: #{e.message}")
end
