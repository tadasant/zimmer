// One rule, shared by every composer, for what happens to a file a human picked
// out of a phone's media library.
//
// Two upload paths exist and they are not interchangeable:
//
// - The IMAGE path (ImageStorageService) sniffs magic bytes, accepts only JPEG,
//   PNG, GIF and WebP, and hands the bytes to the model inline. Anything else it
//   is given raises "Could not detect image type".
// - The FILE path (FileStorageService) stores arbitrary bytes verbatim and hands
//   the agent a path on disk.
//
// A phone produces media the image path cannot take: iPhone photos arrive as
// HEIC/HEIF, iPhone video as QuickTime, Android video as MP4. Sending those up
// the image path is a guaranteed error, so the media picker accepts them and
// then splits the selection — model-readable stills go up as images, everything
// else goes up as a file. The agent still gets the media either way; only the
// inline-vs-path distinction changes.

// The four types ImageStorageService::SUPPORTED_TYPES can sniff and store.
export const MODEL_READABLE_IMAGE_TYPES = [
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp"
]

// Extensions for the same four, used when the browser reports no usable MIME type
// — which Android pickers do for files handed over by some gallery apps and share
// targets.
const MODEL_READABLE_EXTENSIONS = [ "jpg", "jpeg", "png", "gif", "webp" ]

// Types that carry no information about the bytes, so the extension decides.
const UNINFORMATIVE_TYPES = [ "", "application/octet-stream" ]

// What a "Photos & videos" input offers. `image/*,video/*` is what makes iOS
// Safari put "Photo Library" and "Take Photo or Video" on the sheet and what
// makes Android Chrome open the media picker rather than the document browser;
// the explicit extensions are for pickers that match on extension and would
// otherwise grey out an iPhone still.
export const MEDIA_ACCEPT = "image/*,video/*,.heic,.heif,.mov"

// True when this file can go up the image path and be read by the model.
export function isModelReadableImage(file) {
  if (!file) return false

  const type = (file.type || "").toLowerCase()
  if (!UNINFORMATIVE_TYPES.includes(type)) return MODEL_READABLE_IMAGE_TYPES.includes(type)

  // Nothing to go on but the name. A dropped *directory* looks exactly like this —
  // no type and no bytes — and one named `shots.png` would otherwise be claimed by
  // the image path while file-attachment is walking it as a folder, uploading it
  // twice. Requiring bytes is what separates the two.
  if (!file.size) return false

  const extension = (file.name || "").split(".").pop().toLowerCase()
  return MODEL_READABLE_EXTENSIONS.includes(extension)
}

// Split a picked selection into the two upload paths.
// Returns { images, files } — `files` is everything the image path would reject.
export function partitionMedia(fileList) {
  const picked = Array.from(fileList || [])
  return {
    images: picked.filter(isModelReadableImage),
    files: picked.filter((file) => !isModelReadableImage(file))
  }
}
