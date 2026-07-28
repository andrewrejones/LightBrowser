//
//  BrowserExtensionManager.swift
//  LightBrowser
//
//  Created by Andrew Jones on 7/27/26.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

#if os(macOS)
import AppKit
#endif

struct InstalledWebExtension: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var resourcePath: String
    var optionsPagePath: String?
    var isEnabled = true

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case resourcePath
        case optionsPagePath
        case isEnabled
    }

    init(id: UUID, displayName: String, resourcePath: String, optionsPagePath: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.resourcePath = resourcePath
        self.optionsPagePath = optionsPagePath
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        resourcePath = try container.decode(String.self, forKey: .resourcePath)
        optionsPagePath = try container.decodeIfPresent(String.self, forKey: .optionsPagePath)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

@MainActor
final class BrowserExtensionManager: NSObject {
    static let shared = BrowserExtensionManager()

    let controller: WKWebExtensionController

    private let installedExtensionsKey = "LightBrowser.webExtensions.installed"
    fileprivate let extensionWindow = BrowserExtensionWindow()
    fileprivate let extensionTab = BrowserExtensionTab()
    private var installedExtensions: [InstalledWebExtension] = []
    private var loadedExtensionIDs = Set<UUID>()
    private var loadedExtensionContexts: [UUID: WKWebExtensionContext] = [:]
    private var managementWindow: NSWindow?
    private var optionWindows: [UUID: NSWindow] = [:]
    fileprivate weak var activeStore: BrowserStore?
    fileprivate weak var activeWebView: WKWebView?

    private override init() {
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = .default()
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        extensionWindow.manager = self
        extensionTab.manager = self
        installedExtensions = loadInstalledExtensionRecords()

        Task { @MainActor in
            await loadInstalledExtensions()
        }
    }

    func registerActiveBrowser(store: BrowserStore, webView: WKWebView) {
        activeStore = store
        activeWebView = webView
    }

    var installedExtensionRecords: [InstalledWebExtension] {
        installedExtensions
    }

    #if os(macOS)
    func installExtensionFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Install Web Extension"
        panel.prompt = "Install"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]

        panel.begin { [weak self] response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                await self?.installExtension(from: sourceURL)
            }
        }
    }

    func showManagementWindow() {
        if let managementWindow {
            managementWindow.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = BrowserExtensionManagementView(manager: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Extensions"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        managementWindow = window
    }

    func showOptions(for installedExtension: InstalledWebExtension) {
        guard let context = loadedExtensionContexts[installedExtension.id],
              let optionsPageURL = optionsPageURL(for: installedExtension, context: context) else {
            showInstallResult(title: "Options Unavailable", message: "\(installedExtension.displayName) does not expose an options page.")
            return
        }

        showOptionsWindow(for: installedExtension, context: context, optionsPageURL: optionsPageURL)
    }
    #endif

    func removeExtension(_ installedExtension: InstalledWebExtension) {
        do {
            if let context = loadedExtensionContexts[installedExtension.id] {
                try controller.unload(context)
            }

            let resourceURL = URL(fileURLWithPath: installedExtension.resourcePath)
            if FileManager.default.fileExists(atPath: resourceURL.path) {
                try FileManager.default.removeItem(at: resourceURL)
            }

            loadedExtensionContexts[installedExtension.id] = nil
            loadedExtensionIDs.remove(installedExtension.id)
            optionWindows[installedExtension.id]?.close()
            optionWindows[installedExtension.id] = nil
            installedExtensions.removeAll { $0.id == installedExtension.id }
            saveInstalledExtensionRecords()
        } catch {
            showInstallResult(title: "Extension Remove Failed", message: "\(installedExtension.displayName): \(error.localizedDescription)")
        }
    }

    func setExtension(_ installedExtension: InstalledWebExtension, isEnabled: Bool) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == installedExtension.id }),
              installedExtensions[index].isEnabled != isEnabled else {
            return
        }

        installedExtensions[index].isEnabled = isEnabled
        saveInstalledExtensionRecords()

        Task { @MainActor in
            if isEnabled {
                await loadExtension(installedExtensions[index])
            } else {
                unloadExtension(installedExtensions[index])
            }
        }
    }

    func loadInstalledExtensions() async {
        for installedExtension in installedExtensions where installedExtension.isEnabled && !loadedExtensionIDs.contains(installedExtension.id) {
            await loadExtension(installedExtension)
        }
    }

    private func installExtension(from sourceURL: URL) async {
        do {
            let installedExtension = try copyExtensionIntoAppSupport(from: sourceURL)
            installedExtensions.append(installedExtension)
            saveInstalledExtensionRecords()
            await loadExtension(installedExtension)
            showInstallResult(title: "Extension Installed", message: "Installed \(installedExtension.displayName).")
        } catch {
            showInstallResult(title: "Extension Install Failed", message: error.localizedDescription)
        }
    }

    private func loadExtension(_ installedExtension: InstalledWebExtension) async {
        guard installedExtension.isEnabled else { return }

        do {
            let resourceURL = URL(fileURLWithPath: installedExtension.resourcePath)
            let webExtension = try await WKWebExtension(resourceBaseURL: resourceURL)
            let context = WKWebExtensionContext(for: webExtension)
            updateOptionsPagePath(for: installedExtension.id, from: webExtension)
            grantRequestedPermissions(for: webExtension, context: context)
            try controller.load(context)
            loadedExtensionIDs.insert(installedExtension.id)
            loadedExtensionContexts[installedExtension.id] = context
        } catch {
            showInstallResult(title: "Extension Load Failed", message: "\(installedExtension.displayName): \(error.localizedDescription)")
        }
    }

    private func unloadExtension(_ installedExtension: InstalledWebExtension) {
        do {
            if let context = loadedExtensionContexts[installedExtension.id] {
                try controller.unload(context)
            }

            loadedExtensionContexts[installedExtension.id] = nil
            loadedExtensionIDs.remove(installedExtension.id)
            optionWindows[installedExtension.id]?.close()
            optionWindows[installedExtension.id] = nil
        } catch {
            showInstallResult(title: "Extension Disable Failed", message: "\(installedExtension.displayName): \(error.localizedDescription)")
        }
    }

    private func grantRequestedPermissions(for webExtension: WKWebExtension, context: WKWebExtensionContext) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func copyExtensionIntoAppSupport(from sourceURL: URL) throws -> InstalledWebExtension {
        let fileManager = FileManager.default
        let installID = UUID()
        let supportURL = try appSupportExtensionsURL()
        try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let sourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .localizedNameKey, .nameKey])
        let isDirectory = sourceValues.isDirectory == true
        let sourceName = sourceValues.localizedName ?? sourceValues.name ?? sourceURL.lastPathComponent
        let displayName = sourceURL.deletingPathExtension().lastPathComponent

        let destinationURL: URL
        if isDirectory {
            destinationURL = supportURL.appendingPathComponent(installID.uuidString, isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } else {
            destinationURL = supportURL
                .appendingPathComponent(installID.uuidString)
                .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "zip" : sourceURL.pathExtension)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        return InstalledWebExtension(
            id: installID,
            displayName: displayName.isEmpty ? sourceName : displayName,
            resourcePath: destinationURL.path
        )
    }

    private func appSupportExtensionsURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return baseURL
            .appendingPathComponent("LightBrowser", isDirectory: true)
            .appendingPathComponent("WebExtensions", isDirectory: true)
    }

    private func loadInstalledExtensionRecords() -> [InstalledWebExtension] {
        guard let data = UserDefaults.standard.data(forKey: installedExtensionsKey),
              let extensions = try? JSONDecoder().decode([InstalledWebExtension].self, from: data) else {
            return []
        }

        let filteredExtensions = extensions.filter { !$0.isConsentOMatic }
        let removedExtensions = extensions.filter(\.isConsentOMatic)
        for removedExtension in removedExtensions {
            let resourceURL = URL(fileURLWithPath: removedExtension.resourcePath)
            try? FileManager.default.removeItem(at: resourceURL)
        }

        if filteredExtensions.count != extensions.count,
           let data = try? JSONEncoder().encode(filteredExtensions) {
            UserDefaults.standard.set(data, forKey: installedExtensionsKey)
        }

        return filteredExtensions
    }

    private func updateOptionsPagePath(for id: UUID, from webExtension: WKWebExtension) {
        guard let optionsPagePath = manifestOptionsPagePath(from: webExtension.manifest),
              let index = installedExtensions.firstIndex(where: { $0.id == id }),
              installedExtensions[index].optionsPagePath != optionsPagePath else {
            return
        }

        installedExtensions[index].optionsPagePath = optionsPagePath
        saveInstalledExtensionRecords()
    }

    private func manifestOptionsPagePath(from manifest: [String: Any]) -> String? {
        if let optionsUI = manifest["options_ui"] as? [String: Any],
           let page = optionsUI["page"] as? String,
           !page.isEmpty {
            return page
        }

        if let optionsPage = manifest["options_page"] as? String,
           !optionsPage.isEmpty {
            return optionsPage
        }

        return nil
    }

    private func optionsPageURL(for installedExtension: InstalledWebExtension, context: WKWebExtensionContext) -> URL? {
        if let optionsPageURL = context.optionsPageURL {
            return optionsPageURL
        }

        if let optionsPagePath = installedExtension.optionsPagePath {
            return extensionResourceURL(path: optionsPagePath, context: context)
        }

        if installedExtension.displayName.localizedCaseInsensitiveContains("ublock") {
            return extensionResourceURL(path: "dashboard.html", context: context)
        }

        return nil
    }

    private func extensionResourceURL(path: String, context: WKWebExtensionContext) -> URL? {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return nil }

        let baseString = context.baseURL.absoluteString.hasSuffix("/")
            ? context.baseURL.absoluteString
            : "\(context.baseURL.absoluteString)/"
        guard let baseURL = URL(string: baseString) else { return nil }
        return URL(string: normalizedPath, relativeTo: baseURL)?.absoluteURL
    }

    private func saveInstalledExtensionRecords() {
        guard let data = try? JSONEncoder().encode(installedExtensions) else { return }
        UserDefaults.standard.set(data, forKey: installedExtensionsKey)
    }

    private func showInstallResult(title: String, message: String) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #else
        print("\(title): \(message)")
        #endif
    }

    private func extensionRecord(for context: WKWebExtensionContext) -> InstalledWebExtension? {
        guard let id = loadedExtensionContexts.first(where: { $0.value === context })?.key else {
            return nil
        }

        return installedExtensions.first { $0.id == id }
    }

    #if os(macOS)
    private func showOptionsWindow(for installedExtension: InstalledWebExtension, context: WKWebExtensionContext, optionsPageURL: URL) {
        if let optionWindow = optionWindows[installedExtension.id] {
            optionWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard let configuration = context.webViewConfiguration else {
            showInstallResult(title: "Options Unavailable", message: "\(installedExtension.displayName) could not create an extension web view configuration.")
            return
        }

        let contentView = BrowserExtensionOptionsView(configuration: configuration, url: optionsPageURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(installedExtension.displayName) Options"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        optionWindows[installedExtension.id] = window
    }
    #endif
}

#if os(macOS)
extension BrowserExtensionManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === managementWindow {
            managementWindow = nil
        } else if let closingWindow = notification.object as? NSWindow,
                  let id = optionWindows.first(where: { $0.value === closingWindow })?.key {
            optionWindows[id] = nil
        }
    }
}

