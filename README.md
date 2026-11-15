# VisionScreenRecallKit

An on-device **Apple Vision OCR** and **SQLite FTS5 Semantic Screen Memory ("Recall")** Swift Package for macOS — extracted from [AndOnMac](https://github.com/V0val0x/AndOnMac) into a clean, zero-dependency SDK.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)](https://github.com/V0val0x/VisionScreenRecallKit)
[![Swift: 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![CI](https://github.com/V0val0x/VisionScreenRecallKit/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/VisionScreenRecallKit/actions/workflows/ci.yml)

**English** | [Русская версия (Russian)](README_RU.md)

---

## Features

- **Neural Engine OCR (`VisionOCRService`):** Fast on-device `VNRecognizeTextRequest` with normalized region cropping (`cropRect`), full-frame text extraction, bounding-box observations (`RecognizedTextObservation`), text-center search (`findTextCenter`), and configurable recognition languages (defaulting to `["en-US", "ru-RU"]`).
- **Smart Frame Change Gate (`FrameChangeDetector`):** Perceptual 16×16 luma-grid downsampling + 64-bit FNV-1a delta hashing so Vision OCR only runs when visual content actually changes.
- **Instant SQLite FTS5 Search (`ScreenMemoryDatabase`):** 100% local SQLite3 full-text index (`porter unicode61` tokenizer) with `snippet()` match highlighting, JPEG thumbnail storage, configurable DB URL, retention-day pruning, and max disk-cap pruning.
- **Privacy-First Local Storage:** Zero cloud uploads or telemetry. Snapshots, OCR text, and thumbnails stay strictly on your Mac with automatic retention & disk-cap enforcement and 1-call `clearAll()` wiping.
- **Decoupled Periodic Snapshotter (`ScreenMemorySnapshotter`):** Generic async `frameProvider` and `contextProvider` closures running inside `autoreleasepool` — index any `CGImage` stream (mirrored phone frames, app windows, video buffers, canvas renders).
- **Ready-to-Drop SwiftUI Overlays:**
  - `OCRRegionSelectionOverlay` — drag-select rectangle over any frame/image with animated marquee, crosshair cursor, clipboard copy, and extracted text callback.
  - `RecallSearchView` — Spotlight-style floating search UI backed directly by any `ScreenMemoryDatabase` with keyboard navigation, `«match»` snippet highlighting, thumbnails, and storage stats.

---

## Installation (Swift Package Manager)

Add `VisionScreenRecallKit` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/V0val0x/VisionScreenRecallKit", from: "1.0.0")
]
```

And add `"VisionScreenRecallKit"` to your target dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["VisionScreenRecallKit"]
)
```

> **Requirements:** macOS 14.0+, Swift 5.9+ (uses system `sqlite3`, `Vision`, `CoreGraphics`, `AppKit`, `SwiftUI`).

---

## Quick Start

### 1. Headless API: Vision OCR, Frame Gate, Snapshotter & FTS5 Recall

```swift
import VisionScreenRecallKit

// 1. Direct OCR & normalized region cropping
let ocr = VisionOCRService(recognitionLanguages: ["en-US", "ru-RU"])
let fullText = try await ocr.recognizeText(in: cgImage)
let observations = try await ocr.recognizeObservations(
    in: cgImage,
    cropRect: CGRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
)

// Find center coordinates of a specific label on screen
if let match = try await ocr.findTextCenter(matching: "Transfer", in: cgImage) {
    print("Found '\(match.matchedText)' at (\(match.normalizedCenterX), \(match.normalizedCenterY))")
}

// 2. Local SQLite FTS5 Screen Memory Database (7-day retention, 250 MB cap by default)
let memoryDB = ScreenMemoryDatabase(
    retentionDays: 7,
    maxDiskCapMB: 250
)

// 3. Periodic Snapshotter with your own CGImage & context closures
let snapshotter = ScreenMemorySnapshotter(
    database: memoryDB,
    interval: 10.0,
    frameProvider: { await myRenderer.latestFrame() },
    contextProvider: { ("Safari", "com.apple.Safari") }
)
snapshotter.start()

// 4. Instant FTS5 prefix search with highlighted snippets
let hits = memoryDB.search(query: "invoice")
for hit in hits {
    print("[\(hit.sourceName)] \(hit.highlightedSnippet)")
}
```

### 2. SwiftUI Overlays: Region OCR & Spotlight Recall Search

```swift
import SwiftUI
import VisionScreenRecallKit

struct MirrorWorkspaceView: View {
    @State private var showOCR = false
    @State private var showRecall = false
    @State private var captureEnabled = true

    let database = ScreenMemoryDatabase.shared

    var body: some View {
        ZStack {
            // Your live video / canvas / image view
            MyFrameCanvasView()

            if showOCR {
                OCRRegionSelectionOverlay(
                    frameProvider: { await MyFrameSource.latestCGImage() },
                    onTextExtracted: { extracted in
                        print("Copied OCR text: \(extracted)")
                        showOCR = false
                    },
                    onDismiss: { showOCR = false }
                )
            }

            if showRecall {
                RecallSearchView(
                    database: database,
                    isCaptureEnabled: $captureEnabled,
                    onSelectEntry: { entry in
                        print("Selected snapshot from \(entry.sourceName): \(entry.extractedText)")
                        showRecall = false
                    },
                    onDismiss: { showRecall = false }
                )
            }
        }
    }
}
```

---

## Privacy & Retention Architecture

- **100% On-Device Execution:** Text recognition runs locally on Apple Silicon via `VNRecognizeTextRequest` (`Vision.framework`), and indexing runs locally via SQLite3 FTS5 (`WAL` mode).
- **Default Storage Location:** `~/Library/Application Support/VisionScreenRecallKit/Memory/memory.sqlite` with compressed JPEG thumbnails in `thumbnails/`. Pass any custom `databaseURL` or `baseDirectoryURL` to `ScreenMemoryDatabase` (for example, a temporary or app-sandboxed container directory).
- **Automatic Retention & Disk Cap Pruning:** `pruneRetention()` removes rows and `.jpg` files older than `retentionDays` (default: `7` days) and evicts the oldest entries first whenever thumbnail storage exceeds `maxDiskCapMB` (default: `250` MB).
- **Instant Wipe:** Call `database.clearAll()` or `snapshotter.clearAllMemory()` to delete all rows, `VACUUM` the SQLite database, and purge every thumbnail from disk.

---

## AndOnMac Ecosystem

`VisionScreenRecallKit` is part of the modular open-source ecosystem spun out from **AndOnMac**:

- [**AndOnMac**](https://github.com/V0val0x/AndOnMac) — Native macOS SwiftUI, VideoToolbox & Metal Android mirroring, file transfer & AI automation suite
- [**MetalScrcpyKit**](https://github.com/V0val0x/MetalScrcpyKit) — Hardware-accelerated VideoToolbox + `CAMetalLayer` 120Hz scrcpy video pipeline
- [**ADBConnectKit**](https://github.com/V0val0x/ADBConnectKit) — Native Swift ADB client, USB/Wi-Fi QR pairing, and hotspot/PAN bypass utilities
- [**AndroidMCPKit**](https://github.com/V0val0x/AndroidMCPKit) — Model Context Protocol (MCP) server & self-healing UI automation bridge for Android
- [**VisionScreenRecallKit**](https://github.com/V0val0x/VisionScreenRecallKit) — On-device Apple Vision OCR & SQLite FTS5 Semantic Screen Memory SDK (this repository)

---

## License

MIT License © 2026 Kirill Zaitsev. See [LICENSE](./LICENSE).
