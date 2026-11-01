//
//  BookShelfApp.swift
//  BookShelf
//
//  Created by Voltline on 2026/7/22.
//

import SwiftUI

@main
struct BookShelfApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--performance-regression") {
                PerformanceRegressionProbe()
            } else if ProcessInfo.processInfo.arguments.contains("--activity-live-regression") {
                ReadingActivityLiveProbe()
            } else if ProcessInfo.processInfo.arguments.contains("--library-regression") {
                LibraryRegressionProbe()
            } else if ProcessInfo.processInfo.arguments.contains("--font-regression") {
                FontRegressionProbe()
            } else if ProcessInfo.processInfo.arguments.contains("--txt-regression") {
                TXTRegressionProbe()
            } else if ProcessInfo.processInfo.arguments.contains("--fulltext-regression") {
                FullTextRegressionProbe()
            } else {
                ContentView().environmentObject(library)
            }
            #else
            ContentView()
                .environmentObject(library)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.flushPendingChanges() }
        }
    }
}
