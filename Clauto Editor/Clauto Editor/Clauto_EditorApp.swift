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
    @NSApplicationDelegateAdaptor(ClautoAppDelegate.self) private var delegate

    init() { ClautoFonts.register() }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, initialProjectTab: ProcessInfo.processInfo.environment["CLAUTO_PROJECT_TAB"] ?? "Brief")
                .frame(minWidth: 900, minHeight: 640)
                .task {
                    delegate.store = store
                    #if DEBUG
                    // App-host unit tests use synthetic windows and media. Do
                    // not restore a user's recent projects into that test host.
                    if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #endif
                    if let path = ProcessInfo.processInfo.environment["CLAUTO_OPEN_PROJECT"] {
                        await store.open(URL(fileURLWithPath: path, isDirectory: true))
                    } else {
                        await store.restore()
                    }
                }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(!updater.enabled)
            }
        }
        Settings {
            VStack(spacing: 0) {
                HStack { ClautoWindowControls(onRail: false); Spacer(); Text("Clauto workspace").font(ClautoDesign.type(13, weight: .semibold)) }
                    .padding(.horizontal, 24).padding(.vertical, 14).background(ClautoDesign.paper)
                ClautoRule()
                SetupView(store: store)
            }.frame(width: 680, height: 680).foregroundStyle(ClautoDesign.ink).preferredColorScheme(ClautoThemeStore.shared.preferredColorScheme)
        }.windowStyle(.hiddenTitleBar)
    }
}
