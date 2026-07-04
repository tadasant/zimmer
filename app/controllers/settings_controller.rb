# frozen_string_literal: true

# Controller for application settings.
#
# Provides a centralized location for user preferences including
# push notification configuration and deployment information.
class SettingsController < ApplicationController
  def show
    @deployment_info = DeploymentInfoService.info

    # Global session defaults (base runtime + model). The runtime/model selectors
    # reuse the new-session form's Stimulus controllers, so they need the same
    # per-runtime catalog data: which models each runtime offers and each
    # runtime's own default.
    @app_setting = AppSetting.current
    runtimes = RuntimeRegistry.registered_runtimes
    @runtimes_for_select = runtimes.map { |runtime| { id: runtime, label: RuntimeRegistry.label_for(runtime) } }
    @runtime_models = runtimes.index_with { |runtime| ModelCatalog.model_ids_for(runtime) }
    @runtime_default_models = runtimes.index_with { |runtime| ModelCatalog.default_for(runtime) }

    @selected_runtime = @app_setting.default_runtime.presence || RuntimeRegistry::DEFAULT_RUNTIME
    @selected_model = @app_setting.default_model.presence || ModelCatalog.default_for(@selected_runtime)

    # The "Experimental" section is data-driven from the extension registry, so a
    # dropped extension disappears from the UI with no view edit. Each entry knows
    # its own id/title/description and current enablement.
    @extensions = Ao::ExtensionRegistry.experimental
  end
end
