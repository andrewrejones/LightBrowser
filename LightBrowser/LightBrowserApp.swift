//
//  LightBrowserApp.swift
//  LightBrowser
//
//  Created by Andrew Jones on 7/27/26.
//

import SwiftUI

@main
struct LightBrowserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            BrowserTabCommands()
            BrowserPasswordCommands()
            BrowserExtensionCommands()
        }
    }
}

private struct BrowserTabCommands: Commands {
    @FocusedValue(BrowserStore.self) private var store

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                store?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(store == nil)
        }

        CommandGroup(before: .windowArrangement) {
            Button("Search Open Tabs") {
                store?.focusTabSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(store == nil)

            Button("Previous Tab") {
                store?.selectPreviousTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled((store?.tabs.count ?? 0) <= 1)

            Button("Next Tab") {
                store?.selectNextTab()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled((store?.tabs.count ?? 0) <= 1)

            Button("Close Tab") {
                store?.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled((store?.tabs.count ?? 0) <= 1)
        }
    }
}

private struct BrowserPasswordCommands: Commands {
    @FocusedValue(BrowserStore.self) private var store

    var body: some Commands {
        CommandMenu("Passwords") {
            Button("Open Passwords") {
                BrowserSystemActions.openPasswords()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button("Open Current Page in Safari for Passkey Login") {
                store?.openSelectedPageInSafari()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift, .option])
            .disabled(store == nil)
        }
    }
}

private struct BrowserExtensionCommands: Commands {
    var body: some Commands {
        CommandMenu("Extensions") {
            Button("Install Extension...") {
                BrowserExtensionManager.shared.installExtensionFromOpenPanel()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("Manage Extensions...") {
                BrowserExtensionManager.shared.showManagementWindow()
            }
        }
    }
}
