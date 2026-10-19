//
//  ScanRecusApp.swift
//  ScanRecus
//
//  Created by Gregoire Painchaud on 18/10/2026.
//

import SwiftUI
import SwiftData

@main
struct ScanRecusApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Persistence.shared)
    }
}
