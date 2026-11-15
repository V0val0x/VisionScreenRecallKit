# VisionScreenRecallKit

Локальный Swift-пакет для macOS с **Apple Vision OCR** и **семантической памятью экрана на базе SQLite FTS5 («Recall»)** — выделен из [AndOnMac](https://github.com/V0val0x/AndOnMac) в самостоятельный SDK без внешних зависимостей.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)](https://github.com/V0val0x/VisionScreenRecallKit)
[![Swift: 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![CI](https://github.com/V0val0x/VisionScreenRecallKit/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/VisionScreenRecallKit/actions/workflows/ci.yml)

[English](README.md) | **Русская версия**

---

## Возможности

- **OCR на Neural Engine (`VisionOCRService`):** Быстрое локальное распознавание текста через `VNRecognizeTextRequest` с нормализованной обрезкой области (`cropRect`), полным сканированием кадра, координатами найденных блоков (`RecognizedTextObservation`), поиском центра текста (`findTextCenter`) и настраиваемыми языками распознавания (по умолчанию `["en-US", "ru-RU"]`).
- **Умный фильтр изменений кадра (`FrameChangeDetector`):** Перцептивный даунсэмплинг в сетку яркости 16×16 и 64-битный FNV-1a хэш — Vision OCR запускается только тогда, когда изображение действительно изменилось.
- **Мгновенный поиск SQLite FTS5 (`ScreenMemoryDatabase`):** 100% локальный полнотекстовый индекс SQLite3 (токенизатор `porter unicode61`) с подсветкой совпадений `snippet()`, сжатыми JPEG-миниатюрами, настраиваемым путём к БД, очисткой по сроку хранения и лимитом дискового пространства.
- **Приватность и локальное хранение:** Никакой отправки данных в облако и телеметрии. Все снимки, распознанный текст и миниатюры хранятся только на вашем Mac с автоматическим удалением старых записей и мгновенной очисткой через `clearAll()`.
- **Отвязанный периодический индексатор (`ScreenMemorySnapshotter`):** Принимает любые async-замыкания `frameProvider` и `contextProvider`, работает внутри `autoreleasepool` — подходит для любых потоков `CGImage` (зеркалирование экрана, окна приложений, видеопотоки).
- **Готовые SwiftUI-компоненты:**
  - `OCRRegionSelectionOverlay` — интерактивное выделение области рамкой поверх любого кадра с анимацией, курсором-перекрестием, копированием в буфер обмена и колбэком с текстом.
  - `RecallSearchView` — поиск в стиле Spotlight поверх любой `ScreenMemoryDatabase` с навигацией с клавиатуры, подсветкой `«совпадений»`, миниатюрами и статистикой хранилища.

---

## Установка (Swift Package Manager)

Добавьте `VisionScreenRecallKit` в ваш `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/V0val0x/VisionScreenRecallKit", from: "1.0.0")
]
```

И подключите зависимость к вашему таргету:

```swift
.target(
    name: "YourApp",
    dependencies: ["VisionScreenRecallKit"]
)
```

> **Требования:** macOS 14.0+, Swift 5.9+ (используются системные `sqlite3`, `Vision`, `CoreGraphics`, `AppKit`, `SwiftUI`).

---

## Быстрый старт

### 1. Headless API: Vision OCR, фильтр кадров, Snapshotter и FTS5 Recall

```swift
import VisionScreenRecallKit

// 1. Распознавание текста и нормализованный crop области
let ocr = VisionOCRService(recognitionLanguages: ["en-US", "ru-RU"])
let fullText = try await ocr.recognizeText(in: cgImage)
let observations = try await ocr.recognizeObservations(
    in: cgImage,
    cropRect: CGRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
)

// Поиск нормализованного центра текста на кадре
if let match = try await ocr.findTextCenter(matching: "Перевод", in: cgImage) {
    print("Найдено '\(match.matchedText)' в (\(match.normalizedCenterX), \(match.normalizedCenterY))")
}

// 2. Локальная база Screen Memory (7 дней хранения, лимит 250 МБ по умолчанию)
let memoryDB = ScreenMemoryDatabase(
    retentionDays: 7,
    maxDiskCapMB: 250
)

// 3. Фоновый индексатор с произвольным источником CGImage и контекста
let snapshotter = ScreenMemorySnapshotter(
    database: memoryDB,
    interval: 10.0,
    frameProvider: { await myRenderer.latestFrame() },
    contextProvider: { ("Safari", "com.apple.Safari") }
)
snapshotter.start()

// 4. Мгновенный FTS5-поиск с подсветкой фрагментов
let hits = memoryDB.search(query: "счёт")
for hit in hits {
    print("[\(hit.sourceName)] \(hit.highlightedSnippet)")
}
```

### 2. SwiftUI-оверлеи: выделение области OCR и Spotlight-поиск Recall

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
            // Ваш видеопоток / изображение / холст
            MyFrameCanvasView()

            if showOCR {
                OCRRegionSelectionOverlay(
                    frameProvider: { await MyFrameSource.latestCGImage() },
                    onTextExtracted: { extracted in
                        print("Скопирован текст: \(extracted)")
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
                        print("Выбран снимок из \(entry.sourceName): \(entry.extractedText)")
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

## Приватность и политика хранения

- **100% на устройстве:** Распознавание текста выполняется локально на Apple Silicon через `VNRecognizeTextRequest` (`Vision.framework`), а индексация — через локальный SQLite3 FTS5 в режиме `WAL`.
- **Расположение данных по умолчанию:** `~/Library/Application Support/VisionScreenRecallKit/Memory/memory.sqlite` и сжатые JPEG-миниатюры в `thumbnails/`. Можно передать любой собственный `databaseURL` или `baseDirectoryURL` в `ScreenMemoryDatabase` (включая временные каталоги и sandbox-контейнеры).
- **Автоматическая ротация:** `pruneRetention()` удаляет записи и `.jpg`-файлы старше `retentionDays` (по умолчанию `7` дней) и удаляет самые старые снимки при превышении лимита `maxDiskCapMB` (по умолчанию `250` МБ).
- **Мгновенная очистка:** Вызов `database.clearAll()` или `snapshotter.clearAllMemory()` удаляет все записи, выполняет `VACUUM` и стирает все миниатюры с диска.

---

## Экосистема AndOnMac

`VisionScreenRecallKit` входит в открытую модульную экосистему проекта **AndOnMac**:

- [**AndOnMac**](https://github.com/V0val0x/AndOnMac) — нативное macOS-приложение на SwiftUI, VideoToolbox и Metal для зеркалирования Android, передачи файлов и AI-автоматизации
- [**MetalScrcpyKit**](https://github.com/V0val0x/MetalScrcpyKit) — аппаратный видеопайплайн scrcpy на VideoToolbox + `CAMetalLayer` до 120 Гц
- [**ADBConnectKit**](https://github.com/V0val0x/ADBConnectKit) — нативный Swift ADB-клиент, QR-сопряжение по Wi-Fi и обход изоляции через Hotspot/PAN
- [**AndroidMCPKit**](https://github.com/V0val0x/AndroidMCPKit) — MCP-сервер (Model Context Protocol) и самовосстанавливающаяся UI-автоматизация для Android
- [**VisionScreenRecallKit**](https://github.com/V0val0x/VisionScreenRecallKit) — локальный SDK для Apple Vision OCR и семантической памяти экрана SQLite FTS5 (этот репозиторий)

---

## Лицензия

MIT License © 2026 Кирилл Зайцев (Kirill Zaitsev). См. [LICENSE](./LICENSE).
