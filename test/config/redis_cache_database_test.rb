# frozen_string_literal: true

require "test_helper"
require "redis_client"

# Throughout Zimmer, `REDIS_URL` names the Redis *server* and each environment picks
# its own logical database: the cache gets its own so it cannot collide with Action
# Cable and GoodJob, which take whatever a bare URL resolves to (0).
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
  # Every committed file that assigns REDIS_URL a literal value. CI builds its own
  # from a dynamic service port and is checked separately below.
  REDIS_URL_FILES = %w[
    .agent-containers/.env.dev
    .env.example
    config/deploy.yml
    config/deploy.production.yml
  ].freeze

  DEVELOPMENT_ENV = Rails.root.join("config/environments/development.rb")

  # `REDIS_URL=redis://host:6379` / `REDIS_URL: redis://host:6379`, commented or not.
  ASSIGNMENT = /^\s*#?\s*REDIS_URL\s*[:=]\s*(\S+)/

  def assigned_urls(path)
    Rails.root.join(path).read.scan(ASSIGNMENT).flatten
  end

  def development_source
    @development_source ||= DEVELOPMENT_ENV.read
  end

  # The `db:` development.rb hands the cache store, read out of the file itself so
  # the behavioural assertions below cannot drift away from the real config.
  def development_cache_db
    development_source[/config\.cache_store = :redis_cache_store, \{[^}]*\bdb:\s*(\d+)/, 1]&.to_i
  end

  test "no committed REDIS_URL names a database" do
    REDIS_URL_FILES.each do |path|
      urls = assigned_urls(path)
      assert_predicate urls, :any?, "#{path} was expected to assign REDIS_URL — has it moved?"

      urls.each do |url|
        path_segment = URI.parse(url).path
        assert path_segment.blank? || path_segment == "/",
          "#{path} sets REDIS_URL=#{url}, which names database #{path_segment.delete_prefix("/")}. " \
          "REDIS_URL names the server only; the environment config picks the database."
      end
    end
  end

  test "CI exports a REDIS_URL without a database" do
    workflow = Rails.root.join(".github/workflows/ci.yml").read
    exports = workflow.scan(/REDIS_URL=([^"]+)"/).flatten

    assert_predicate exports, :any?, "ci.yml was expected to export REDIS_URL — has it moved?"
    exports.each do |url|
      refute_match %r{\}\}/\d+\z}, url,
        "ci.yml exports REDIS_URL=#{url} with a database index appended"
    end
  end

  test "development selects the cache database explicitly rather than appending to the URL" do
    refute_match(/cache_store = :redis_cache_store.*#\{ENV\["REDIS_URL"\]\}/, development_source,
      "development.rb interpolates REDIS_URL into the cache-store URL. Appending a path " \
      "segment to a URL that may already name a database yields an unparseable db (#822) — " \
      "pass `db:` instead.")

    assert_not_nil development_cache_db,
      "development.rb should hand :redis_cache_store an explicit `db:`"
  end

  test "the development cache database is not the one Action Cable and GoodJob get" do
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

    # ...where the concatenation it replaced is what raised on every Rails.cache call.
    error = assert_raises(ArgumentError) do
      RedisClient.config(url: "redis://redis.invalid:6379/0/#{db}").db
    end
    assert_match(/invalid value for Integer\(\): "0\/#{db}"/, error.message)
  end
end
