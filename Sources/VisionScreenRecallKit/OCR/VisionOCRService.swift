import Foundation
import Vision
import CoreGraphics
import AppKit

/// A single recognized text line or region returned by `VisionOCRService`, with top-left normalized (`0...1`) coordinates.
public struct RecognizedTextObservation: Sendable, Equatable, Hashable {
    public let text: String
    public let confidence: Float
    /// Bounding box in top-left normalized (`0...1`) coordinates.
    public let boundingBox: CGRect

    /// Center point in top-left normalized (`0...1`) coordinates.
    public var normalizedCenter: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Located OCR text match with top-left normalized (`0...1`) center coordinates and bounding box.
public struct VisionTextMatch: Sendable, Equatable {
    public let matchedText: String
    public let normalizedCenterX: Double
    public let normalizedCenterY: Double
    public let boundingBox: CGRect

    public init(
        matchedText: String,
        normalizedCenterX: Double,
        normalizedCenterY: Double,
        boundingBox: CGRect = .zero
    ) {
        self.matchedText = matchedText
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.boundingBox = boundingBox
    }
}

/// Performs on-device Neural Engine / Apple Silicon text recognition using Apple Vision (`VNRecognizeTextRequest`).
public final class VisionOCRService: @unchecked Sendable {
    public static let defaultRecognitionLanguages: [String] = ["en-US", "ru-RU"]
    public static let shared = VisionOCRService()

    private let lock = NSLock()
    private var _recognitionLanguages: [String]
    private var _recognitionLevel: VNRequestTextRecognitionLevel
    private var _usesLanguageCorrection: Bool
    private var _automaticallyDetectsLanguage: Bool

