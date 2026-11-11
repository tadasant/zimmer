# Far-future, immutable caching for Propshaft's digest-stamped build output.
#
# In a deployed environment the precompiled assets are files under public/assets,
# so ActionDispatch::Static serves them — with config.public_file_server.headers,
# the one-hour max-age that public/'s un-stamped files (the manifest, the icons)
# need. That header is wrong for a file whose name changes whenever its content
# does: an hour after the last visit, every asset on the page is stale, and the
# browser revalidates all of them — two stylesheets that block first paint, and
# the ~100 importmap modules Turbo and Stimulus have to load before a lazy frame
# can even start fetching — before it shows anything.
#
# This rewrites Cache-Control on a digest-stamped /assets response to a year,
# immutable, so a returning browser makes no asset requests at all. A deploy that
# changes an asset changes its URL, and the layout's data-turbo-track="reload"
# picks up the new URLs, so nothing is pinned stale.
#
# A path that is not digest-stamped (anything a deploy can change in place) keeps
# the header Static gave it.
class DigestedAssetCacheHeaders
  IMMUTABLE = "public, max-age=#{365 * 24 * 60 * 60}, immutable".freeze

  # Propshaft's stamp: "-" then 8 lowercase hex characters before the extension,
  # e.g. /assets/tailwind-153f0432.css,
  # /assets/controllers/foo_controller-1b22bc5a.js, /assets/turbo.min-8421946c.js.map.
  DIGESTED_PATH = %r{\A/assets/.+-[0-9a-f]{8,}\.[a-z0-9.]+\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)

    if (status == 200 || status == 304) && DIGESTED_PATH.match?(env["PATH_INFO"].to_s)
      headers["cache-control"] = IMMUTABLE
    end

    [ status, headers, body ]
  end
end
