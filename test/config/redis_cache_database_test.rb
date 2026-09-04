# frozen_string_literal: true

require "test_helper"
require "redis_client"

# Throughout Zimmer, `REDIS_URL` names the Redis *server* and each environment config
# picks its own logical database: the cache takes one of its own so it cannot collide
# with anything else pointed at a bare URL — `DeepHealthCheck`'s ping, or another app
# sharing the server, both of which land on 0.
#
# The two halves of that convention are individually reasonable and jointly invalid
# the moment either forgets the other. An environment file that helpfully appends
# `/0` plus an environment config that appends `/1` produces `redis://…:6379/0/1`,
# whose whole path redis-client reads as the database number:
#
#   ArgumentError (invalid value for Integer(): "0/1")
#
# It does not raise at boot — the store is built lazily — so the stack comes up
# healthy and then every single `Rails.cache` call fails. In the containerized dev
# stack that meant `GET /clis/badge` 500ing, and because the badge is a lazy
# `<turbo-frame>` on the dashboard, Turbo escalated it into a full page visit and the
# dashboard rendered as "Action Controller: Exception caught"
# ([#822](https://github.com/tadasant/zimmer/issues/822)). The same trap had already
# been sprung once in production ([#20](https://github.com/tadasant/zimmer/issues/20)).
#
# This guards both halves: no committed `REDIS_URL` names a database, and development
# selects its cache database explicitly rather than by string concatenation, so a URL
# that names one anyway is overridden instead of corrupted.
class RedisCacheDatabaseTest < ActiveSupport::TestCase
  # Files that must assign REDIS_URL. Every deploy config is swept separately below,
  # because a file is free to inherit the value rather than set one of its own.
  REDIS_URL_FILES = %w[
    .agent-containers/.env.dev
    .env.example
    config/deploy.yml
    config/deploy.production.yml
  ].freeze

  DEVELOPMENT_ENV = Rails.root.join("config/environments/development.rb")

  # `REDIS_URL=redis://host:6379` / `REDIS_URL: "redis://host:6379"`, commented or not.
  ASSIGNMENT = /^\s*#?\s*REDIS_URL\s*[:=]\s*(\S+)/

  def assigned_urls(path)
    Rails.root.join(path).read.scan(ASSIGNMENT).flatten.map { |url| url.gsub(/\A["']|["']\z/, "") }
  end

  # The database a URL names, or nil for none. GitHub Actions expressions stand in for
  # the port they interpolate so `ci.yml`'s value parses like any other.
  def database_index(url)
    path = URI.parse(url.gsub(/\$\{\{[^}]*\}\}/, "0")).path
    path.presence&.delete_prefix("/").presence
  end

  def development_source
    @development_source ||= DEVELOPMENT_ENV.read
  end

  # The `db:` development.rb hands the cache store, read out of the file itself so the
  # behavioural assertions below cannot drift away from the real config.
  def development_cache_db
    development_source[/config\.cache_store = :redis_cache_store,.*?\bdb:\s*(\d+)/m, 1]&.to_i
  end

  def assert_names_no_database(url, source)
    assert_nil database_index(url),
      "#{source} sets REDIS_URL=#{url}, which names a database. REDIS_URL names the " \
      "server only; the environment config picks the database."
  end

  test "no committed REDIS_URL names a database" do
    REDIS_URL_FILES.each do |path|
      urls = assigned_urls(path)
      assert_predicate urls, :any?, "#{path} was expected to assign REDIS_URL — has it moved?"

      urls.each { |url| assert_names_no_database(url, path) }
    end
  end

  # deploy.staging.yml carries no REDIS_URL of its own today — it inherits deploy.yml's.
  # Should it (or a future deploy config) grow one, staging.rb concatenates `/0` exactly
  # like production, so the index would have to be absent there too.
  test "no deploy config names a database" do
    Dir[Rails.root.join("config/deploy*.yml")].each do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      assigned_urls(relative).each { |url| assert_names_no_database(url, relative) }
    end
  end

  test "CI exports a REDIS_URL without a database" do
    workflow = Rails.root.join(".github/workflows/ci.yml").read
    exports = workflow.scan(/REDIS_URL=([^"]+)"/).flatten

    assert_predicate exports, :any?, "ci.yml was expected to export REDIS_URL — has it moved?"
    exports.each { |url| assert_names_no_database(url, "ci.yml") }
  end

  test "development selects the cache database explicitly rather than appending to the URL" do
    refute_includes development_source, '#{ENV["REDIS_URL"]}',
      "development.rb interpolates REDIS_URL into a string. Appending a path segment to " \
      "a URL that may already name a database yields an unparseable db (#822) — pass " \
      "`db:` to the cache store instead."

    assert_not_nil development_cache_db,
      "development.rb should hand :redis_cache_store an explicit `db:`"
  end

  test "the development cache database is not the one a bare REDIS_URL resolves to" do
    bare = RedisClient.config(url: "redis://redis.invalid:6379").db

    assert_equal 0, bare, "a bare REDIS_URL was expected to resolve to database 0"
    assert_not_equal bare, development_cache_db,
      "the development cache must stay off the database a bare REDIS_URL resolves to"
  end

  test "the development cache database survives a REDIS_URL that names one" do
    db = development_cache_db

    # The shape development.rb uses: an explicit `db:` overrides the URL's own path...
    %w[
      redis://redis.invalid:6379
      redis://redis.invalid:6379/0
      redis://default:secret@redis.invalid:6379/3
    ].each do |url|
      assert_equal db, RedisClient.config(url: url, db: db).db,
        "REDIS_URL=#{url} should still put the cache on database #{db}"
    end

    # ...whereas concatenating onto a URL that names a database yields an unparseable one.
    error = assert_raises(ArgumentError) do
      RedisClient.config(url: "redis://redis.invalid:6379/0/#{db}").db
    end
    assert_match(/invalid value for Integer\(\): "0\/#{db}"/, error.message)
  end
end