private extension InstalledWebExtension {
    var isConsentOMatic: Bool {
        let name = displayName.lowercased()
        return name.contains("consent-o-matic") || name.contains("consent o matic")
    }
}

private struct BrowserExtensionManagementView: View {
    let manager: BrowserExtensionManager
    @State private var installedExtensions: [InstalledWebExtension]

    init(manager: BrowserExtensionManager) {
        self.manager = manager
        _installedExtensions = State(initialValue: manager.installedExtensionRecords)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Extensions")
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if installedExtensions.isEmpty {
                ContentUnavailableView("No Extensions Installed", systemImage: "puzzlepiece.extension")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(installedExtensions) { installedExtension in
                        HStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.extension")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(installedExtension.displayName)
                                    .lineLimit(1)
                                Text(URL(fileURLWithPath: installedExtension.resourcePath).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Toggle("Enabled", isOn: Binding(
                                get: { installedExtension.isEnabled },
                                set: { newValue in
                                    manager.setExtension(installedExtension, isEnabled: newValue)
                                    installedExtensions = manager.installedExtensionRecords
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help(installedExtension.isEnabled ? "Disable Extension" : "Enable Extension")

                            Button("Options") {
                                manager.showOptions(for: installedExtension)
                            }
                            .disabled(!installedExtension.isEnabled)

                            Button("Remove") {
                                manager.removeExtension(installedExtension)
                                installedExtensions = manager.installedExtensionRecords
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

private struct BrowserExtensionOptionsView: NSViewRepresentable {
    let configuration: WKWebViewConfiguration
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard nsView.url != url else { return }
        nsView.load(URLRequest(url: url))
    }
}
#endif

extension BrowserExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        activeWebView == nil ? [] : [extensionWindow]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        activeWebView == nil ? nil : extensionWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let url = configuration.url
        if url?.scheme == "webkit-extension" {
            completionHandler(nil, nil)
            return
        }

        activeStore?.newTab(openInBackground: !configuration.shouldBeActive, url: url)
        completionHandler(extensionTab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler(urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
    }
}

private final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var manager: BrowserExtensionManager?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let tab = manager?.extensionTab else { return [] }
        return [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        manager?.extensionTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }
}

private final class BrowserExtensionTab: NSObject, WKWebExtensionTab {
    weak var manager: BrowserExtensionManager?

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        manager?.activeWebView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        manager?.extensionWindow
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        manager?.activeWebView?.url ?? manager?.activeStore?.selectedTab?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        manager?.activeStore?.selectedTab?.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        manager?.activeWebView?.title ?? manager?.activeStore?.selectedTab?.title
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(manager?.activeWebView?.isLoading ?? false)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        manager?.activeWebView?.bounds.size ?? .zero
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.activeStore?.closeSelectedTab()
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.activeStore?.setSelectedTabURL(url)
        manager?.activeWebView?.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.activeWebView?.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.activeWebView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        manager?.activeWebView?.goForward()
        completionHandler(nil)
    }
}
