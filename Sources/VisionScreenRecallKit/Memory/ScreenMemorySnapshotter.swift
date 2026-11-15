import Foundation
import AppKit
import CoreGraphics

/// Periodic background screen memory indexer with perceptual frame-change gating,
/// Apple Vision OCR, compressed JPEG thumbnail generation, and retention pruning.
public final class ScreenMemorySnapshotter: ObservableObject, @unchecked Sendable {
    public typealias FrameProvider = @Sendable () async -> CGImage?
    public typealias ContextProvider = @Sendable () async -> (sourceName: String?, identifier: String?)

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var indexedCount: Int = 0
    @Published public private(set) var storageBytes: Int64 = 0

    public let database: ScreenMemoryDatabase
    public let ocrService: VisionOCRService
    public let interval: TimeInterval
    public let minFrameDelta: Double
    public let thumbnailMaxWidth: CGFloat
    public let thumbnailJPEGQuality: CGFloat
    public let recognitionLanguages: [String]?

    private let detector: FrameChangeDetector
    private let frameProvider: FrameProvider
    private let contextProvider: ContextProvider
    private let lock = NSLock()
    private var loopTask: Task<Void, Never>?
    private var lastPruneDate: Date = .distantPast

    public init(
        database: ScreenMemoryDatabase = .shared,
        ocrService: VisionOCRService = .shared,
        interval: TimeInterval = 10.0,
        minFrameDelta: Double = 0.015,
        thumbnailMaxWidth: CGFloat = 360,
        thumbnailJPEGQuality: CGFloat = 0.65,
        recognitionLanguages: [String]? = nil,
        frameProvider: @escaping FrameProvider,
        contextProvider: @escaping ContextProvider = { (nil, nil) }
    ) {
        self.database = database
        self.ocrService = ocrService
        self.interval = max(0.05, interval)
        self.minFrameDelta = minFrameDelta
        self.thumbnailMaxWidth = max(32, thumbnailMaxWidth)
        self.thumbnailJPEGQuality = max(0.1, min(1.0, thumbnailJPEGQuality))
        self.recognitionLanguages = recognitionLanguages
        self.detector = FrameChangeDetector(defaultMinMeanDelta: minFrameDelta)
        self.frameProvider = frameProvider
        self.contextProvider = contextProvider
        refreshStats()
    }

    deinit {
        loopTask?.cancel()
    }

    /// Starts the periodic capture & indexing loop.
    public func start() {
        stop()
        detector.reset()

        DispatchQueue.main.async {
            self.isRunning = true
        }

        let intervalNanos = UInt64((interval * 1_000_000_000).rounded())
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = self.database.pruneRetention()
            self.setLastPruneDate(Date())
            self.refreshStats()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                if Task.isCancelled { break }
                await self.captureOnce()
            }
        }

        lock.lock()
        loopTask = task
        lock.unlock()
    }

    /// Stops the periodic capture loop and resets frame-change state.
    public func stop() {
        lock.lock()
        let task = loopTask
        loopTask = nil
        lock.unlock()

        task?.cancel()
        detector.reset()
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    /// Synchronizes published `indexedCount` and `storageBytes` from the backing database.
    public func refreshStats() {
        let s = database.stats()
        DispatchQueue.main.async {
            self.indexedCount = s.count
            self.storageBytes = s.totalBytes
        }
    }

    /// Deletes all indexed snapshots and resets the frame-change detector.
    public func clearAllMemory() {
        database.clearAll()
        detector.reset()
        refreshStats()
    }

    /// Performs a single capture cycle: fetches a frame, gates via `FrameChangeDetector`,
    /// extracts text with Apple Vision OCR, writes a compressed JPEG thumbnail, and inserts into SQLite FTS5.
    /// Returns the inserted snapshot row ID, or `nil` if skipped or empty.
    @discardableResult
    public func captureOnce() async -> Int64? {
        guard let frame = await frameProvider() else { return nil }
        guard detector.hasFrameChanged(frame, minMeanDelta: minFrameDelta) else { return nil }

        let frameHash = FrameChangeDetector.frameHash(for: frame)

        // Run Apple Vision OCR on Neural Engine at utility QoS (autoreleasepool is inside VisionOCRService)
        let extractedText: String
        do {
            extractedText = try await ocrService.recognizeText(
                in: frame,
                recognitionLanguages: recognitionLanguages,
                qos: .utility
            )
        } catch {
            return nil
        }

        let cleanedText = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }

        let context = await contextProvider()
        let sourceName = context.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = context.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedSource = (sourceName?.isEmpty == false ? sourceName! : nil)
            ?? (identifier?.isEmpty == false ? identifier! : "Screen")
        let resolvedIdentifier = identifier ?? ""

        let jpegData = autoreleasepool {
            Self.encodeJPEGThumbnail(
                from: frame,
                maxWidth: thumbnailMaxWidth,
                quality: thumbnailJPEGQuality
            )
        }
        guard let jpegData else { return nil }

        let insertedId = database.insertSnapshot(
            timestamp: Date(),
            sourceName: resolvedSource,
            sourceIdentifier: resolvedIdentifier,
            extractedText: cleanedText,
            thumbnailJPEGData: jpegData,
            frameHash: frameHash
        )

        if Date().timeIntervalSince(getLastPruneDate()) > 3_600 {
            _ = database.pruneRetention()
            setLastPruneDate(Date())
        }
        refreshStats()
        return insertedId
    }

    /// Encodes a downscaled JPEG thumbnail from `image`.
    public static func encodeJPEGThumbnail(
        from image: CGImage,
        maxWidth: CGFloat = 360,
        quality: CGFloat = 0.65
    ) -> Data? {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1.0, maxWidth / srcW)
        let dstW = max(1, Int((srcW * scale).rounded()))
        let dstH = max(1, Int((srcH * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let scaled = ctx.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func getLastPruneDate() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return lastPruneDate
    }

    private func setLastPruneDate(_ date: Date) {
        lock.lock()
        lastPruneDate = date
        lock.unlock()
    }
}
