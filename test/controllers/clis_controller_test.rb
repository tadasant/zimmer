# frozen_string_literal: true

require "test_helper"

class ClisControllerTest < ActionDispatch::IntegrationTest
  test "clear_cache enqueues CacheClearJob and redirects" do
    assert_enqueued_with(job: CacheClearJob, args: [ { reinstall: true } ]) do
      post clear_cache_clis_path
    end

    assert_redirected_to clis_path
    assert_match(/Cache clear queued/, flash[:notice])
    assert_match(/worker container/, flash[:notice])
  end

  test "clear_cache returns JSON when requested" do
    assert_enqueued_with(job: CacheClearJob, args: [ { reinstall: true } ]) do
      post clear_cache_clis_path, as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["queued"]
    assert_match(/Cache clear queued/, json["message"])
  end
end
