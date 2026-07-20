# frozen_string_literal: true

namespace :sessions do
  desc "Remove catalog skill ids that no longer resolve from non-archived sessions (DRY_RUN=true to preview)"
  task heal_stale_catalog_skills: :environment do
    dry_run = ENV["DRY_RUN"] == "true"

    # The same two guards AirPrepareService#scrubbed_catalog_skills applies, for
    # the same reason: an empty catalog makes every id look stale, and a degraded
    # (last-known-good) catalog can be missing ids that were added after the
    # snapshot. Either would strip valid skills — and unlike the runtime scrub,
    # a sweep writes to every session at once.
    if SkillsConfig.all.empty?
      abort "Catalog is empty (resolution failed) — refusing to sweep; every id would look stale."
    end
    if AirCatalogService.degraded?
      abort "Catalog is degraded (serving a last-known-good snapshot) — refusing to sweep; " \
            "repair resolution first so freshly-added skills aren't mistaken for stale ones."
    end

    healed = 0
    Session.where.not(status: :archived).find_each do |session|
      requested = Array(session.catalog_skills).reject(&:blank?)
      next if requested.empty?

      stale = requested.reject { |id| SkillsConfig.exists?(id) }
      next if stale.empty?

      valid = requested - stale
      puts "Session #{session.id}: removing #{stale.join(', ')} (remaining: #{valid.presence&.join(', ') || '(none)'})"
      session.update_column(:catalog_skills, valid) unless dry_run
      healed += 1
    end

    puts dry_run ? "DRY RUN — #{healed} session(s) would be healed." : "Healed #{healed} session(s)."
  end
end
