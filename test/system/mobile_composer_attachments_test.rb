require "application_system_test_case"

# Attaching a photo from a phone.
#
# A touch device has no drag-and-drop, so on a phone the tappable attach control
# *is* the attachment mechanism — if it is not on screen, the feature is absent
# however much of it exists in JS. The follow-up composer's phone layout
# (`sm:hidden`) had no attach control at all: the buttons lived in the desktop row
# next to it, which is `display: none` below 640px. So every test here runs at a
# phone viewport, and the assertions are about what a thumb can reach.
#
# The second thing these pin is the media split. The picker deliberately accepts
# more than the image path can store — an iPhone still is HEIC and a phone video
# is .mov — and anything the image path would reject has to come out the file path
# instead of erroring. See app/javascript/lib/media_kinds.js.
class MobileComposerAttachmentsTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  # A real 1x1 PNG: the image upload endpoint sniffs magic bytes, so filler would
  # be rejected server-side and the preview would stay empty for a reason that has
  # nothing to do with the composer.
  ONE_PIXEL_PNG_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  setup do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 900)
    @fixture_paths&.each { |path| FileUtils.rm_f(path) }
  end

  test "the follow-up composer offers reachable attach controls at phone width" do
    session = create_session
    visit session_path(session)
    open_phone_composer

    # The desktop row is display:none here, so these have to be the phone row's
    # own buttons — `visible: true` is the whole assertion.
    assert_selector "button[aria-label='Attach photos or videos']", visible: true
    assert_selector "button[aria-label='Take a photo']", visible: true
    assert_selector "button[aria-label='Attach a file']", visible: true

    assert_no_horizontal_overflow("the session composer with its phone attach row open")
  end

  test "a photo attached from the phone composer rides along with the queued message" do
    # `running` so the submit queues rather than being handed to a CLI process
    # that does not exist in a system test. The delivery path is the same one the
    # composer's hidden `images` field feeds either way.
    session = create_session(status: :running)
    visit session_path(session)
    open_phone_composer

    attach_to_composer('input[data-image-attachment-target="input"]', png_fixture("beach.png"))

    # Both preview rows are written (the targets are plural); the phone one is the
    # only one on screen, which is what `visible: true` pins.
    assert_selector '[data-image-attachment-target="preview"]', text: "1 image", visible: true
    assert_equal 1, staged_images.length
    assert_match(/\.png\z/, staged_images.first["path"])

    find("#session_#{session.id}_follow_up_textarea_mobile").fill_in(with: "what is in this photo?")
    click_button "Queue Message"

    message = nil
    assert_nothing_raised do
      Timeout.timeout(Capybara.default_max_wait_time) do
        sleep 0.1 until (message = session.enqueued_messages.reload.first)
      end
    end

    assert_equal "what is in this photo?", message.content
    assert_equal 1, message.images.length
    assert_equal "image/png", message.images.first["media_type"]
    assert File.exist?(message.images.first["path"]),
      "the queued message names an image that is not on disk"
  ensure
    ImageStorageService.new(session_id: session.id).cleanup! if session
  end

  test "an iPhone HEIC picked from the photo input attaches as a file instead of erroring" do
    session = create_session
    visit session_path(session)
    open_phone_composer

    # HEIC is what an iPhone's camera actually writes, and ImageStorageService
    # cannot sniff or store it. Before the split this went up the image path and
    # came back "Could not detect image type - unsupported format".
    attach_to_composer('input[data-image-attachment-target="input"]', heic_fixture("IMG_4821.HEIC"))

    assert_selector '[data-file-attachment-target="preview"]', text: "IMG_4821.HEIC", visible: true
    assert_selector '[data-image-attachment-target="preview"]', visible: :hidden
    assert_equal 1, staged_files.length
  ensure
    FileStorageService.new(session_id: session.id).cleanup! if session
  end

  test "the dashboard quick prompt counts a HEIC as a file, not as an image" do
    visit root_path
    click_button "What do you want to do?"

    # The overlay's photo input is where a phone user taps "Photo Library". A HEIC
    # picked there must be moved onto files[] before the form posts, or the server
    # answers the whole submission with "Failed to upload attachment".
    attach_to_composer('input[data-quick-prompt-target="mobileImageInput"]', heic_fixture("IMG_4821.HEIC"))

    assert_selector '[data-quick-prompt-target="mobileBadge"]', text: "1 file attached"
    assert_equal 0, input_file_count('input[data-quick-prompt-target="mobileImageInput"]')
    assert_equal 1, input_file_count('input[data-quick-prompt-target="mobileFileInput"]')
  end

  test "the quick router keeps a JPEG on the image path and a .mov on the file path" do
    visit root_path
    # The joystick suppresses the page-global FAB on a session page; the dashboard
    # is where it is tappable.
    find("button[aria-label='Open quick router']").click

    attach_to_composer('input[data-chat-bubble-target="imageInput"]',
                       [ jpeg_fixture("snap.jpg"), mov_fixture("clip.mov") ])

    assert_selector '[data-chat-bubble-target="preview"]', text: "snap.jpg"
    assert_selector '[data-chat-bubble-target="preview"]', text: "clip.mov"

    # Both chips render into the same preview target, so their presence says
    # nothing about which path each took. The controller's own lists do.
    staged = page.evaluate_script(<<~JS)
      (() => {
        const controller = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector("#chat-bubble"), "chat-bubble"
        )
        return {
          images: controller.attachedImages.map(f => f.name),
          files: controller.attachedFiles.map(f => f.name)
        }
      })()
    JS
    # #write_fixture prefixes a unique id, so match the suffix.
    assert_equal 1, staged["images"].length
    assert staged["images"].first.end_with?("snap.jpg"), staged["images"].inspect
    assert_equal 1, staged["files"].length,
      "the quick router sent a .mov up the image path, which ImageStorageService rejects"
    assert staged["files"].first.end_with?("clip.mov"), staged["files"].inspect

    assert_no_horizontal_overflow("the quick router panel with a photo and a video attached")
  end

  test "one oversize photo does not discard the rest of a phone multi-select" do
    visit root_path
    click_button "What do you want to do?"

    # A phone multi-select is one tap over a grid. Before, a single entry over the
    # limit aborted the whole selection; now it is dropped on its own and named.
    over = ImageStorageService::MAX_IMAGE_SIZE + 1
    accept_alert(wait: 5) do
      attach_to_composer(
        'input[data-quick-prompt-target="mobileImageInput"]',
        [ png_fixture("keep-me.png"), png_fixture("panorama.png", bytes: "\0" * over) ]
      )
    end

    assert_selector '[data-quick-prompt-target="mobileBadge"]', text: "1 image attached"
    assert_equal 1, input_file_count('input[data-quick-prompt-target="mobileImageInput"]')
  end

  test "every prompt composer offers the phone's photo library and camera roll" do
    # One assertion per surface: an `accept` narrowed to the four storable types
    # is what greys out an iPhone's own photos in the picker, and it is invisible
    # until someone holds a phone.
    { root_path => "the dashboard quick prompt and quick router",
      new_session_path => "the new-session prompt",
      session_path(create_session) => "the follow-up composer" }.each do |path, label|
      visit path
      accepts = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("input[type=file]"))
             .map((i) => i.accept)
             .filter((a) => a && a.includes("image"))
      JS

      assert accepts.any?, "#{label} renders no image-capable file input at all"
      media = accepts.select { |a| a.include?("video/*") }
      assert media.any?,
        "#{label} offers no input that accepts video — a phone user cannot attach a clip there"
      assert media.all? { |a| a.include?("image/*") },
        "#{label} has a media input narrower than image/*, which hides HEIC stills in the picker"
    end
  end

  private

  def create_session(status: :needs_input)
    Session.create!(
      prompt: "Initial prompt",
      status: status,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
  end

  # On a phone the composer sits behind a collapsed drawer.
  def open_phone_composer
    wait_for_stimulus_controller("file-attachment")
    find("[data-bottom-drawer-target='trigger'] button").click
    assert_selector "[data-bottom-drawer-target='content']", visible: true
  end

  # Selenium can send a path to a file input the page has hidden, which is exactly
  # what the visible attach button does when it forwards a click to it.
  # `Array()` is deliberately not used: a fixture is a Hash, and Array(hash)
  # splays it into key/value pairs.
  def attach_to_composer(selector, fixtures)
    paths = (fixtures.is_a?(Array) ? fixtures : [ fixtures ]).map { |fixture| write_fixture(fixture) }
    find(selector, visible: :all).set(paths.length == 1 ? paths.first : paths)
  end

  def write_fixture(fixture)
    path = File.join(Dir.tmpdir, "#{SecureRandom.hex(4)}-#{fixture[:name]}")
    File.binwrite(path, fixture[:bytes])
    (@fixture_paths ||= []) << path
    path
  end

  def png_fixture(name, bytes: nil)
    { name: name, bytes: bytes || Base64.decode64(ONE_PIXEL_PNG_BASE64) }
  end

  # A JPEG only has to start with the SOI marker to be sniffed as one.
  def jpeg_fixture(name) = { name: name, bytes: [ 0xFF, 0xD8, 0xFF, 0xE0 ].pack("C*") + ("\x00" * 64) }

  # ISO-BMFF with an `ftypheic` brand — what an iPhone writes, and what the image
  # path has no magic-byte rule for.
  def heic_fixture(name)
    { name: name, bytes: [ 0, 0, 0, 0x18 ].pack("C*") + "ftypheic" + ("\x00" * 64) }
  end

  def mov_fixture(name)
    { name: name, bytes: [ 0, 0, 0, 0x14 ].pack("C*") + "ftypqt  " + ("\x00" * 64) }
  end

  # The hidden fields the composer submits — what is staged, as the server will
  # see it.
  def staged_images
    JSON.parse(find("input[name='images']", visible: :all).value.presence || "[]")
  end

  def staged_files
    JSON.parse(find("input[name='files_payload']", visible: :all).value.presence || "[]")
  end

  def input_file_count(selector)
    page.evaluate_script("document.querySelector(#{selector.to_json}).files.length")
  end
end
