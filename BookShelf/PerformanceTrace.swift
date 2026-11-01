import os

/// Local Instruments intervals only; no analytics or network reporting.
nonisolated enum PerformanceTrace {
    static let signposter = OSSignposter(subsystem: "com.Voltline.BookShelf", category: "Performance")
}
