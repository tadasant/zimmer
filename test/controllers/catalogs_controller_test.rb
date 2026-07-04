# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CatalogsControllerTest < ActionDispatch::IntegrationTest
  def ok_result
    CatalogRefreshJob::WaitResult.new(status: :ok, error_message: nil)
  end

  test "refresh refreshes the web process AND the worker, then redirects with notice" do
    # Web-process refresh (drives the catalog pickers on this page).
    AirCatalogService.expects(:refresh!).once.returns(true)
    # Worker-process refresh (drives session preparation) via the shared job.
    CatalogRefreshJob.expects(:perform_and_wait).once.returns(ok_result)
    AirCatalogService.stubs(:last_refreshed_at).returns(Time.current)

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/Catalogs refreshed successfully/, flash[:notice])
  end

  test "refresh redirects with alert when the web-process refresh fails" do
    AirCatalogService.expects(:refresh!).once
      .raises(AirCatalogService::CatalogError, "git fetch failed")
    # Worker refresh still runs; web failure takes precedence in the message.
    CatalogRefreshJob.stubs(:perform_and_wait).returns(ok_result)

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/Catalog refresh failed/, flash[:alert])
    assert_match(/git fetch failed/, flash[:alert])
  end

  test "refresh redirects with alert when the worker refresh fails, stripping the exception class prefix" do
    AirCatalogService.expects(:refresh!).once.returns(true)
    # GoodJob records the error as "ExceptionClass: message"; the flash should
    # show only the bare message, matching the web-process failure path.
    CatalogRefreshJob.expects(:perform_and_wait).once
      .returns(CatalogRefreshJob::WaitResult.new(
        status: :failed, error_message: "AirCatalogService::CatalogError: worker boom"
      ))

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/Catalog refresh failed: worker boom/, flash[:alert])
    refute_match(/CatalogError/, flash[:alert])
  end

  test "refresh redirects with alert when the worker refresh times out" do
    AirCatalogService.expects(:refresh!).once.returns(true)
    CatalogRefreshJob.expects(:perform_and_wait).once
      .returns(CatalogRefreshJob::WaitResult.new(status: :timeout, error_message: nil))

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/still running in the background/, flash[:alert])
  end

  test "refresh shows 'just now' when last_refreshed_at is nil" do
    AirCatalogService.expects(:refresh!).once.returns(true)
    CatalogRefreshJob.stubs(:perform_and_wait).returns(ok_result)
    AirCatalogService.stubs(:last_refreshed_at).returns(nil)

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/just now/, flash[:notice])
  end

  test "refresh redirects back to referrer when available" do
    AirCatalogService.expects(:refresh!).once.returns(true)
    CatalogRefreshJob.stubs(:perform_and_wait).returns(ok_result)
    AirCatalogService.stubs(:last_refreshed_at).returns(Time.current)

    post refresh_catalogs_path, headers: { "HTTP_REFERER" => new_session_url }

    assert_redirected_to new_session_url
  end
end
