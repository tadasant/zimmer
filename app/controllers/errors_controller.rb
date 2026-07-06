# Handles unmatched routes (routing misses) so they no longer bubble up as an
# ActionController::RoutingError. Rails' default DebugExceptions middleware logs
# every RoutingError at ERROR level, and a single ERROR line trips the critical
# "Zimmer ERROR logs present" Grafana alert. A routine 404 (favicon
# probe, stale API path a client is hitting, etc.) is not "broken system behavior
# requiring attention", so it is logged at INFO here instead.
#
# This only intercepts routing misses — the bottom catch-all route in routes.rb
# directs unmatched paths here. Real exceptions raised inside other controllers
# are unaffected and continue to log at ERROR.
class ErrorsController < ApplicationController
  # The catch-all route forwards every verb (via: :all) here, so non-GET misses reach
  # this controller. ApplicationController inherits Rails' default :exception CSRF
  # strategy, which would run verify_authenticity_token before the action and raise
  # ActionController::InvalidAuthenticityToken (logged at ERROR) on a tokenless
  # POST/PUT/etc — re-tripping the very alert this controller exists to silence. A 404
  # response carries no state to protect, so skipping forgery protection is safe.
  skip_forgery_protection

  def not_found
    Rails.logger.info("Unmatched route 404: #{request.request_method} #{request.path}")

    if request.path.start_with?("/api/")
      render json: { error: "Not Found", message: "The requested resource was not found" },
        status: :not_found
    else
      render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
    end
  end
end
