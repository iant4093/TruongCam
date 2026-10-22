#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import UIKit
import XCTest
@testable import TruongCam

private actor JPEG51PhotoLibrary: DNGPhotoLibraryWriting {
    private(set) var authorizations = 0
    private(set) var originals: [Data] = []
    private(set) var filenames: [String] = []
    func requestAddAuthorization() -> Bool { authorizations += 1; return true }
    func addOriginals(_ files: [URL]) throws {
        originals = try files.map { try Data(contentsOf: $0) }
        filenames = files.map(\.lastPathComponent)
    }
}

final class JPEGPhotosNativeTests: XCTestCase {
    @MainActor func testJPEGPhotosActionRetainsExactCopiesAndSkipsMetadataWithoutRealPhotoKit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JPEGPhotos51-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let jpg = root.appendingPathComponent("one.jpg"), jpeg = root.appendingPathComponent("two.jpeg")
        let json = root.appendingPathComponent("one.json")
        try bytes.write(to: jpg); try bytes.write(to: jpeg); try Data("{}".utf8).write(to: json)
        let library = JPEG51PhotoLibrary(), exporter = DNGPhotosExporter(library: library)
        let activity = SaveDNGToPhotosActivity(exporter: exporter)
        XCTAssertTrue(activity.canPerform(withActivityItems: [jpg]))
        XCTAssertTrue(activity.canPerform(withActivityItems: [jpeg]))
        XCTAssertFalse(activity.canPerform(withActivityItems: [json]))
        let count = try await exporter.save([jpg, json, jpeg])
        XCTAssertEqual(count, 2)
        let imported = await library.originals, names = await library.filenames, calls = await library.authorizations
        XCTAssertEqual(imported, [bytes, bytes]); XCTAssertEqual(names, ["one.jpg", "two.jpeg"])
        XCTAssertEqual(calls, 1); XCTAssertEqual(try Data(contentsOf: jpg), bytes)
        do { _ = try await exporter.save([json]); XCTFail("Metadata alone cannot request Photos import") }
        catch { }
        let finalCalls = await library.authorizations
        XCTAssertEqual(finalCalls, 1)
        let consent = PartialExportConsentCopy.message(absences: ["originals/Holiday.jpeg (native provider detail)"], sources: [])
        XCTAssertTrue(consent.contains("Holiday.jpeg")); XCTAssertFalse(consent.contains("native provider detail"))
    }
}
#endif
