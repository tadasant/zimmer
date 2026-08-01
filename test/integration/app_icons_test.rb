require "test_helper"

# The PWA manifest and the layout's <link rel="icon"> tags name files by path.
# Nothing at boot checks those paths resolve, so a rename that misses one of them
# fails silently — the tab falls back to a blank page glyph and an install shows
# the platform's default icon. These tests walk every declared path.
class AppIconsTest < ActionDispatch::IntegrationTest
  MANIFEST = JSON.parse(Rails.public_path.join("manifest.json").read)

  test "every icon the manifest declares is served" do
    MANIFEST["icons"].each do |icon|
      get icon["src"]

      assert_response :success, "#{icon['src']} is declared in manifest.json but is not served"
      assert_equal "\x89PNG".b, response.body.byteslice(0, 4).b, "#{icon['src']} should be a PNG"
    end
  end

  test "manifest icons declare the size they actually are" do
    MANIFEST["icons"].each do |icon|
      expected = icon["sizes"].split("x").map(&:to_i)

      assert_equal expected, png_dimensions(public_file(icon["src"])),
                   "#{icon['src']} does not match its declared #{icon['sizes']}"
    end
  end

  test "manifest splits any and maskable rather than declaring one icon both" do
    # `purpose` is optional and defaults to "any", so read it the way a browser does.
    purposes = MANIFEST["icons"].map { |icon| icon["purpose"] || "any" }

    assert_includes purposes, "any"
    assert_includes purposes, "maskable"
    # A full-bleed render declared maskable gets its edges cropped away by
    # Android's circle/squircle mask; the maskable files are padded for it.
    assert_empty purposes.select { |purpose| purpose.split.size > 1 },
                 "an icon cannot be both full-bleed and padded for the maskable safe zone"
  end

  # Read the layout rather than rendering it: rendering pulls in the Tailwind
  # build, which is git-ignored and only compiled for the system suite.
  test "every icon the layout links is served" do
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    hrefs = layout.scan(/<link[^>]+rel="(?:icon|apple-touch-icon)"[^>]+href="([^"]+)"/).flatten

    assert_operator hrefs.size, :>=, 3, "layout should link a favicon set"
    hrefs.each do |href|
      get href

      assert_response :success, "#{href} is linked from the layout but is not served"
    end
  end

  # The docs site is built by Astro, which does not validate references into its
  # own public/ directory — a renamed favicon there builds clean and ships a
  # broken tab icon. Nothing else in CI would catch it, so check it from here.
  DOCS = Rails.root.join("docs")

  test "every icon the docs site references exists in docs/public" do
    sources = [ DOCS.join("astro.config.mjs"), DOCS.join("src/components/Head.astro") ]
    referenced = sources.flat_map { |file| file.read.scan(%r{["']/(favicon[\w.-]*|apple-touch-icon\.png)["']}) }.flatten.uniq

    assert_operator referenced.size, :>=, 4, "expected the docs favicon set to be referenced"
    referenced.each do |name|
      assert_path_exists DOCS.join("public", name),
                         "docs/#{name} is referenced by the docs site but missing from docs/public"
    end
  end

  test "favicon.ico carries the 16, 32 and 48 pixel renders" do
    ico = Rails.public_path.join("favicon.ico").binread

    assert_equal "\x00\x00\x01\x00".b, ico.byteslice(0, 4).b, "should be an ICO container"
    count = ico.byteslice(4, 2).unpack1("v")
    sizes = count.times.map { |i| ico.getbyte(6 + (i * 16)) }

    assert_equal [ 16, 32, 48 ], sizes.sort
  end

  private

  # Icon srcs carry a ?v= cache buster; the file on disk does not.
  def public_file(src)
    Rails.public_path.join(src.split("?").first.delete_prefix("/"))
  end

  # PNG puts an IHDR chunk with width and height at a fixed offset.
  def png_dimensions(path)
    path.binread(24).byteslice(16, 8).unpack("N2")
  end
end
