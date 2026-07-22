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
            ContentView()
                .environmentObject(library)
        }
    }
}
