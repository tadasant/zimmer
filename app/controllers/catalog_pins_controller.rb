# frozen_string_literal: true

# Persists the catalog ref pins configured on the settings page. Each submitted
# row maps a `github://owner/repo` catalog to a ref (commit SHA / tag / branch);
# a blank ref clears the pin so that catalog tracks HEAD again.
#
# The save and the catalog re-resolve happen inside one transaction: if the new
# pin set fails to resolve (e.g. a non-existent SHA), the transaction rolls back
# and nothing is persisted, so a bad pin can never wedge catalog resolution.
class CatalogPinsController < ApplicationController
  def update
    pinnable = AirCatalogService.pinnable_catalogs

    ActiveRecord::Base.transaction do
      Array(params[:pins]).each do |entry|
        catalog = entry[:catalog].to_s
        # Ignore anything not declared as a pinnable catalog in air.json.
        next unless pinnable.include?(catalog)

        ref = entry[:ref].to_s.strip
        pin = CatalogPin.find_or_initialize_by(catalog: catalog)

        if ref.blank?
          pin.destroy if pin.persisted?
        else
          pin.update!(ref: ref)
        end
      end

      # Validate the new pin set actually resolves before committing. Raises
      # CatalogError on failure, rolling back the pin changes above.
      AirCatalogService.refresh!
    end

    redirect_to settings_path, notice: "Catalog pins updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: "Invalid pin: #{e.record.errors.full_messages.join(", ")}"
  rescue AirCatalogService::CatalogError => e
    redirect_to settings_path,
      alert: "Pins not saved — catalogs failed to resolve with those refs (check the SHAs): #{e.message}"
  end
end
