# frozen_string_literal: true

require "test_helper"

# Contract test for ensuring all models are exposed via the Supervisor admin interface.
#
# Historical context:
# When the SubagentTranscript model was added, it was not registered with Supervisor
# (Administrate), making it invisible in the admin dashboard. This test ensures all
# models are properly exposed through Supervisor.
#
# What this test checks:
# 1. Every model has a corresponding dashboard in app/dashboards/
# 2. Every model has a corresponding controller in app/controllers/supervisor/
# 3. Every model is routed in the supervisor namespace in routes.rb
#
# Models excluded from this requirement:
# - ApplicationRecord (base class, not intended for admin interface)
# - Concerns (modules in app/models/concerns/, not actual models)
#
class SupervisorCoverageTest < ActiveSupport::TestCase
  # Models that should NOT have Supervisor interfaces
  # (base classes, internal framework models, infrastructure models, etc.)
  EXCLUDED_MODELS = %w[
    ApplicationRecord
    Notification
    PushSubscription
    CatalogSnapshot
  ].freeze

  test "all models have a corresponding Supervisor dashboard" do
    model_names = collect_model_names
    dashboard_names = collect_dashboard_names

    missing_dashboards = model_names - dashboard_names

    assert_empty missing_dashboards, format_missing_message(
      "Models missing Supervisor dashboards",
      missing_dashboards,
      "app/dashboards/",
      "_dashboard.rb"
    )
  end

  test "all models have a corresponding Supervisor controller" do
    model_names = collect_model_names
    controller_names = collect_supervisor_controller_names

    missing_controllers = model_names - controller_names

    assert_empty missing_controllers, format_missing_message(
      "Models missing Supervisor controllers",
      missing_controllers,
      "app/controllers/supervisor/",
      "_controller.rb"
    )
  end

  test "all models are routed in the Supervisor namespace" do
    model_names = collect_model_names
    routed_resources = collect_supervisor_routed_resources

    missing_routes = model_names - routed_resources

    assert_empty missing_routes, format_route_message(missing_routes)
  end

  private

  def collect_model_names
    model_files = Dir.glob(Rails.root.join("app/models/*.rb"))

    model_files.filter_map do |file|
      basename = File.basename(file, ".rb")
      # Convert filename to class name (e.g., "subagent_transcript" -> "SubagentTranscript")
      class_name = basename.camelize

      # Skip excluded models
      next if EXCLUDED_MODELS.include?(class_name)

      class_name
    end
  end

  def collect_dashboard_names
    dashboard_files = Dir.glob(Rails.root.join("app/dashboards/*_dashboard.rb"))

    dashboard_files.map do |file|
      # Extract model name from dashboard file
      # e.g., "session_dashboard.rb" -> "Session"
      basename = File.basename(file, ".rb")
      basename.sub(/_dashboard$/, "").camelize
    end
  end

  def collect_supervisor_controller_names
    controller_files = Dir.glob(Rails.root.join("app/controllers/supervisor/*_controller.rb"))

    # Exclude the application_controller.rb which is the base class
    controller_files.filter_map do |file|
      basename = File.basename(file, ".rb")
      next if basename == "application_controller"

      # Extract model name from controller file
      # e.g., "sessions_controller.rb" -> "Session"
      basename.sub(/_controller$/, "").singularize.camelize
    end
  end

  def collect_supervisor_routed_resources
    routes_file = Rails.root.join("config/routes.rb")
    content = File.read(routes_file)

    # Find the supervisor namespace block and extract resource definitions
    # Match pattern: namespace :supervisor do ... end
    # Use \bend\b to match "end" as a whole word (not "end" within "credentials")
    supervisor_block = content.match(/namespace :supervisor do(.*?)\bend\b/m)
    return [] unless supervisor_block

    block_content = supervisor_block[1]

    # Extract resource names from `resources :xxx` declarations
    resources = block_content.scan(/resources\s+:(\w+)/).flatten

    # Convert to singular model names (e.g., "sessions" -> "Session")
    resources.map { |r| r.singularize.camelize }
  end

  def format_missing_message(title, missing_items, directory, suffix)
    message = "\n#{title}:\n\n"
    missing_items.each do |item|
      filename = "#{item.underscore}#{suffix}"
      message += "  • #{item} (expected file: #{directory}#{filename})\n"
    end
    message += "\nResolution:\n"
    message += "Create the missing files following the existing patterns in #{directory}\n"
    message += "See existing dashboards/controllers for examples of the required structure."
    message
  end

  def format_route_message(missing_routes)
    message = "\nModels missing Supervisor routes:\n\n"
    missing_routes.each do |model|
      resource_name = model.underscore.pluralize
      message += "  • #{model} (add `resources :#{resource_name}` to supervisor namespace)\n"
    end
    message += "\nResolution:\n"
    message += "Add the missing resources to the supervisor namespace in config/routes.rb:\n\n"
    message += "  namespace :supervisor do\n"
    missing_routes.each do |model|
      message += "    resources :#{model.underscore.pluralize}\n"
    end
    message += "  end\n"
    message
  end
end
