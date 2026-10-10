# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Every route Zimmer draws, sorted into exactly one of four kinds, so a new
# browser page cannot ship outside the web login wall unnoticed and a machine
# path cannot be walled off by accident:
#
#   walled           a controller that includes WebSignInRequired. Proven by
#                    REQUEST: with the gate on and no cookie, every route answers
#                    a redirect to /login or a 401, and never reaches its action.
#   signed-out       SIGNED_OUT_REACHABLE, exactly: the login flow, the 404 page,
#                    /up/deep. Plus health#export_diagnostics, but only for a
#                    request from the host itself; the walk asks from outside.
#   machine          Api::BaseController, Webhooks::BaseController and
#                    OauthServer::BaseController (REST, /mcp, the webhooks, the
#                    OAuth endpoints for /mcp). An API key, a signature, or PKCE,
#                    never a cookie.
#   framework        FRAMEWORK_CONTROLLERS, each with the reason it is harmless.
class WebSignInRouteAuditTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  SIGNED_OUT_REACHABLE = %w[
    web_sign_ins#new
    web_sign_ins#create
    web_sign_ins#callback
    web_sign_ins#destroy
    web_second_factors#new
    web_second_factors#create
    web_second_factors#setup
    web_second_factors#confirm_setup
    errors#not_found
    health#deep
  ].to_set.freeze

  # The walk asks as a client on the internet would. The test client's default
  # address is loopback, and health#export_diagnostics answers a request that
  # never left the host signed out (HealthControllerWebAuthTest covers that case).
  PUBLIC_CLIENT = "198.51.100.23"

  # OauthServer::BaseController: the OAuth discovery, registration, token and
  # revocation endpoints for /mcp. A client authenticates with PKCE or a token
  # it holds, never a cookie. (/oauth/authorize is a browser page, and walled.)
  MACHINE_BASES = [ Api::BaseController, Webhooks::BaseController, OauthServer::BaseController ].freeze

  FRAMEWORK_CONTROLLERS = {
    "rails/health" => "/up: answers 200 to any process that booted, and says nothing else",
    "turbo/native/navigation" => "turbo-rails' recede/resume/refresh redirects for native apps; they render nothing",
    "active_storage/" => "Active Storage is drawn but unused: db/schema.rb has no active_storage_* tables, so there is no blob to serve and no upload to accept",
    "action_mailbox/" => "Action Mailbox is drawn but unused: no action_mailbox_* tables, and every ingress demands its own password",
    "rails/conductor/" => "Action Mailbox's conductor refuses every request outside development",
    "native_access_handoffs" => "the iOS app's edge handoff: hands back only the Cloudflare Access assertion the request already carries, after verifying it (signature, iss, exp, required aud); 403 without one, and every API call still needs Zimmer's own OAuth token"
  }.freeze

  test "every routed controller is walled, a machine path, or a named framework route" do
    unexplained = app_routes.filter_map do |route|
      controller = route[:controller_class]
      next if controller.nil? && framework_reason(route[:controller])
      next if controller && (controller.include?(WebSignInRequired) || MACHINE_BASES.any? { |base| controller <= base })
      next if framework_reason(route[:controller])

      "#{route[:verb]} #{route[:path]} -> #{route[:controller]}##{route[:action]} (#{controller&.superclass || "no such controller"})"
    end.uniq

    assert_empty unexplained, <<~MESSAGE
      These routes reach a controller that is neither behind the web login wall nor a
      known machine path. A browser page inherits ApplicationController (or includes
      WebSignInRequired); a machine endpoint inherits Api::BaseController or
      Webhooks::BaseController; anything else needs a reason in FRAMEWORK_CONTROLLERS.

      #{unexplained.join("\n")}
    MESSAGE
  end

  test "the mounted apps: GoodJob's dashboard is walled, and the cable has its own check" do
    mounted = Rails.application.routes.routes.filter_map { |r| r.app.app if r.app.respond_to?(:app) && r.defaults[:controller].nil? }

    assert_includes mounted, GoodJob::Engine
    assert_includes GoodJob::ApplicationController.ancestors, WebSignInRequired
    assert(mounted.any? { |app| app.is_a?(ActionCable::Server::Base) }, "expected /cable to be mounted")
    assert_includes ApplicationCable::Connection.instance_method(:connect).source_location.first, "app/channels/application_cable/connection.rb"
  end

  test "with the gate on and no cookie, every walled route refuses, and only the named ones let a browser through" do
    enable_web_auth
    walled = app_routes.select { |r| r[:controller_class]&.include?(WebSignInRequired) }
    assert_operator walled.size, :>, 100, "expected the audit to see the whole web UI"

    reached = []
    walled.each do |route|
      key = "#{route[:controller]}##{route[:action]}"
      next if SIGNED_OUT_REACHABLE.include?(key)

      reset!
      process(route[:verb].downcase.to_sym, route[:sample_path], env: { "REMOTE_ADDR" => PUBLIC_CLIENT })

      walled_off = (response.redirect? && URI(response.location).path == "/login") || response.status == 401
      reached << "#{route[:verb]} #{route[:sample_path]} -> #{key} answered #{response.status}" unless walled_off
    end

    assert_empty reached, "these routes answered a signed-out request without the login wall:\n#{reached.join("\n")}"
  end

  test "the path-based machine exemption never covers a browser page" do
    browser_pages = app_routes.select { |r| r[:controller_class]&.include?(WebSignInRequired) }
      .reject { |r| r[:controller] == "health" && r[:action] == "deep" }
      .select { |r| r[:sample_path].match?(WebSignInRequired::MACHINE_PATHS) }
      .map { |r| "#{r[:verb]} #{r[:path]} -> #{r[:controller]}##{r[:action]}" }

    assert_empty browser_pages, "these walled pages sit under WebSignInRequired::MACHINE_PATHS and would be let through:\n#{browser_pages.join("\n")}"
  end

  test "the signed-out list names real actions, and each one is genuinely let through" do
    routed = app_routes.map { |r| "#{r[:controller]}##{r[:action]}" }.to_set

    assert_empty SIGNED_OUT_REACHABLE - routed, "SIGNED_OUT_REACHABLE names actions that no route reaches"

    enable_web_auth
    get "/login"
    assert_response :success
    get "/no/such/page"
    assert_response :not_found
  end

  private

  def app_routes
    @app_routes ||= Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next if controller.nil?

      verb = route.verb.to_s.split("|").first.presence || "GET"
      {
        controller: controller,
        action: route.defaults[:action],
        verb: verb,
        path: route.path.spec.to_s,
        sample_path: sample_path(route.path.spec.to_s),
        controller_class: "#{controller.camelize}Controller".safe_constantize
      }
    end
  end

  # "/sessions/:id/archive(.:format)" -> "/sessions/1/archive"
  def sample_path(spec)
    path = spec.dup
    path = path.gsub(/\([^()]*\)/, "") while path.match?(/\([^()]*\)/)
    path = path.gsub(/:\w+/, "1").gsub(/\*\w+/, "x")
    path.presence || "/"
  end

  def framework_reason(controller)
    FRAMEWORK_CONTROLLERS.find { |prefix, _| prefix.end_with?("/") ? controller.start_with?(prefix) : controller == prefix }&.last
  end
end
