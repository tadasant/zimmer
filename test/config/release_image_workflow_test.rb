# frozen_string_literal: true

require "test_helper"

class ReleaseImageWorkflowTest < ActiveSupport::TestCase
  RELEASE_WORKFLOW = Rails.root.join(".github/workflows/release-image.yml")

  test "release workflow rebuilds the base image when Dockerfile.base changes" do
    workflow = RELEASE_WORKFLOW.read

    assert_includes workflow, "git diff --name-only"
    assert_includes workflow, "-- Dockerfile.base"
    assert_includes workflow, "Dockerfile.base changed; rebuilding base image before app image."
    assert_match(/if:\s*steps\.base\.outputs\.need_base == 'true'/, workflow)
    assert_match(/name: Build and push.*?pull: true/m, workflow)
  end
end
