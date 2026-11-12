import XCTest
import AppKit
@testable import AnyWhereCore

final class PackIconTests: XCTestCase {
    private func bitmap(width: Int = 200, height: Int = 100) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func testRasterAndStaticVectorFitWithinBoundedTransparentSquare() throws {
        let source = try bitmap()
        for (format, suffix) in [(NSBitmapImageRep.FileType.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.tiff, "tiff")] {
            let data = try XCTUnwrap(source.representation(using: format, properties: [:]))
            let result = try XCTUnwrap(NSBitmapImageRep(data: PackIcon.normalize(data, extension: suffix)))
            XCTAssertEqual(result.pixelsWide, 128); XCTAssertEqual(result.pixelsHigh, 128)
            XCTAssertEqual(try XCTUnwrap(result.colorAt(x: 64, y: 0)).alphaComponent, 0, accuracy: 0.01)
            XCTAssertGreaterThan(try XCTUnwrap(result.colorAt(x: 64, y: 64)).alphaComponent, 0.9)
        }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="red"/></svg>"#.utf8)
        let vector = try XCTUnwrap(NSBitmapImageRep(data: PackIcon.normalize(svg, extension: "svg")))
        XCTAssertEqual(vector.pixelsWide, 128)
        XCTAssertGreaterThan(try XCTUnwrap(vector.colorAt(x: 64, y: 64)).alphaComponent, 0.9)
        let pdf = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: pdf)), mediaBox: &page, nil))
        for color in [NSColor.red.cgColor, NSColor.blue.cgColor] {
            context.beginPDFPage(nil); context.setFillColor(color); context.fill(page); context.endPDFPage()
        }
        context.closePDF()
        let firstPage = try XCTUnwrap(NSBitmapImageRep(data: PackIcon.normalize(pdf as Data, extension: "pdf")))
        XCTAssertGreaterThan(try XCTUnwrap(firstPage.colorAt(x: 64, y: 64)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        XCTAssertThrowsError(try PackIcon.normalize(Data(repeating: 0, count: PackIcon.byteLimit + 1), extension: "png"))
        XCTAssertThrowsError(try PackIcon.normalize(try XCTUnwrap(bitmap(width: 4097, height: 1).representation(using: .png, properties: [:])), extension: "png"))
        for unsafe in [#"<svg><script/></svg>"#, #"<svg><image href="https://example.com/a.png"/></svg>"#,
                       #"<svg onload="alert(1)"/>"#, #"<!DOCTYPE svg><svg/>"#,
                       #"<?xml-stylesheet href="https://example.com/a.css"?><svg/>"#] {
            XCTAssertThrowsError(try PackIcon.normalize(Data(unsafe.utf8), extension: "svg"))
        }
    }

    func testManifestPathsAndSnapshotRejectMissingOrEscapingArtwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try PackIcon.pngData("shippingbox", in: root))
        for path in ["../icon.png", "/tmp/icon.png", "https://example.com/icon.png", "file:///tmp/icon.png", "images/icon.exe"] {
            XCTAssertThrowsError(try PackIcon.validate(path), path)
        }
        let manifest = PackManifest(schemaVersion: 1, name: "Artwork", icon: "art.png",
                                    actions: [PackAction(id: "tool", title: "Tool", icon: "art.png", script: "run.sh")])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        XCTAssertThrowsError(try PackSnapshot.read(in: root))
        let png = try XCTUnwrap(bitmap().representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("art.png"))
        XCTAssertEqual(try PackSnapshot.read(in: root).manifest.icon, "art.png")
        try FileManager.default.removeItem(at: root.appendingPathComponent("art.png"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("art.png").path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try PackSnapshot.read(in: root))
    }
}
