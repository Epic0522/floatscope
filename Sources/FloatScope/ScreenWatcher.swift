import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum CaptureMode {
    case fullScreen
}

enum WatchIntervalMode: Equatable {
    case fixed(TimeInterval)
    case random(TimeInterval, TimeInterval)

    var label: String {
        switch self {
        case .fixed(let interval):
            "Every \(Int(interval))s"
        case .random(let min, let max):
            "Random \(Int(min))-\(Int(max))s"
        }
    }
}

@MainActor
final class ScreenWatcher {
    private struct CaptureEntry {
        let url: URL
        let date: Date
    }

    private var rollingTask: Task<Void, Never>?
    private var recentCaptures: [CaptureEntry] = []

    func startRollingCache() {
        guard rollingTask == nil, hasPermission() else { return }
        rollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                do {
                    let url = try await self.capture()
                    self.remember(url)
                } catch {
                    // The rolling cache is opportunistic; explicit captures still report errors.
                }
            }
        }
    }

    func stopRollingCache() {
        rollingTask?.cancel()
        rollingTask = nil
    }

    func setRollingCacheEnabled(_ enabled: Bool) {
        if enabled {
            startRollingCache()
        } else {
            stopRollingCache()
            clearRecentCaptures()
        }
    }

    func captureRecentOrFresh(maxAge: TimeInterval = 12) async throws -> URL {
        if let recent = recentCaptures.last,
           Date().timeIntervalSince(recent.date) <= maxAge {
            return recent.url
        }
        let url = try await capture()
        remember(url)
        return url
    }

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func capture(_ mode: CaptureMode = .fullScreen) async throws -> URL {
        if !hasPermission() {
            requestPermission()
            throw ScreenWatcherError.permissionNeeded
        }

        let content = try await SCShareableContent.current
        let displayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ScreenWatcherError.captureFailed
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true

        let config = SCStreamConfiguration()
        let maxWidth = 1920
        if display.width > maxWidth {
            config.width = maxWidth
            config.height = max(1, Int(Double(display.height) * Double(maxWidth) / Double(display.width)))
        } else {
            config.width = display.width
            config.height = display.height
        }
        config.showsCursor = true
        config.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let data = try autoreleasepool {
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.76]) else {
                throw ScreenWatcherError.encodeFailed
            }
            return data
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloatScope", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).jpg")
        try data.write(to: file)
        return file
    }

    private func remember(_ url: URL) {
        recentCaptures.append(CaptureEntry(url: url, date: Date()))
        if recentCaptures.count > 5 {
            let removed = recentCaptures.prefix(recentCaptures.count - 5)
            removed.forEach { try? FileManager.default.removeItem(at: $0.url) }
            recentCaptures.removeFirst(recentCaptures.count - 5)
        }
    }

    private func clearRecentCaptures() {
        recentCaptures.forEach { try? FileManager.default.removeItem(at: $0.url) }
        recentCaptures.removeAll()
    }
}

enum ScreenWatcherError: LocalizedError {
    case permissionNeeded
    case captureFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .permissionNeeded: "Screen recording permission is needed."
        case .captureFailed: "Unable to capture the screen."
        case .encodeFailed: "Unable to encode screenshot."
        }
    }
}

@MainActor
final class WatchScheduler {
    private var task: Task<Void, Never>?
    private let watcher: ScreenWatcher
    private let onCapture: (Result<URL, Error>) -> Void

    init(watcher: ScreenWatcher, onCapture: @escaping (Result<URL, Error>) -> Void) {
        self.watcher = watcher
        self.onCapture = onCapture
    }

    func start(intervalMode: WatchIntervalMode) {
        stop()
        task = Task { [watcher, onCapture] in
            while !Task.isCancelled {
                let delay = Self.nextDelay(for: intervalMode)
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                do {
                    let url = try await watcher.capture()
                    onCapture(.success(url))
                } catch {
                    onCapture(.failure(error))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func nextDelay(for mode: WatchIntervalMode) -> TimeInterval {
        switch mode {
        case .fixed(let interval):
            Swift.max(5, interval)
        case .random(let minimum, let maximum):
            Double.random(in: Swift.max(5, minimum)...Swift.max(maximum, minimum + 1))
        }
    }
}
