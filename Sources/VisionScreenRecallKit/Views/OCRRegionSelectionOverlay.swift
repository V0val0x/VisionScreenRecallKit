import SwiftUI
import AppKit

/// Interactive selection-rectangle overlay for on-device Apple Vision OCR on any live frame or image.
public struct OCRRegionSelectionOverlay: View {
    public let frameProvider: @Sendable () async -> CGImage?
    public let ocrService: VisionOCRService
    public let recognitionLanguages: [String]?
    public let copyToPasteboard: Bool
    public let promptText: String
    public let processingText: String
    public let onTextExtracted: (String) -> Void
    public let onError: ((Error) -> Void)?
    public let onDismiss: (() -> Void)?

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var isProcessing: Bool = false
    @State private var dashPhase: CGFloat = 0
    @State private var isHovering: Bool = false

    public init(
        frameProvider: @escaping @Sendable () async -> CGImage?,
        ocrService: VisionOCRService = .shared,
        recognitionLanguages: [String]? = nil,
        copyToPasteboard: Bool = true,
        promptText: String = "Drag over text to copy",
        processingText: String = "Recognizing...",
        onTextExtracted: @escaping (String) -> Void,
        onError: ((Error) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.frameProvider = frameProvider
        self.ocrService = ocrService
        self.recognitionLanguages = recognitionLanguages
        self.copyToPasteboard = copyToPasteboard
        self.promptText = promptText
        self.processingText = processingText
        self.onTextExtracted = onTextExtracted
        self.onError = onError
        self.onDismiss = onDismiss
    }

    /// Convenience initializer for running region-selection OCR over a static `CGImage`.
    public init(
        image: CGImage,
        ocrService: VisionOCRService = .shared,
        recognitionLanguages: [String]? = nil,
        copyToPasteboard: Bool = true,
        promptText: String = "Drag over text to copy",
        processingText: String = "Recognizing...",
        onTextExtracted: @escaping (String) -> Void,
        onError: ((Error) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.init(
            frameProvider: { image },
            ocrService: ocrService,
            recognitionLanguages: recognitionLanguages,
            copyToPasteboard: copyToPasteboard,
            promptText: promptText,
            processingText: processingText,
            onTextExtracted: onTextExtracted,
            onError: onError,
            onDismiss: onDismiss
        )
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.36)
                    .contentShape(Rectangle())

                if let rect = currentSelectionRect(in: geo.size) {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.16))
                        .overlay(
                            Rectangle()
                                .stroke(
                                    Color.cyan,
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: dashPhase)
                                )
                        )
                        .shadow(color: .cyan.opacity(0.35), radius: 8)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }

                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: isProcessing ? "sparkles" : "text.viewfinder")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.cyan)
                            .symbolEffect(.pulse, isActive: isProcessing)

                        Text(isProcessing ? processingText : promptText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)

                        if let onDismiss {
                            Button {
                                onDismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.75)
                    )
                    .padding(.top, 14)

                    Spacer()
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    dashPhase = -20
                }
            }
            .onHover { hovering in
                if hovering && !isHovering {
                    isHovering = true
                    NSCursor.crosshair.push()
                } else if !hovering && isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        guard let start = dragStart else { return }
                        let rect = normalizedRect(from: start, to: value.location, in: geo.size)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragStart = nil
                            dragCurrent = nil
                        }
                        runOCR(normalizedRect: rect)
                    }
            )
        }
    }

    private func currentSelectionRect(in size: CGSize) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let minX = max(0, min(start.x, end.x)) / w
        let minY = max(0, min(start.y, end.y)) / h
        let width = min(1 - minX, abs(end.x - start.x) / w)
        let height = min(1 - minY, abs(end.y - start.y) / h)
        return CGRect(x: minX, y: minY, width: max(0.02, width), height: max(0.02, height))
    }

    private func runOCR(normalizedRect: CGRect) {
        isProcessing = true
        Task {
            do {
                guard let image = await frameProvider() else {
                    throw NSError(
                        domain: "VisionScreenRecallKit.OCRRegionSelectionOverlay",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "No frame available for OCR"]
                    )
                }
                let text = try await ocrService.extractAndCopyText(
                    from: image,
                    cropRect: normalizedRect,
                    recognitionLanguages: recognitionLanguages,
                    copyToPasteboard: copyToPasteboard
                )
                await MainActor.run {
                    isProcessing = false
                    onTextExtracted(text)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    onError?(error)
                }
            }
        }
    }
}
