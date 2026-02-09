//
//  majoing3App.swift
//  majoing3
//
//  Created by Kodai Okugawa on 2026/01/27.
//

import SwiftUI
import FirebaseCore

@main
struct majoing3App: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .task {
                    await appModel.startIfNeeded()
                }
        }
    }
}
