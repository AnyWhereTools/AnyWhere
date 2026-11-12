import SwiftUI
import AnyWhereCore

struct PluginIconView: View {
    let icon: String
    var directory: URL? = nil
    var remoteURL: URL? = nil
    var size: CGFloat = 30
    @State private var image: NSImage?

    private var requestID: String {
        let modified = directory.flatMap { root in
            try? root.appendingPathComponent(icon).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return icon + (directory?.path ?? remoteURL?.absoluteString ?? "") + String(describing: modified)
    }

    var body: some View {
        Group {
            if PackIcon.imagePath(icon) == nil {
                AppIcon(icon, size: size, hue: .teal)
            } else if let image {
                ImageIconView(image: image, size: size)
            } else {
                AppIcon("shippingbox", size: size, hue: .teal)
            }
        }
        .frame(width: size, height: size)
        .task(id: requestID) {
            image = nil
            guard PackIcon.imagePath(icon) != nil else { return }
            do {
                let data: Data?
                if let directory {
                    data = try PackIcon.pngData(icon, in: directory)
                } else if let remoteURL {
                    let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: remoteURL, timeoutInterval: 10))
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          response.expectedContentLength <= PackIcon.byteLimit else { return }
                    var downloaded = Data()
                    for try await byte in bytes.prefix(PackIcon.byteLimit + 1) { downloaded.append(byte) }
                    data = try PackIcon.normalize(downloaded, extension: remoteURL.pathExtension)
                } else { return }
                try Task.checkCancellation()
                image = data.flatMap(NSImage.init(data:))
            } catch { /* Offline or invalid artwork retains the bounded placeholder. */ }
        }
    }
}
