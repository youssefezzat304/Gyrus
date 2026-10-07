//
//  GyrusApp.swift
//  Gyrus
//
//  Created by Youssef Abdelrahim on 07.10.26.
//

import SwiftUI

@main
struct GyrusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
