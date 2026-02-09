//
//  majoing3App.swift
//  majoing3
//
//  Created by Kodai Okugawa on 2026/01/27.
//

import SwiftUI
import UIKit
import FirebaseCore

// AppDelegateでFirebaseを初期化
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        print("[AppDelegate] didFinishLaunchingWithOptions called")
        
        // GoogleService-Info.plist の存在確認
        if let plistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") {
            print("[AppDelegate] GoogleService-Info.plist found at: \(plistPath)")
            FirebaseApp.configure()
            print("[AppDelegate] Firebase configured successfully")
        } else {
            print("[AppDelegate] ERROR: GoogleService-Info.plist not found in bundle")
        }
        
        return true
    }
}

@main
struct majoing3App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
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
