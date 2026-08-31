# frozen_string_literal: true

module Supervisor
  class PostDeployTaskRunsController < Supervisor::ApplicationController
    # One row per one-time post-deploy task (`db/post_deploy/`). Browsing them
    # answers "did this step ever run against this environment, when, and did it
    # fail" at row level, without a shell on the box — the same question the
    # health page's panel answers in aggregate.
    private

    def default_sorting_attribute = :version

    def default_sorting_direction = :desc
  end
end
