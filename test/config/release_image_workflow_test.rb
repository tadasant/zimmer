# frozen_string_literal: true

require "test_helper"

class ReleaseImageWorkflowTest < ActiveSupport::TestCase
  RELEASE_WORKFLOW = Rails.root.join(".github/workflows/release-image.yml")

  test "release workflow pins the app to a content-addressed base image" do
    workflow = RELEASE_WORKFLOW.read

    assert_includes workflow,
      "git ls-tree HEAD -- Dockerfile.base Gemfile Gemfile.lock mcp.json bin/preinstall-mcp-packages"
    assert_includes workflow, "zimmer-base:content-${BASE_KEY}"
    assert_includes workflow, 'imagetools inspect "$BASE_IMAGE"'
    assert_not_includes workflow, "git diff --name-only",
      "a per-push diff forgets a failed base build as soon as another commit lands"
    assert_match(/if:\s*steps\.base\.outputs\.need_base == 'true'/, workflow)
    assert_match(/tags:\s*\|\s*\n\s*\$\{\{ steps\.base\.outputs\.image \}\}/, workflow)

    attempts = workflow.scan(/name: Build and push(?: \([^\n]+\))?.*?(?=\n\s+- name:|\z)/m)
    assert_equal 3, attempts.size
    attempts.each do |attempt|
      assert_includes attempt, "BASE_IMAGE=${{ steps.base.outputs.image }}",
        "every retry must use the same exact base as the first app build"
    end
  end
end
