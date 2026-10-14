//
//  Clauto_EditorApp.swift
//  Clauto Editor
//
//  Created by Nathan on 10/13/26.
//

import SwiftUI

@main
struct Clauto_EditorApp: App {
    @State private var store = EditorStore()
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 640)
                .task {
                    if let path = ProcessInfo.processInfo.environment["CLAUTO_OPEN_PROJECT"] {
                        await store.open(URL(fileURLWithPath: path, isDirectory: true))
                    } else {
                        await store.restore()
                    }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.enabled)
            }
        }
        Settings { SetupView(store: store).frame(width: 640, height: 620) }
    }
}
