import XCTest
import SwiftUI
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class PluginIconTests: XCTestCase {
    func testArtworkRendersAtFixedSizesAndExportsToFinder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" rx="16" fill="#08b7a4"/><path d="M40 50 L55 65 L80 35" fill="none" stroke="white" stroke-width="9"/><path d="M105 50 H160" stroke="white" stroke-width="9"/></svg>"##
        try Data(svg.utf8).write(to: directory.appendingPathComponent("icon.svg"))
        guard case .imageFile(let file) = IconStore.importPackIcon("icon.svg", directory: directory) else {
            return XCTFail("Bundled artwork must become a Finder-compatible image icon")
        }
        defer { IconStore.remove(file) }
        let bytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(IconStore.base64PNG(for: file))))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        XCTAssertEqual(bitmap.pixelsWide, 36); XCTAssertEqual(bitmap.pixelsHigh, 36)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 18, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertNotNil(IconStore.loadNSImage(file))
        XCTAssertEqual(IconStore.importPackIcon("bolt", directory: directory), .symbol("bolt"))

        let host = NSHostingView(rootView: HStack(spacing: 24) {
            ForEach([32, 44, 52], id: \.self) { size in
                VStack {
                    PluginIconView(icon: "icon.svg", directory: directory, size: CGFloat(size))
                    Text("\(size) pt").font(.caption)
                }
            }
            PluginIconView(icon: "shippingbox", size: 44)
        }.padding(24).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let screenshot = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: screenshot)
        // Teal pixels prove the asynchronous image branch loaded instead of only the placeholder.
        var teal = 0
        for y in 0..<screenshot.pixelsHigh {
            for x in 0..<screenshot.pixelsWide {
                if let color = screenshot.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.greenComponent - color.redComponent > 0.3,
                   color.blueComponent - color.redComponent > 0.25 { teal += 1 }
            }
        }
        XCTAssertGreaterThan(teal, 500)
        try XCTUnwrap(screenshot.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/anywhere-plugin-icons.png"))
    }

    func testCatalogArtworkUsesPinnedRepositoryRevision() throws {
        let sha = String(repeating: "a", count: 40)
        var entry: [String: Any] = ["id": "owner.tool", "repository": "https://github.com/owner/tool", "revision": sha,
                                  "name": "Tool", "icon": "assets/icon.png", "manifestSchemaVersion": 4, "types": ["tool"]]
        func decode() throws -> CatalogPack {
            let catalog = try PackCatalog.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "packages": [entry]]))
            return try XCTUnwrap(catalog.packages.first)
        }
        XCTAssertEqual(try decode().iconURL?.absoluteString, "https://raw.githubusercontent.com/owner/tool/\(sha)/assets/icon.png")
        entry["icon"] = "https://other.example/icon.png"
        XCTAssertThrowsError(try decode())
        entry["icon"] = "../icon.png"
        XCTAssertThrowsError(try decode())
        entry["icon"] = "shippingbox"
        XCTAssertNil(try decode().iconURL)
    }
}
