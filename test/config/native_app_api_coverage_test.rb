# frozen_string_literal: true

require "test_helper"

# Every REST endpoint Zimmer's iOS app calls must accept the app's OAuth bearer
# token. The opt-in is per controller (`accepts_native_app_tokens`), so an
# endpoint added to the app without it would pass every app test — they run
# against a fake — and then answer 401 on a phone.
#
# The list of endpoints is read from the app's own source: every `"/api/v1/..."`
# string literal under ios/Sources, with Swift interpolations filled in. A new
# call in a later PR is covered the moment it is written.
class NativeAppApiCoverageTest < ActiveSupport::TestCase
  SOURCES = Rails.root.join("ios/Sources")
  METHODS = %w[GET POST PATCH PUT DELETE].freeze

  def app_paths
    Dir.glob(SOURCES.join("**/*.swift")).flat_map do |file|
      File.read(file).scan(%r{"(/api/v1/[^"]*)"}).flatten
    end.uniq.map { |path| path.gsub(/\\\([^)]*\)/, "1") }
  end

  def controllers_for(path)
    METHODS.filter_map do |verb|
      route = Rails.application.routes.recognize_path(path, method: verb)
      controller = "#{route[:controller]}_controller".camelize.constantize
      # The catch-all error route answers every verb nothing else does.
      controller if controller < Api::BaseController
    rescue ActionController::RoutingError
      nil
    end.uniq
  end

  test "the app's source names at least one endpoint, so this test is checking something" do
    assert_includes app_paths, "/api/v1/sessions"
  end

  test "every controller behind an endpoint the iOS app calls accepts its bearer token" do
    app_paths.each do |path|
      controllers = controllers_for(path)
      assert controllers.any?, "the iOS app calls #{path}, which no route serves"
      controllers.each do |controller|
        assert controller.native_app_tokens_accepted,
          "the iOS app calls #{path}, but #{controller.name} does not declare accepts_native_app_tokens"
      end
    end
  end

  test "a controller the app does not call stays closed to its token" do
    refute Api::V1::ConfigsController.native_app_tokens_accepted
    refute Api::V1::ExternalAppTriggersController.native_app_tokens_accepted
  end
end
