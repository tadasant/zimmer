# frozen_string_literal: true

require "test_helper"

class DigestedAssetCacheHeadersTest < ActiveSupport::TestCase
  ONE_HOUR = "public, max-age=3600"

  def call(path, status: 200)
    app = ->(_env) { [ status, Rack::Headers.new.merge("cache-control" => ONE_HOUR), [ "" ] ] }
    _, headers, = DigestedAssetCacheHeaders.new(app).call(Rack::MockRequest.env_for(path))
    headers["cache-control"]
  end

  test "digest-stamped assets are cached for a year, immutable" do
    [
      "/assets/tailwind-153f0432.css",
      "/assets/application-580766e9.css",
      "/assets/controllers/session_drawer_controller-1b22bc5a.js",
      "/assets/turbo.min-86bf8853.js",
      "/assets/turbo.min-8421946c.js.map"
    ].each do |path|
      assert_equal DigestedAssetCacheHeaders::IMMUTABLE, call(path), path
    end
  end

  test "a revalidation answer carries the same header" do
    assert_equal DigestedAssetCacheHeaders::IMMUTABLE, call("/assets/tailwind-153f0432.css", status: 304)
  end

  test "anything a deploy can change in place keeps Static's hour" do
    [
      "/manifest.json",
      "/icons/apple-touch-icon.png",
      "/favicon.ico",
      "/service-worker.js",
      "/assets/tailwind.css",
      "/assets/notes-2024.txt",
      "/sessions/123-abcdef12.css"
    ].each do |path|
      assert_equal ONE_HOUR, call(path), path
    end
  end

  test "a missing asset is not marked immutable" do
    assert_equal ONE_HOUR, call("/assets/tailwind-153f0432.css", status: 404)
  end

  test "it wraps the static file server" do
    stack = Rails.application.middleware.map(&:klass)
    assert_operator stack.index(DigestedAssetCacheHeaders), :<, stack.index(ActionDispatch::Static)
  end
end
