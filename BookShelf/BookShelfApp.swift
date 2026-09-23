//
//  BookShelfApp.swift
//  BookShelf
//
//  Created by Voltline on 2026/7/22.
//

import SwiftUI

@main
struct BookShelfApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--font-regression") {
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
    }
}
