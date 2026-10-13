import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZimmerKit

/// The composer's paperclip: the web composer's *Attach image* and *Attach file*, as the
/// system photo picker and file browser; its camera button, which on a phone opens the rear
/// camera (`capture="environment"`); and pasting an image, which the web composer takes from
/// the clipboard into the same attachments.
struct AttachMenu: View {
    /// What could be attached, and the names of what could not be read at all.
    let add: ([MessageAttachment], [String]) -> Void

    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var takingPhoto = false
    /// Whether *Paste Image* is offered. Asking the pasteboard whether it holds an image does
    /// not read it, so this shows no paste prompt; the prompt comes with the paste itself.
    @State private var canPasteImage = false

    var body: some View {
        HStack {
            Menu {
                // A device without a camera (the simulator, some iPads) is not offered one.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { takingPhoto = true } label: { Label("Take Photo", systemImage: "camera") }
                }
                Button { choosingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                Button { choosingFiles = true } label: { Label("Choose Files", systemImage: "folder") }
                if canPasteImage {
                    Button { paste() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                }
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Attach")
            .accessibilityIdentifier("composer.attach")
            .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: MessageAttachment.limit, matching: .images)
        }
        // On the container rather than the Menu, which already presents the photo picker.
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task {
                let (read, unreadable) = await Self.read(urls)
                add(read, unreadable)
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                let (loaded, failed) = await Self.load(items)
                add(loaded, failed)
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in
                takingPhoto = false
                guard let data else { return }
                let stamp = Int(Date().timeIntervalSince1970)
                Task {
                    let (taken, failed) = await Self.images([data], named: { _ in "Photo \(stamp).jpg" })
                    add(taken, failed)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { canPasteImage = UIPasteboard.general.hasImages }
        // Copied here, or in another app while this one was in the background.
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            canPasteImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            canPasteImage = UIPasteboard.general.hasImages
        }
    }

    /// The images on the pasteboard, through the photo pipeline: as JPEG, scaled to fit.
    private func paste() {
        let pasted = (UIPasteboard.general.images ?? []).compactMap { $0.jpegData(compressionQuality: 0.9) }
        let stamp = Int(Date().timeIntervalSince1970)
        guard !pasted.isEmpty else {
            add([], ["The pasted image"])
            return
        }
        Task {
            let (read, failed) = await Self.images(pasted, named: { "Pasted image \(stamp)-\($0 + 1).jpg" })
            add(read, failed)
        }
    }

    /// Image bytes from the camera or the pasteboard as attachments, re-encoded and scaled off
    /// the main thread as a library photo is.
    nonisolated static func images(_ data: [Data], named name: @Sendable (Int) -> String) async -> ([MessageAttachment], [String]) {
        var images: [MessageAttachment] = []
        var failed: [String] = []
        for (index, bytes) in data.enumerated() {
            guard let jpeg = jpeg(from: bytes) else {
                failed.append(name(index))
                continue
            }
            images.append(MessageAttachment(filename: name(index), mediaType: "image/jpeg", data: jpeg))
        }
        return (images, failed)
    }

    /// Photos as JPEG, decoded and downsampled off the main thread: the library hands back
    /// HEIC, which the server does not keep as an image, and a photo is scaled down until its
    /// JPEG fits the image limit.
    nonisolated static func load(_ items: [PhotosPickerItem]) async -> ([MessageAttachment], [String]) {
        var loaded: [MessageAttachment] = []
        var failed: [String] = []
        let stamp = Int(Date().timeIntervalSince1970)
        for (index, item) in items.enumerated() {
            let name = "Photo \(stamp)-\(index + 1).jpg"
            guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = jpeg(from: data) else {
                failed.append(name)
                continue
            }
            loaded.append(MessageAttachment(filename: name, mediaType: "image/jpeg", data: jpeg))
        }
        return (loaded, failed)
    }

    /// A JPEG under the image limit: the full image if it fits, else ImageIO thumbnails of a
    /// shrinking longest side, which never decode the full-size bitmap.
    nonisolated static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for maxPixels in [0, 4096, 3072, 2048, 1024] {
            let options: [CFString: Any] = maxPixels == 0
                ? [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
                : [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            if out.length <= MessageAttachment.maxImageBytes { return out as Data }
        }
        return nil
    }

    /// Files from the Files app, read off the main thread. One larger than a whole message
    /// may carry is refused by its size before it is read. Its media type comes from its
    /// extension; the server decides image or file by the bytes.
    nonisolated static func read(_ urls: [URL]) async -> ([MessageAttachment], [String]) {
        var read: [MessageAttachment] = []
        var unreadable: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > MessageAttachment.maxTotalBytes {
                unreadable.append("\(url.lastPathComponent) (over 75 MB)")
                continue
            }
            var data: Data?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                data = try? Data(contentsOf: readable)
            }
            guard let data else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            read.append(MessageAttachment(filename: url.lastPathComponent, mediaType: type, data: data))
        }
        return (read, unreadable)
    }
}

/// The rear camera, for one photo: the web composer's camera button. `finish` gets the
/// photo's bytes, or nil when the person cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let finish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (Data?) -> Void

        init(finish: @escaping (Data?) -> Void) {
            self.finish = finish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            finish(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finish(nil)
        }
    }
}

/// What is going with the next message, each one removable.
struct AttachmentChips: View {
    @Binding var attachments: [MessageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                        Text(attachment.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(Theme.inkSoft)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkMute)
                        }
                        .accessibilityLabel("Remove \(attachment.filename)")
                        .accessibilityIdentifier("composer.attachment.remove.\(attachment.filename)")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.attachment.\(attachment.filename)")
                }
            }
        }
    }
}
