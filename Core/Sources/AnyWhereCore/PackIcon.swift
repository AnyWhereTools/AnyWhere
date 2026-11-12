import AppKit
import ImageIO

/// Plugin artwork is bundled with the pack and normalized before display or Finder IPC.
public enum PackIcon {
    public static let byteLimit = 1024 * 1024
    public static let dimensionLimit = 4096
    public static let outputSize = 128
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "heic", "heif", "ico", "icns", "svg", "pdf"]

    public struct Invalid: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public static func imagePath(_ icon: String) -> String? {
        icon.contains("/") || extensions.contains((icon as NSString).pathExtension.lowercased()) ? icon : nil
    }

    public static func validate(_ icon: String) throws {
        guard !icon.isEmpty, icon.utf8.count <= 256, !icon.contains("\0"), !icon.contains(":"), !icon.contains("\\") else {
            throw Invalid("图标必须是 SF Symbol 名称或插件包内的图片相对路径。")
        }
        if let path = imagePath(icon) {
            guard PackManifest.isSafeRelativeScriptPath(path), extensions.contains((path as NSString).pathExtension.lowercased()) else {
                throw Invalid("图标图片路径或格式不受支持。")
            }
        }
    }

    public static func pngData(_ icon: String, in directory: URL) throws -> Data? {
        try validate(icon)
        guard let path = imagePath(icon) else { return nil }
        let url = try PluginResourceResolver.resolve(root: directory, relativePath: path)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: byteLimit + 1) ?? Data()
        return try normalize(data, extension: url.pathExtension)
    }

    public static func normalize(_ data: Data, extension suffix: String) throws -> Data {
        guard !data.isEmpty, data.count <= byteLimit else { throw Invalid("图标文件不能超过 1 MiB。") }
        let image: NSImage
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            guard (1...dimensionLimit).contains(width), (1...dimensionLimit).contains(height) else {
                throw Invalid("图标尺寸不能超过 4096 × 4096 像素。")
            }
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: outputSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary) else { throw Invalid("无法读取图标图片。") }
            image = NSImage(cgImage: thumbnail, size: .zero)
        } else {
            guard ["svg", "pdf"].contains(suffix.lowercased()) else { throw Invalid("无法读取图标图片。") }
            if suffix.lowercased() == "svg" { try validateSVG(data) }
            guard let decoded = NSImage(data: data) else { throw Invalid("无法读取图标图片。") }
            image = decoded
        }
        let size = image.size
        guard size.width > 0, size.height > 0, size.width <= CGFloat(dimensionLimit), size.height <= CGFloat(dimensionLimit) else {
            throw Invalid("图标尺寸不能超过 4096 × 4096。")
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outputSize, pixelsHigh: outputSize,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Invalid("无法生成图标缩略图。") }
        bitmap.size = NSSize(width: outputSize, height: outputSize)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let side = CGFloat(outputSize), scale = min(side / size.width, side / size.height)
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)
        image.draw(in: NSRect(x: (side - size.width * scale) / 2, y: (side - size.height * scale) / 2,
                              width: size.width * scale, height: size.height * scale),
                   from: .zero, operation: .sourceOver, fraction: 1)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Invalid("无法生成图标缩略图。") }
        return png
    }

    /// Static vector artwork only; the native image renderer never receives active or external resources.
    private static func validateSVG(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY"), !text.localizedCaseInsensitiveContains("<?xml-stylesheet") else { throw Invalid("SVG 图标必须是独立的静态图片。") }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.localName == "svg" else { throw Invalid("无效的 SVG 图标。") }
        func check(_ node: XMLElement) throws {
            guard !["script", "foreignobject", "image", "feimage", "style", "a", "animate", "animatemotion", "animatetransform", "set"]
                .contains((node.localName ?? "").lowercased()) else { throw Invalid("SVG 图标不能包含脚本、动画或外部资源。") }
            for attribute in node.attributes ?? [] {
                let name = (attribute.localName ?? "").lowercased(), value = attribute.stringValue ?? ""
                let withoutLocalURLs = value.replacingOccurrences(of: #"url\(\s*#[A-Za-z0-9_.:-]+\s*\)"#, with: "", options: .regularExpression)
                guard !name.hasPrefix("on"), name != "style", name != "base", !value.contains("\\"),
                      !["href", "src"].contains(name) || value.hasPrefix("#"),
                      !withoutLocalURLs.localizedCaseInsensitiveContains("url(") else {
                    throw Invalid("SVG 图标不能包含脚本、样式表或外部资源。")
                }
            }
            for child in node.children ?? [] { if let element = child as? XMLElement { try check(element) } }
        }
        try check(root)
    }
}
