import XCTest
import CoreGraphics
import AppKit
import SwiftUI
@testable import VisionScreenRecallKit

final class VisionScreenRecallKitTests: XCTestCase {

    // MARK: - Helpers

    /// Renders crisp black text on a white background into a `CGImage` for deterministic on-device OCR testing.
    private func renderTextImage(
        width: Int = 900,
        height: Int = 500,
        blocks: [(text: String, rect: CGRect, fontSize: CGFloat)]
    ) throws -> CGImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))

        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        for block in blocks {
            let font = NSFont.systemFont(ofSize: block.fontSize, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let attributed = NSAttributedString(string: block.text, attributes: attrs)
            // Convert top-left rect to AppKit bottom-left coordinates
            let flippedRect = NSRect(
                x: block.rect.origin.x,
                y: CGFloat(height) - block.rect.maxY,
                width: block.rect.width,
                height: block.rect.height
            )
            attributed.draw(in: flippedRect)
        }

        return try XCTUnwrap(rep.cgImage)
    }

    private func makeSolidGrayImage(gray: UInt8, size: Int = 64) throws -> CGImage {
        var pixels = [UInt8](repeating: gray, count: size * size)
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: - VisionOCRService Tests

    func testVisionOCRPixelCropRectAndClamping() {
        let crop = VisionOCRService.pixelCropRect(
            normalizedRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
            imageWidth: 1080,
            imageHeight: 2400
        )
        XCTAssertEqual(crop, CGRect(x: 270, y: 1200, width: 540, height: 600))

        // Out-of-bounds crop must clamp safely
        let clamped = VisionOCRService.pixelCropRect(
            normalizedRect: CGRect(x: -0.5, y: 0.9, width: 2.0, height: 0.5),
            imageWidth: 1000,
            imageHeight: 2000
        )
        XCTAssertEqual(clamped.origin.x, 0)
        XCTAssertLessThanOrEqual(clamped.maxX, 1000)
        XCTAssertLessThanOrEqual(clamped.maxY, 2000)
    }

    func testVisionOCRDefaultAndCustomLanguages() {
        XCTAssertEqual(VisionOCRService.defaultRecognitionLanguages, ["en-US", "ru-RU"])
        XCTAssertEqual(VisionOCRService.shared.recognitionLanguages, ["en-US", "ru-RU"])

        let custom = VisionOCRService(recognitionLanguages: ["en-US", "de-DE"], recognitionLevel: .fast)
        XCTAssertEqual(custom.recognitionLanguages, ["en-US", "de-DE"])
        XCTAssertEqual(custom.recognitionLevel, .fast)
    }

    func testVisionOCRRecognizesProgrammaticallyRenderedTextAndBoundingBoxes() async throws {
        let image = try renderTextImage(
            width: 900,
            height: 400,
            blocks: [
                ("INVOICE 2026 TOTAL", CGRect(x: 60, y: 80, width: 780, height: 100), 54),
                ("PAYMENT CONFIRMED", CGRect(x: 60, y: 220, width: 780, height: 100), 48)
            ]
        )

        let service = VisionOCRService(recognitionLanguages: ["en-US"])
        let fullText = try await service.recognizeText(in: image)
        XCTAssertTrue(fullText.localizedCaseInsensitiveContains("INVOICE"), "Expected INVOICE in OCR output, got: \(fullText)")
        XCTAssertTrue(fullText.localizedCaseInsensitiveContains("PAYMENT"), "Expected PAYMENT in OCR output, got: \(fullText)")

        let observations = try await service.recognizeObservations(in: image)
        XCTAssertGreaterThanOrEqual(observations.count, 2)
        for obs in observations {
            XCTAssertGreaterThan(obs.confidence, 0)
            XCTAssertGreaterThanOrEqual(obs.boundingBox.minX, 0)
            XCTAssertLessThanOrEqual(obs.boundingBox.maxX, 1)
            XCTAssertGreaterThanOrEqual(obs.boundingBox.minY, 0)
            XCTAssertLessThanOrEqual(obs.boundingBox.maxY, 1)
        }

        let match = try await service.findTextCenter(matching: "PAYMENT CONFIRMED", in: image)
        XCTAssertNotNil(match)
        XCTAssertGreaterThan(match?.normalizedCenterY ?? 0, 0.45)
    }

    func testVisionOCRRegionCropIsolatesTargetQuadrant() async throws {
        let image = try renderTextImage(
            width: 900,
            height: 600,
            blocks: [
                ("ALPHA HEADER", CGRect(x: 80, y: 50, width: 740, height: 110), 56),
                ("OMEGA FOOTER", CGRect(x: 80, y: 420, width: 740, height: 110), 56)
            ]
        )

        let service = VisionOCRService(recognitionLanguages: ["en-US"])
        // Crop strictly to bottom half where OMEGA FOOTER lives
        let bottomText = try await service.recognizeText(
            in: image,
            cropRect: CGRect(x: 0.0, y: 0.58, width: 1.0, height: 0.42)
        )
        XCTAssertTrue(bottomText.localizedCaseInsensitiveContains("OMEGA"), "Expected OMEGA in bottom crop, got: \(bottomText)")
        XCTAssertFalse(bottomText.localizedCaseInsensitiveContains("ALPHA"), "Did not expect ALPHA in bottom crop, got: \(bottomText)")
    }

    // MARK: - FrameChangeDetector Tests

    func testFrameChangeDetectorDetectsStaticVsChangedFrames() throws {
        let detector = FrameChangeDetector()

        let dark = try makeSolidGrayImage(gray: 20)
        let darkAgain = try makeSolidGrayImage(gray: 20)
        let bright = try makeSolidGrayImage(gray: 220)

        XCTAssertTrue(detector.hasFrameChanged(dark))
        XCTAssertFalse(detector.hasFrameChanged(darkAgain))
        XCTAssertTrue(detector.hasFrameChanged(bright))

        XCTAssertEqual(FrameChangeDetector.frameHash(for: dark), FrameChangeDetector.frameHash(for: darkAgain))
        XCTAssertNotEqual(FrameChangeDetector.frameHash(for: dark), FrameChangeDetector.frameHash(for: bright))

        detector.reset()
        XCTAssertTrue(detector.hasFrameChanged(bright))
    }

    // MARK: - ScreenMemoryDatabase Tests

    func testScreenMemoryDatabaseFTS5SearchAndRetentionPruning() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-recall-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = ScreenMemoryDatabase(baseDirectoryURL: tmpDir)
        let oldThumb = "old.jpg"
        let recentThumb = "recent.jpg"
        try Data("old".utf8).write(to: db.thumbnailsDirectoryURL.appendingPathComponent(oldThumb))
        try Data("recent".utf8).write(to: db.thumbnailsDirectoryURL.appendingPathComponent(recentThumb))

        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)

        XCTAssertNotNil(db.insertSnapshot(
            timestamp: tenDaysAgo,
            sourceName: "ArchiveApp",
            sourceIdentifier: "com.old.app",
            extractedText: "Archived invoice 9012",
            thumbnailFilename: oldThumb,
            frameHash: 111
        ))
        XCTAssertNotNil(db.insertSnapshot(
            timestamp: now,
            sourceName: "BankApp",
            sourceIdentifier: "com.bank.app",
            extractedText: "Checking account balance is $4,250.00",
            thumbnailFilename: recentThumb,
            frameHash: 222
        ))

        let hits = db.search(query: "bal")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sourceName, "BankApp")
        XCTAssertEqual(hits.first?.sourceIdentifier, "com.bank.app")
        XCTAssertTrue(hits.first?.highlightedSnippet.contains("«balance»") == true)

        // Empty query returns recent entries
        let recent = db.search(query: "")
        XCTAssertEqual(recent.count, 2)

        // Unsafe FTS5 characters must not crash or inject syntax errors
        XCTAssertEqual(db.search(query: "\"unterminated* (AND OR").count, 0)

        let pruned = db.pruneRetention(now: now, olderThanDays: 7)
        XCTAssertEqual(pruned, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.thumbnailsDirectoryURL.appendingPathComponent(oldThumb).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.thumbnailsDirectoryURL.appendingPathComponent(recentThumb).path))
        XCTAssertEqual(db.stats().count, 1)

        db.clearAll()
        XCTAssertEqual(db.stats().count, 0)
    }

    func testScreenMemoryDatabaseCustomURLAndDiskCapPruning() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-recall-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let customDBURL = tmpDir.appendingPathComponent("custom-recall.sqlite", isDirectory: false)
        let db = ScreenMemoryDatabase(databaseURL: customDBURL, retentionDays: 14, maxDiskCapMB: 100)
        XCTAssertEqual(db.databaseURL, customDBURL)
        XCTAssertEqual(db.retentionDays, 14)
        XCTAssertEqual(db.maxDiskCapMB, 100)

        let now = Date()
        let blob512 = Data(repeating: 0xAB, count: 512)

        let id1 = db.insertSnapshot(
            timestamp: now.addingTimeInterval(-300),
            sourceName: "Safari",
            sourceIdentifier: "com.apple.Safari",
            extractedText: "First oldest snapshot",
            thumbnailJPEGData: blob512,
            frameHash: 1
        )
        let id2 = db.insertSnapshot(
            timestamp: now.addingTimeInterval(-200),
            sourceName: "Terminal",
            sourceIdentifier: "com.apple.Terminal",
            extractedText: "Second middle snapshot",
            thumbnailJPEGData: blob512,
            frameHash: 2
        )
        let id3 = db.insertSnapshot(
            timestamp: now.addingTimeInterval(-100),
            sourceName: "Xcode",
            sourceIdentifier: "com.apple.dt.Xcode",
            extractedText: "Third newest snapshot",
            thumbnailJPEGData: blob512,
            frameHash: 3
        )
        XCTAssertNotNil(id1)
        XCTAssertNotNil(id2)
        XCTAssertNotNil(id3)
        XCTAssertEqual(db.stats().count, 3)

        // Cap to 600 bytes -> must prune oldest two snapshots, leaving only the newest 512-byte one
        let pruned = db.pruneRetention(now: now, maxThumbnailBytes: 600)
        XCTAssertEqual(pruned, 2)
        XCTAssertEqual(db.stats().count, 1)
        let remaining = db.search(query: "")
        XCTAssertEqual(remaining.first?.sourceName, "Xcode")
        XCTAssertEqual(remaining.first?.loadThumbnailData()?.count, 512)
    }

    // MARK: - ScreenMemorySnapshotter Tests

    func testScreenMemorySnapshotterCapturesChangedFramesAndSkipsStatic() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-recall-snapshotter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = ScreenMemoryDatabase(baseDirectoryURL: tmpDir)

        let frame1 = try renderTextImage(
            width: 800,
            height: 360,
            blocks: [("RELEASE NOTES V1", CGRect(x: 60, y: 110, width: 680, height: 120), 54)]
        )
        let frame2 = try renderTextImage(
            width: 800,
            height: 360,
            blocks: [("BUILD SUCCEEDED 2026", CGRect(x: 60, y: 110, width: 680, height: 120), 54)]
        )

        final class MockSource: @unchecked Sendable {
            var currentFrame: CGImage?
            var currentContext: (sourceName: String?, identifier: String?) = ("Notes", "com.apple.Notes")
        }
        let mock = MockSource()
        mock.currentFrame = frame1

        let snapshotter = ScreenMemorySnapshotter(
            database: db,
            ocrService: VisionOCRService(recognitionLanguages: ["en-US"]),
            interval: 1.0,
            frameProvider: { mock.currentFrame },
            contextProvider: { mock.currentContext }
        )

        // 1. First capture indexes frame1
        let firstId = await snapshotter.captureOnce()
        XCTAssertNotNil(firstId)
        XCTAssertEqual(db.stats().count, 1)

        // 2. Identical frame must be gated out by FrameChangeDetector
        let duplicateId = await snapshotter.captureOnce()
        XCTAssertNil(duplicateId)
        XCTAssertEqual(db.stats().count, 1)

        // 3. New frame with different text must be captured and searchable via FTS5
        mock.currentFrame = frame2
        mock.currentContext = ("Terminal", "com.apple.Terminal")
        let secondId = await snapshotter.captureOnce()
        XCTAssertNotNil(secondId)
        XCTAssertEqual(db.stats().count, 2)

        let hits = db.search(query: "SUCCEEDED")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sourceName, "Terminal")
        XCTAssertEqual(hits.first?.sourceIdentifier, "com.apple.Terminal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hits.first?.thumbnailURL.path ?? ""))

        snapshotter.clearAllMemory()
        XCTAssertEqual(db.stats().count, 0)
    }

    func testScreenMemorySnapshotterStartStopLoop() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-recall-loop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = ScreenMemoryDatabase(baseDirectoryURL: tmpDir)
        let frame = try renderTextImage(
            width: 800,
            height: 360,
            blocks: [("PERIODIC SNAPSHOT", CGRect(x: 60, y: 110, width: 680, height: 120), 54)]
        )

        let snapshotter = ScreenMemorySnapshotter(
            database: db,
            ocrService: VisionOCRService(recognitionLanguages: ["en-US"]),
            interval: 0.05,
            frameProvider: { frame },
            contextProvider: { ("Preview", "com.apple.Preview") }
        )

        snapshotter.start()
        try await Task.sleep(nanoseconds: 450_000_000)
        snapshotter.stop()

        // Allow main-queue published state updates to settle
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(snapshotter.isRunning)
        XCTAssertEqual(db.stats().count, 1)
    }

    // MARK: - SwiftUI Views Smoke Instantiation

    @MainActor
    func testSwiftUIViewsCanBeConstructed() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-recall-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = ScreenMemoryDatabase(baseDirectoryURL: tmpDir)
        let img = try makeSolidGrayImage(gray: 128)

        let overlay = OCRRegionSelectionOverlay(image: img) { _ in }
        let searchView = RecallSearchView(database: db, onSelectEntry: { _ in }, onDismiss: {})

        XCTAssertNotNil(overlay.body)
        XCTAssertNotNil(searchView.body)
    }
}