    /// Default recognition languages used when none are passed to a recognition call.
    public var recognitionLanguages: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _recognitionLanguages
        }
        set {
            lock.lock()
            _recognitionLanguages = newValue
            lock.unlock()
        }
    }

    /// Default recognition accuracy level (`.accurate` or `.fast`).
    public var recognitionLevel: VNRequestTextRecognitionLevel {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _recognitionLevel
        }
        set {
            lock.lock()
            _recognitionLevel = newValue
            lock.unlock()
        }
    }

    public init(
        recognitionLanguages: [String] = VisionOCRService.defaultRecognitionLanguages,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        automaticallyDetectsLanguage: Bool = true
    ) {
        self._recognitionLanguages = recognitionLanguages
        self._recognitionLevel = recognitionLevel
        self._usesLanguageCorrection = usesLanguageCorrection
        self._automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }

    /// Converts a normalized selection rect (top-left origin, `0...1`) to pixel coordinates for `CGImage.cropping(to:)`.
    public static func pixelCropRect(
        normalizedRect: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let clampedX = max(0, min(1, normalizedRect.minX))
        let clampedY = max(0, min(1, normalizedRect.minY))
        let clamped = CGRect(
            x: clampedX,
            y: clampedY,
            width: max(0.01, min(1 - clampedX, normalizedRect.width)),
            height: max(0.01, min(1 - clampedY, normalizedRect.height))
        )
        return CGRect(
            x: clamped.origin.x * CGFloat(imageWidth),
            y: clamped.origin.y * CGFloat(imageHeight),
            width: clamped.size.width * CGFloat(imageWidth),
            height: clamped.size.height * CGFloat(imageHeight)
        ).integral
    }

    /// Recognizes text observations (text, confidence, and top-left normalized bounding boxes) in `image`.
    public func recognizeObservations(
        in image: CGImage,
        cropRect normalizedCropRect: CGRect? = nil,
        recognitionLanguages: [String]? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> [RecognizedTextObservation] {
        let targetImage: CGImage
        if let norm = normalizedCropRect {
            let cropRect = Self.pixelCropRect(
                normalizedRect: norm,
                imageWidth: image.width,
                imageHeight: image.height
            )
            targetImage = image.cropping(to: cropRect) ?? image
        } else {
            targetImage = image
        }

        let config = currentConfig(
            languagesOverride: recognitionLanguages,
            levelOverride: recognitionLevel
        )

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                autoreleasepool {
                    let request = VNRecognizeTextRequest { request, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        let rawObservations = (request.results as? [VNRecognizedTextObservation]) ?? []
                        let mapped: [RecognizedTextObservation] = rawObservations.compactMap { obs in
                            guard let candidate = obs.topCandidates(1).first else { return nil }
                            let text = candidate.string
                            guard !text.isEmpty else { return nil }
                            let box = obs.boundingBox
                            // Vision uses bottom-left origin; convert to top-left normalized (0...1) coordinates.
                            let topLeftBox = CGRect(
                                x: max(0, min(1, box.minX)),
                                y: max(0, min(1, 1.0 - box.maxY)),
                                width: max(0, min(1, box.width)),
                                height: max(0, min(1, box.height))
                            )
                            return RecognizedTextObservation(
                                text: text,
                                confidence: candidate.confidence,
                                boundingBox: topLeftBox
                            )
                        }
                        continuation.resume(returning: mapped)
                    }

                    request.recognitionLevel = config.level
                    request.usesLanguageCorrection = config.usesLanguageCorrection
                    request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage
                    if !config.languages.isEmpty {
                        request.recognitionLanguages = config.languages
                    }

                    let handler = VNImageRequestHandler(cgImage: targetImage, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Recognizes full-frame or region-cropped text from `image`, joined by newlines.
    public func recognizeText(
        in image: CGImage,
        cropRect normalizedCropRect: CGRect? = nil,
        recognitionLanguages: [String]? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> String {
        let observations = try await recognizeObservations(
            in: image,
            cropRect: normalizedCropRect,
            recognitionLanguages: recognitionLanguages,
            recognitionLevel: recognitionLevel,
            qos: qos
        )
        return observations.map(\.text).joined(separator: "\n")
    }

    /// Searches `image` on-device via Apple Vision OCR for `query` and returns its top-left normalized center coordinates.
    public func findTextCenter(
        matching query: String,
        in image: CGImage,
        recognitionLanguages: [String]? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> VisionTextMatch? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        let observations = try await recognizeObservations(
            in: image,
            recognitionLanguages: recognitionLanguages,
            qos: qos
        )

        var exactMatch: VisionTextMatch?
        var bestContains: (match: VisionTextMatch, lengthDelta: Int)?

        for obs in observations {
            let text = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let center = obs.normalizedCenter
            let match = VisionTextMatch(
                matchedText: text,
                normalizedCenterX: max(0, min(1, Double(center.x))),
                normalizedCenterY: max(0, min(1, Double(center.y))),
                boundingBox: obs.boundingBox
            )

            if text.compare(trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                exactMatch = match
                break
            }
            if text.localizedCaseInsensitiveContains(trimmedQuery) {
                let delta = abs(text.count - trimmedQuery.count)
                if bestContains == nil || delta < bestContains!.lengthDelta {
                    bestContains = (match, delta)
                }
            }
        }

        return exactMatch ?? bestContains?.match
    }

    /// Runs Vision OCR on `image` (optionally cropped to `cropRect`), optionally copies non-empty text to `NSPasteboard`, and returns it.
    @discardableResult
    public func extractAndCopyText(
        from image: CGImage,
        cropRect normalizedCropRect: CGRect? = nil,
        recognitionLanguages: [String]? = nil,
        copyToPasteboard: Bool = true,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> String {
        let text = try await recognizeText(
            in: image,
            cropRect: normalizedCropRect,
            recognitionLanguages: recognitionLanguages,
            qos: qos
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if copyToPasteboard, !trimmed.isEmpty {
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(trimmed, forType: .string)
            }
        }
        return trimmed
    }

    private func currentConfig(
        languagesOverride: [String]?,
        levelOverride: VNRequestTextRecognitionLevel?
    ) -> (languages: [String], level: VNRequestTextRecognitionLevel, usesLanguageCorrection: Bool, automaticallyDetectsLanguage: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            languages: languagesOverride ?? _recognitionLanguages,
            level: levelOverride ?? _recognitionLevel,
            usesLanguageCorrection: _usesLanguageCorrection,
            automaticallyDetectsLanguage: _automaticallyDetectsLanguage
        )
    }
}
