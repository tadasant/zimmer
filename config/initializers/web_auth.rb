# frozen_string_literal: true

# GoodJob's dashboard at /jobs is an engine whose controllers inherit from
# ActionController::Base, not from ApplicationController, so the web login wall
# is added to them here. GoodJob runs this hook when it loads its base controller.
ActiveSupport.on_load(:good_job_application_controller) do
  include WebSignInRequired
end
