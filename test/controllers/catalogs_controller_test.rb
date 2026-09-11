# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class CatalogsControllerTest < ActionDispatch::IntegrationTest
  def ok_result
    CatalogRefreshJob::WaitResult.new(status: :ok, error_message: nil)
  end

  test "refresh runs the worker's refresh, not one in the web process, then serves the new snapshot" do
    # The web process never fetches or resolves on the button's behalf...
    AirCatalogService.expects(:refresh!).never
    # ...the worker does, via the job the cron runs...
    CatalogRefreshJob.expects(:perform_and_wait).once.returns(ok_result)
    # ...and the web picks up the snapshot that job stored.
    AirCatalogService.expects(:sync_from_snapshot!).once.returns(true)
    AirCatalogService.stubs(:last_refreshed_at).returns(Time.current)

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/Catalogs refreshed successfully/, flash[:notice])
  end

  test "refresh syncs the snapshot even when the worker refresh fails, so the banner shows it" do
    CatalogRefreshJob.expects(:perform_and_wait).once
      .returns(CatalogRefreshJob::WaitResult.new(status: :failed, error_message: "AirCatalogService::CatalogError: boom"))
    AirCatalogService.expects(:sync_from_snapshot!).once.returns(true)

    post refresh_catalogs_path

    assert_match(/Catalog refresh failed: boom/, flash[:alert])
  end

  # Through the real snapshot table: this process serves one snapshot, the
  # worker (simulated by a direct store!) writes a newer one, and the page the
  # button redirects to is served from it — with no `air` subprocess in this
  # process. The suite disables the TTL, so without the controller's sync the
  # process would still be serving "before".
  test "refresh leaves this process serving the snapshot the worker stored" do
    CatalogSnapshot.delete_all
    AirCatalogService.reset!
    CatalogSnapshot.store!({ skills: { "before" => {} } })
    assert_equal [ "before" ], AirCatalogService.entries_for(:skills).keys

    CatalogSnapshot.store!({ skills: { "after" => {} } }, fetched_at: Time.utc(2026, 9, 11, 12))
    CatalogRefreshJob.stubs(:perform_and_wait).returns(ok_result)
    Open3.expects(:capture3).never

    post refresh_catalogs_path

    assert_equal [ "after" ], AirCatalogService.entries_for(:skills).keys
    assert_equal Time.utc(2026, 9, 11, 12), AirCatalogService.last_refreshed_at
    assert_match(/Catalogs refreshed successfully \(Sep 11, 2026 12:00:00 UTC\)/, flash[:notice])
  ensure
    AirCatalogService.reset!
  end

  # #319: this flash is `air update`'s own text from a process holding
  # AIR_GITHUB_TOKEN, and redirect_back puts it on /sessions/new — the same
  # unauthenticated page as the catalog-failure banner.
  test "refresh scrubs a credential out of a worker-side failure flash" do
    token = "ghp_#{"w" * 36}"
    SecretsLoader.stubs(:all).returns({ "AIR_GITHUB_TOKEN" => token })
    AirCatalogService.stubs(:sync_from_snapshot!).returns(true)
    CatalogRefreshJob.expects(:perform_and_wait).once
      .returns(CatalogRefreshJob::WaitResult.new(
        status: :failed, error_message: "AirCatalogService::CatalogError: worker boom with #{token}"
      ))

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    refute_includes flash[:alert], token
    assert_match(/Catalog refresh failed: worker boom with \[REDACTED:AIR_GITHUB_TOKEN\]/, flash[:alert])
  end

  test "refresh redirects with alert when the worker refresh fails, stripping the exception class prefix" do
    AirCatalogService.stubs(:sync_from_snapshot!).returns(true)
    # GoodJob records the error as "ExceptionClass: message"; the flash should
    # show only the bare message.
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
    AirCatalogService.stubs(:sync_from_snapshot!).returns(true)
    CatalogRefreshJob.expects(:perform_and_wait).once
      .returns(CatalogRefreshJob::WaitResult.new(status: :timeout, error_message: nil))

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/still running in the background/, flash[:alert])
  end

  test "refresh shows 'just now' when last_refreshed_at is nil" do
    AirCatalogService.stubs(:sync_from_snapshot!).returns(true)
    CatalogRefreshJob.stubs(:perform_and_wait).returns(ok_result)
    AirCatalogService.stubs(:last_refreshed_at).returns(nil)

    post refresh_catalogs_path

    assert_redirected_to new_session_path
    assert_match(/just now/, flash[:notice])
  end

  test "refresh redirects back to referrer when available" do
    AirCatalogService.stubs(:sync_from_snapshot!).returns(true)
    CatalogRefreshJob.stubs(:perform_and_wait).returns(ok_result)
    AirCatalogService.stubs(:last_refreshed_at).returns(Time.current)

    post refresh_catalogs_path, headers: { "HTTP_REFERER" => new_session_url }

    assert_redirected_to new_session_url
  end
end
