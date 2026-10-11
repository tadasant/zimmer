import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ZimmerKit

/// The composer's paperclip: the web composer's *Attach image* and *Attach file*, as the
/// system photo picker and file browser.
struct AttachMenu: View {
    let add: ([MessageAttachment]) -> Void

    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false

    var body: some View {
        Menu {
            Button { choosingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { choosingFiles = true } label: { Label("Choose Files", systemImage: "folder") }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("composer.attach")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: MessageAttachment.limit, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { add(await Self.load(items)) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            add(urls.compactMap(Self.read))
        }
    }

    /// Photos as JPEG: the library hands back HEIC, which the server does not keep as an
    /// image. A photo still over the image limit is scaled down until it fits.
    static func load(_ items: [PhotosPickerItem]) async -> [MessageAttachment] {
        var loaded: [MessageAttachment] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let jpeg = jpeg(image) else { continue }
            loaded.append(MessageAttachment(filename: "Photo \(index + 1).jpg", mediaType: "image/jpeg", data: jpeg))
        }
        return loaded
    }

    static func jpeg(_ image: UIImage) -> Data? {
        var candidate = image
        for _ in 0..<4 {
            guard let data = candidate.jpegData(compressionQuality: 0.8) else { return nil }
            if data.count <= MessageAttachment.maxImageBytes { return data }
            let size = CGSize(width: candidate.size.width / 2, height: candidate.size.height / 2)
            candidate = UIGraphicsImageRenderer(size: size).image { _ in candidate.draw(in: CGRect(origin: .zero, size: size)) }
        }
        return nil
    }

    /// A file from the Files app. Its media type comes from its extension; an image file in a
    /// type the server keeps as an image goes as an image, anything else as a file.
    static func read(_ url: URL) -> MessageAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return MessageAttachment(filename: url.lastPathComponent, mediaType: type, data: data)
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
                            .foregroundStyle(.secondary)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .accessibilityIdentifier("composer.attachment.\(attachment.filename)")
                }
            }
        }
    }
}
