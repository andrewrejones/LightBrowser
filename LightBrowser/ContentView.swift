//
//  ContentView.swift
//  LightBrowser
//
//  Created by Andrew Jones on 7/27/26.
//

import SwiftUI
import Observation
import WebKit
import UniformTypeIdentifiers
import Darwin

#if os(macOS)
import AppKit
private typealias BrowserPlatformView = NSView
#else
import UIKit
private typealias BrowserPlatformView = UIView
#endif

enum BrowserSystemActions {
    static func openPasswords() {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        let candidateURLs = [
            URL(fileURLWithPath: "/System/Applications/Passwords.app"),
            URL(fileURLWithPath: "/Applications/Passwords.app")
        ]

        if let appURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            workspace.open(appURL)
            return
        }

        if let preferencesURL = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            workspace.open(preferencesURL)
        }
        #endif
    }

    static func openInSafari(_ url: URL) {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        let candidateURLs = [
            URL(fileURLWithPath: "/System/Applications/Safari.app"),
            URL(fileURLWithPath: "/Applications/Safari.app")
        ]

        guard let safariURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            workspace.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        workspace.open([url], withApplicationAt: safariURL, configuration: configuration)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

private enum BrowserDefaults {
    static let homeURL = URL(string: "https://duckduckgo.com")!
    static let clipboardURL = URL(string: "lightbrowser://clipboard")!
    static let desktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}

struct BrowserTab: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: URL
    var faviconData: Data?
    var temporaryExpiresAt: Date?
    var scrollPosition: CGPoint
    var isPinned: Bool
    var groupID: UUID?
    var isIncognito: Bool
    var searchText: String
    var isClipboard: Bool

    var isTemporary: Bool {
        temporaryExpiresAt != nil
    }

    init(id: UUID = UUID(), title: String = "New Tab", url: URL = BrowserDefaults.homeURL, faviconData: Data? = nil, temporaryExpiresAt: Date? = nil, scrollPosition: CGPoint = .zero, isPinned: Bool = false, groupID: UUID? = nil, isIncognito: Bool = false, searchText: String = "", isClipboard: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.faviconData = faviconData
        self.temporaryExpiresAt = temporaryExpiresAt
        self.scrollPosition = scrollPosition
        self.isPinned = isPinned
        self.groupID = groupID
        self.isIncognito = isIncognito
        self.searchText = searchText
        self.isClipboard = isClipboard
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case faviconData
        case temporaryExpiresAt
        case scrollPosition
        case isPinned
        case groupID
        case isIncognito
        case searchText
        case isClipboard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        faviconData = try container.decodeIfPresent(Data.self, forKey: .faviconData)
        temporaryExpiresAt = try container.decodeIfPresent(Date.self, forKey: .temporaryExpiresAt)
        scrollPosition = try container.decodeIfPresent(CGPoint.self, forKey: .scrollPosition) ?? .zero
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        isIncognito = try container.decodeIfPresent(Bool.self, forKey: .isIncognito) ?? false
        searchText = try container.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        isClipboard = try container.decodeIfPresent(Bool.self, forKey: .isClipboard) ?? false
    }
}

struct BrowserTabGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var copiedAt: Date

    init(id: UUID = UUID(), text: String, copiedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
    }

    var linkURL: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        if let url = URL(string: trimmed),
           url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            return url
        }

        guard trimmed.contains("."),
              !trimmed.contains("@"),
              let url = URL(string: "https://\(trimmed)") else {
            return nil
        }

        return url
    }
}

@MainActor
@Observable
final class BrowserStore {
    var tabs: [BrowserTab] = []
    var tabGroups: [BrowserTabGroup] = []
    var selectedTabID: BrowserTab.ID?
    var addressText = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var estimatedProgress = 0.0
    var pageErrorMessage: String?
    var pageRecoveryURL: URL?
    var downloadMessage: String?
    var tabSearchFocusRequest = 0
    var tabsOpenedToday = 0
    var lastPageLoadDuration: TimeInterval?
    var memoryUsageBytes: UInt64 = 0
    var clipboardItems: [ClipboardHistoryItem] = []

    private let sessionKey = "LightBrowser.session.tabs"
    private let groupsKey = "LightBrowser.session.tabGroups"
    private let selectedTabKey = "LightBrowser.session.selectedTabID"
    private let tabsOpenedTodayKey = "LightBrowser.metrics.tabsOpenedToday"
    private let tabsOpenedTodayDateKey = "LightBrowser.metrics.tabsOpenedTodayDate"
    private let clipboardHistoryKey = "LightBrowser.clipboard.history"
    private let temporaryTabLifetime: TimeInterval = 24 * 60 * 60
    private let cachedWebViewLifetime: TimeInterval = 60 * 60
    private let clipboardHistoryLimit = 25
    @ObservationIgnored private let webCoordinator = BrowserWebCoordinator()
    @ObservationIgnored private let downloadManager = BrowserDownloadManager()
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var webViews: [BrowserTab.ID: WKWebView] = [:]
    @ObservationIgnored private var webViewTabIDs: [ObjectIdentifier: BrowserTab.ID] = [:]
    @ObservationIgnored private var webViewLastUsed: [BrowserTab.ID: Date] = [:]
    @ObservationIgnored private var requestedURLs: [BrowserTab.ID: URL] = [:]
    @ObservationIgnored private var loadStartTimes: [BrowserTab.ID: Date] = [:]
    @ObservationIgnored private var contentRuleList: WKContentRuleList?
    @ObservationIgnored private var installedContentRuleListWebViewIDs = Set<ObjectIdentifier>()
    @ObservationIgnored private var temporaryTabExpirationTimer: Timer?
    @ObservationIgnored private var cachedWebViewCleanupTimer: Timer?
    @ObservationIgnored private var metricsTimer: Timer?
    @ObservationIgnored private var clipboardMonitorTimer: Timer?
    @ObservationIgnored private var lastPasteboardChangeCount = 0

    init() {
        if let savedGroupData = UserDefaults.standard.data(forKey: groupsKey),
           let savedGroups = try? JSONDecoder().decode([BrowserTabGroup].self, from: savedGroupData) {
            tabGroups = savedGroups
        } else {
            tabGroups = []
        }

        if let savedData = UserDefaults.standard.data(forKey: sessionKey),
           let savedTabs = try? JSONDecoder().decode([BrowserTab].self, from: savedData),
           !savedTabs.filter(\.isSessionRestorable).isEmpty {
            let validGroupIDs = Set(tabGroups.map(\.id))
            let restorableTabs = savedTabs
                .filter(\.isSessionRestorable)
                .map { tab in
                    var tab = tab
                    if tab.isTemporary {
                        tab.isPinned = false
                        tab.groupID = nil
                    } else if tab.isPinned || tab.groupID.map({ !validGroupIDs.contains($0) }) == true {
                        tab.groupID = nil
                    }
                    return tab
                }
            tabs = restorableTabs
            selectedTabID = UUID(uuidString: UserDefaults.standard.string(forKey: selectedTabKey) ?? "") ?? restorableTabs.first?.id
            if !tabs.contains(where: { $0.id == selectedTabID }) {
                selectedTabID = tabs.first?.id
            }
        } else {
            let initialTab = BrowserTab()
            tabs = [initialTab]
            selectedTabID = initialTab.id
        }

        ensureClipboardTabExists()
        addressText = selectedTab?.url.absoluteString ?? ""
        webCoordinator.store = self
        loadDailyTabCount()
        loadClipboardHistory()
        refreshMemoryUsage()
        installContentBlockers()
        startTemporaryTabExpirationTimer()
        startCachedWebViewCleanupTimer()
        startMetricsTimer()
        startClipboardMonitor()
        closeExpiredTemporaryTabs()
    }

    deinit {
        temporaryTabExpirationTimer?.invalidate()
        cachedWebViewCleanupTimer?.invalidate()
        metricsTimer?.invalidate()
        clipboardMonitorTimer?.invalidate()
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var regularTabs: [BrowserTab] {
        tabs.filter { !$0.isTemporary && !$0.isIncognito && !$0.isClipboard }
    }

    var pinnedTabs: [BrowserTab] {
        tabs.filter { !$0.isTemporary && !$0.isIncognito && !$0.isClipboard && $0.isPinned }
    }

    var ungroupedTabs: [BrowserTab] {
        tabs.filter { !$0.isTemporary && !$0.isIncognito && !$0.isClipboard && !$0.isPinned && $0.groupID == nil }
    }

    var temporaryTabs: [BrowserTab] {
        tabs.filter { $0.isTemporary && !$0.isIncognito && !$0.isClipboard }
    }

    var incognitoTabs: [BrowserTab] {
        tabs.filter { $0.isIncognito && !$0.isClipboard }
    }

    var clipboardTabs: [BrowserTab] {
        tabs.filter(\.isClipboard)
    }

    func tabs(in group: BrowserTabGroup) -> [BrowserTab] {
        tabs.filter { !$0.isTemporary && !$0.isIncognito && !$0.isClipboard && !$0.isPinned && $0.groupID == group.id }
    }

    func pinnedTabs(matching query: String) -> [BrowserTab] {
        pinnedTabs.filter { $0.matchesSearch(query) }
    }

    func ungroupedTabs(matching query: String) -> [BrowserTab] {
        ungroupedTabs.filter { $0.matchesSearch(query) }
    }

    func temporaryTabs(matching query: String) -> [BrowserTab] {
        temporaryTabs.filter { $0.matchesSearch(query) }
    }

    func incognitoTabs(matching query: String) -> [BrowserTab] {
        incognitoTabs.filter { $0.matchesSearch(query) }
    }

    func clipboardTabs(matching query: String) -> [BrowserTab] {
        clipboardTabs.filter { $0.matchesSearch(query) }
    }

    func tabs(in group: BrowserTabGroup, matching query: String) -> [BrowserTab] {
        tabs(in: group).filter { $0.matchesSearch(query) }
    }

    fileprivate func displaySelectedTab(in container: BrowserPlatformView) {
        guard let tab = selectedTab else { return }
        let selectedWebView = cachedWebView(for: tab)
        let didChangeActiveWebView = webView !== selectedWebView

        if didChangeActiveWebView {
            webView = selectedWebView
        }

        if selectedWebView.superview !== container {
            selectedWebView.removeFromSuperview()
            embed(selectedWebView, in: container)
        }

        for subview in container.subviews where subview !== selectedWebView {
            subview.removeFromSuperview()
        }

        if didChangeActiveWebView {
            webCoordinator.observe(selectedWebView)
            BrowserExtensionManager.shared.registerActiveBrowser(store: self, webView: selectedWebView)
            installCompiledContentRuleListIfNeeded(on: selectedWebView)
        }
        loadSelectedTabIfNeeded()
        ensureDisplayedTabIsLoadingIfBlank(tab, webView: selectedWebView)
        if didChangeActiveWebView {
            updateNavigationState(from: selectedWebView)
            unloadStaleCachedWebViews()
        }
    }

    private func embed(_ webView: WKWebView, in container: BrowserPlatformView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func ensureDisplayedTabIsLoadingIfBlank(_ tab: BrowserTab, webView: WKWebView) {
        guard webView.url == nil,
              requestedURLs[tab.id] == nil,
              tab.url.isLoadableInMainBrowser else {
            return
        }

        requestedURLs[tab.id] = tab.url
        webView.load(URLRequest(url: tab.url))
    }

    func selectTab(id: BrowserTab.ID?) {
        guard let id, let tab = tabs.first(where: { $0.id == id }) else { return }
        guard id != selectedTabID else { return }
        prepareActiveTabForBackground()
        selectedTabID = id
        addressText = tab.url.absoluteString
        saveSession()
    }

    func select(_ tab: BrowserTab) {
        selectTab(id: tab.id)
    }

    func focusTabSearch() {
        tabSearchFocusRequest += 1
    }

    func selectPreviousTab() {
        selectAdjacentTab(offset: -1)
    }

    func selectNextTab() {
        selectAdjacentTab(offset: 1)
    }

    func newTab(openInBackground: Bool = false, url: URL? = nil) {
        let targetURL = url ?? BrowserDefaults.homeURL
        let tab = BrowserTab(url: targetURL)
        add(tab, openInBackground: openInBackground)
    }

    func newTab(in group: BrowserTabGroup, openInBackground: Bool = false, url: URL? = nil) {
        let targetURL = url ?? BrowserDefaults.homeURL
        let tab = BrowserTab(url: targetURL, groupID: group.id)
        add(tab, openInBackground: openInBackground)
    }

    func newTemporaryTab(openInBackground: Bool = false, url: URL? = nil) {
        let targetURL = url ?? BrowserDefaults.homeURL
        let tab = BrowserTab(url: targetURL, temporaryExpiresAt: Date().addingTimeInterval(temporaryTabLifetime))
        add(tab, openInBackground: openInBackground)
    }

    func newIncognitoTab(openInBackground: Bool = false, url: URL? = nil) {
        let targetURL = url ?? BrowserDefaults.homeURL
        let tab = BrowserTab(url: targetURL, isIncognito: true)
        add(tab, openInBackground: openInBackground)
    }

    func openClipboardTab() {
        if let clipboardTab = tabs.first(where: \.isClipboard) {
            select(clipboardTab)
            return
        }

        let tab = BrowserTab(title: "Clipboard", url: BrowserDefaults.clipboardURL, isClipboard: true)
        add(tab)
    }

    private func ensureClipboardTabExists() {
        guard !tabs.contains(where: \.isClipboard) else { return }
        tabs.append(BrowserTab(title: "Clipboard", url: BrowserDefaults.clipboardURL, isClipboard: true))
    }

    func newTabInSelectedContext(openInBackground: Bool = false, url: URL? = nil) {
        let targetURL = url ?? BrowserDefaults.homeURL
        guard let selectedTab else {
            newTab(openInBackground: openInBackground, url: targetURL)
            return
        }

        if selectedTab.isIncognito {
            newIncognitoTab(openInBackground: openInBackground, url: targetURL)
        } else if selectedTab.isTemporary {
            newTemporaryTab(openInBackground: openInBackground, url: targetURL)
        } else if let groupID = selectedTab.groupID,
                  tabGroups.contains(where: { $0.id == groupID }) {
            let tab = BrowserTab(url: targetURL, groupID: groupID)
            add(tab, openInBackground: openInBackground)
        } else {
            newTab(openInBackground: openInBackground, url: targetURL)
        }
    }

    func duplicate(_ tab: BrowserTab, openInBackground: Bool = false) {
        let temporaryExpiresAt = tab.isTemporary ? Date().addingTimeInterval(temporaryTabLifetime) : nil
        let duplicate = BrowserTab(title: tab.title, url: tab.url, faviconData: tab.faviconData, temporaryExpiresAt: temporaryExpiresAt, scrollPosition: tab.scrollPosition, isPinned: tab.isPinned, groupID: tab.groupID, isIncognito: tab.isIncognito, searchText: tab.searchText)
        add(duplicate, openInBackground: openInBackground)
    }

    func duplicateSelectedTab(openInBackground: Bool = false) {
        guard let selectedTab else { return }
        duplicate(selectedTab, openInBackground: openInBackground)
    }

    private func selectAdjacentTab(offset: Int) {
        let orderedTabs = sidebarOrderedTabs
        guard orderedTabs.count > 1 else { return }

        let currentIndex = selectedTabID.flatMap { selectedID in
            orderedTabs.firstIndex { $0.id == selectedID }
        } ?? 0

        let nextIndex = (currentIndex + offset + orderedTabs.count) % orderedTabs.count
        select(orderedTabs[nextIndex])
    }

    private var sidebarOrderedTabs: [BrowserTab] {
        pinnedTabs
            + ungroupedTabs
            + tabGroups.flatMap { tabs(in: $0) }
            + incognitoTabs
            + temporaryTabs
    }

    private func add(_ tab: BrowserTab, openInBackground: Bool = false) {
        tabs.append(tab)
        recordTabOpened()

        if !openInBackground {
            prepareActiveTabForBackground()
            selectedTabID = tab.id
            addressText = tab.url.absoluteString
        }

        saveSession()
    }

    func close(_ tab: BrowserTab) {
        guard !tab.isClipboard else { return }
        guard tabs.count > 1 else { return }
        let wasSelected = tab.id == selectedTabID
        let orderedTabsBeforeClose = sidebarOrderedTabs
        let closedTabIndex = orderedTabsBeforeClose.firstIndex { $0.id == tab.id }
        if wasSelected {
            prepareActiveTabForBackground()
        }
        removeCachedWebView(for: tab.id)
        tabs.removeAll { $0.id == tab.id }

        if wasSelected {
            selectedTabID = replacementSelectedTabID(afterClosingTabAt: closedTabIndex)
            addressText = selectedTab?.url.absoluteString ?? ""
        }

        saveSession()
    }

    func closeSelectedTab() {
        guard let selectedTab else { return }
        close(selectedTab)
    }

    private func replacementSelectedTabID(afterClosingTabAt closedTabIndex: Int?) -> BrowserTab.ID? {
        let orderedTabs = sidebarOrderedTabs
        guard !orderedTabs.isEmpty else {
            let tab = BrowserTab()
            tabs.append(tab)
            recordTabOpened()
            return tab.id
        }

        guard let closedTabIndex else {
            return orderedTabs.last?.id
        }

        let replacementIndex = min(closedTabIndex, orderedTabs.count - 1)
        return orderedTabs[replacementIndex].id
    }

    func createGroup() {
        let number = tabGroups.count + 1
        tabGroups.append(BrowserTabGroup(name: "Group \(number)"))
        saveSession()
    }

    func deleteGroup(_ group: BrowserTabGroup) {
        tabGroups.removeAll { $0.id == group.id }
        for index in tabs.indices where tabs[index].groupID == group.id {
            tabs[index].groupID = nil
        }
        saveSession()
    }

    func renameGroup(_ group: BrowserTabGroup, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = tabGroups.firstIndex(where: { $0.id == group.id }) else {
            return
        }

        tabGroups[index].name = trimmedName
        saveSession()
    }

    func setPinned(_ isPinned: Bool, for tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }),
              !tabs[index].isTemporary,
              !tabs[index].isIncognito,
              !tabs[index].isClipboard else {
            return
        }

        tabs[index].isPinned = isPinned
        if isPinned {
            tabs[index].groupID = nil
        }
        saveSession()
    }

    func moveTab(_ tab: BrowserTab, to group: BrowserTabGroup?) {
        moveTab(id: tab.id, toGroupID: group?.id)
    }

    func moveTab(id tabID: BrowserTab.ID, toGroupID groupID: BrowserTabGroup.ID?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              !tabs[index].isTemporary,
              !tabs[index].isIncognito,
              !tabs[index].isClipboard else {
            return
        }

        if let groupID, !tabGroups.contains(where: { $0.id == groupID }) {
            return
        }

        tabs[index].isPinned = false
        tabs[index].groupID = groupID
        saveSession()
    }

    func submitAddress() {
        guard let url = resolvedURL(from: addressText) else { return }
        convertSelectedClipboardTabToBrowserTabIfNeeded(url: url)
        setSelectedTabURL(url)
        load(url)
    }

    private func convertSelectedClipboardTabToBrowserTabIfNeeded(url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
              tabs[index].isClipboard else {
            return
        }

        tabs[index].isClipboard = false
        tabs[index].title = displayTitle(for: url)
        tabs[index].url = url
        saveSession()
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    private func loadSelectedTabIfNeeded() {
        guard let url = selectedTab?.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        guard url.isLoadableInMainBrowser else {
            showPageError(BrowserNavigationError.unsupportedInternalURL)
            return
        }

        if webView?.url == url {
            if let webView {
                restoreScrollPositionIfNeeded(in: webView)
            }
            return
        }

        guard let selectedTabID else { return }
        guard requestedURLs[selectedTabID] != url else { return }
        requestedURLs[selectedTabID] = url
        webView?.load(URLRequest(url: url))
    }

    private func prepareActiveTabForBackground() {
        saveCurrentScrollPosition()
        if let selectedTabID {
            webViewLastUsed[selectedTabID] = Date()
        }
        if let selectedTabID {
            requestedURLs[selectedTabID] = nil
        }
    }

    private func cachedWebView(for tab: BrowserTab) -> WKWebView {
        if let cachedWebView = webViews[tab.id] {
            return cachedWebView
        }

        let cachedWebView = WKWebView(frame: .zero, configuration: browserConfiguration(isIncognito: tab.isIncognito))
        configure(cachedWebView, for: tab.id)
        webViews[tab.id] = cachedWebView
        webViewLastUsed[tab.id] = Date()
        return cachedWebView
    }

    private func configure(_ webView: WKWebView, for tabID: BrowserTab.ID) {
        webView.customUserAgent = BrowserDefaults.desktopSafariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = webCoordinator
        webView.uiDelegate = webCoordinator
        webViewTabIDs[ObjectIdentifier(webView)] = tabID
        installCompiledContentRuleListIfNeeded(on: webView)
    }

    private func removeCachedWebView(for tabID: BrowserTab.ID) {
        guard let cachedWebView = webViews.removeValue(forKey: tabID) else { return }
        cachedWebView.stopLoading()
        cachedWebView.removeFromSuperview()
        let identifier = ObjectIdentifier(cachedWebView)
        webViewTabIDs[identifier] = nil
        installedContentRuleListWebViewIDs.remove(identifier)
        webViewLastUsed[tabID] = nil
        if webView === cachedWebView {
            webView = nil
        }
    }

    private func unloadStaleCachedWebViews(now: Date = Date()) {
        guard let selectedTabID else { return }
        let staleTabIDs = webViewLastUsed.compactMap { tabID, lastUsed in
            tabID != selectedTabID && now.timeIntervalSince(lastUsed) >= cachedWebViewLifetime ? tabID : nil
        }

        for tabID in staleTabIDs {
            removeCachedWebView(for: tabID)
        }
    }

    private func saveCurrentScrollPosition() {
        guard let webView,
              let selectedTabID else {
            return
        }

        let tabID = selectedTabID
        let script = "[window.scrollX || window.pageXOffset || 0, window.scrollY || window.pageYOffset || 0]"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let coordinates = result as? [NSNumber]
            let x = coordinates?.first?.doubleValue ?? 0
            let y = coordinates?.dropFirst().first?.doubleValue ?? 0

            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.tabs.firstIndex(where: { $0.id == tabID }) else {
                    return
                }

                let scrollPosition = CGPoint(x: x, y: y)
                guard self.tabs[index].scrollPosition != scrollPosition else { return }
                self.tabs[index].scrollPosition = scrollPosition
                self.saveSession()
            }
        }
    }

    private func restoreScrollPositionIfNeeded(in webView: WKWebView) {
        guard let scrollPosition = selectedTab?.scrollPosition,
              scrollPosition != .zero else {
            return
        }

        let x = Int(scrollPosition.x)
        let y = Int(scrollPosition.y)
        let script = "window.scrollTo(\(x), \(y))"
        webView.evaluateJavaScript(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak webView] in
            webView?.evaluateJavaScript(script)
        }
    }

    func setSelectedTabURL(_ url: URL, title: String? = nil) {
        guard url.isRestorableBrowserURL else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let resolvedTitle = cleanTitle(title, fallbackURL: url)
        if let selectedTabID {
            requestedURLs[selectedTabID] = nil
        }
        updateTab(at: index, url: url, title: resolvedTitle)
    }

    func setTabURL(_ url: URL, title: String? = nil, for tabID: BrowserTab.ID?) {
        guard url.isRestorableBrowserURL,
              let tabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let resolvedTitle = cleanTitle(title, fallbackURL: url)
        if tabID == selectedTabID {
            requestedURLs[tabID] = nil
        }
        updateTab(at: index, url: url, title: resolvedTitle, updateAddress: tabID == selectedTabID)
    }

    func beginNavigation(to url: URL) {
        guard url.isRestorableBrowserURL else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        if tabs[index].url != url {
            tabs[index].scrollPosition = .zero
        }
        updateTab(at: index, url: url, title: displayTitle(for: url))
        isLoading = true
        estimatedProgress = 0
    }

    func beginNavigation(to url: URL, from webView: WKWebView) {
        guard url.isRestorableBrowserURL else { return }
        guard let tabID = tabID(for: webView),
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        if tabs[index].url != url {
            tabs[index].scrollPosition = .zero
        }
        updateTab(at: index, url: url, title: displayTitle(for: url), updateAddress: tabID == selectedTabID)
        loadStartTimes[tabID] = Date()

        guard self.webView === webView else { return }
        isLoading = true
        estimatedProgress = 0
    }

    func refreshPageDetails(from webView: WKWebView) {
        let activeTabID = tabID(for: webView)
        if let url = webView.url, url.isRestorableBrowserURL,
           let activeTabID,
           let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            updateTab(at: index, url: url, title: cleanTitle(webView.title, fallbackURL: url), updateAddress: activeTabID == selectedTabID)
        }

        updateNavigationState(from: webView)
    }

    func loadFavicon(for tabID: BrowserTab.ID?, pageURL: URL, webView: WKWebView) {
        guard let tabID else { return }

        let script = """
        Array.from(document.querySelectorAll('link[rel]'))
            .filter(link => /(?:^|\\s)(?:icon|shortcut icon|apple-touch-icon)(?:\\s|$)/i.test(link.rel))
            .map(link => link.href)
            .filter(Boolean)
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let iconHrefs = result as? [String] ?? []
            let candidates = self.faviconCandidates(from: iconHrefs, pageURL: pageURL)
            self.fetchFirstFavicon(from: candidates, for: tabID, pageURL: pageURL)
        }
    }

    func updateSearchText(for tabID: BrowserTab.ID?, webView: WKWebView) {
        guard let tabID else { return }
        let script = "document.body ? document.body.innerText.slice(0, 30000) : ''"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let text = result as? String else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.tabs.firstIndex(where: { $0.id == tabID }),
                      self.tabs[index].searchText != text else {
                    return
                }

                self.tabs[index].searchText = text
                self.saveSession()
            }
        }
    }

    func updateNavigationState(from webView: WKWebView) {
        guard self.webView === webView else { return }
        let newCanGoBack = webView.canGoBack
        let newCanGoForward = webView.canGoForward
        let progress = webView.estimatedProgress
        let newIsLoading = webView.isLoading && progress < 0.995
        let newEstimatedProgress = newIsLoading ? progress : 1

        if canGoBack != newCanGoBack {
            canGoBack = newCanGoBack
        }
        if canGoForward != newCanGoForward {
            canGoForward = newCanGoForward
        }
        if isLoading != newIsLoading {
            isLoading = newIsLoading
        }
        if estimatedProgress != newEstimatedProgress {
            estimatedProgress = newEstimatedProgress
        }
    }

    func finishNavigation(from webView: WKWebView) {
        if let tabID = tabID(for: webView),
           let startTime = loadStartTimes.removeValue(forKey: tabID) {
            lastPageLoadDuration = Date().timeIntervalSince(startTime)
        }

        refreshPageDetails(from: webView)
        if self.webView === webView {
            isLoading = false
            estimatedProgress = 1
            restoreScrollPositionIfNeeded(in: webView)
        }
    }

    func tabID(for webView: WKWebView) -> BrowserTab.ID? {
        webViewTabIDs[ObjectIdentifier(webView)]
    }

    func clearRequestedURL() {
        if let selectedTabID {
            requestedURLs[selectedTabID] = nil
        }
    }

    func clearRequestedURL(from webView: WKWebView) {
        guard let tabID = tabID(for: webView) else { return }
        requestedURLs[tabID] = nil
    }

    func clearPageError() {
        pageErrorMessage = nil
        pageRecoveryURL = nil
    }

    func clearPageError(from webView: WKWebView) {
        guard self.webView === webView else { return }
        clearPageError()
    }

    func showPageError(_ error: Error) {
        pageErrorMessage = error.localizedDescription
        pageRecoveryURL = selectedTab?.url.isGoogleAccountURL == true ? selectedTab?.url : nil
    }

    func showPageError(_ error: Error, from webView: WKWebView) {
        guard self.webView === webView else { return }
        let recoveryURL = webView.url ?? selectedTab?.url
        if recoveryURL?.isGoogleAccountURL == true {
            pageErrorMessage = "Google blocks account sign-in inside embedded web views. Open this page in Safari to complete Google login."
            pageRecoveryURL = recoveryURL
        } else {
            showPageError(error)
        }
    }

    func beginDownload(_ download: WKDownload) {
        downloadMessage = "Preparing download..."
        downloadManager.track(download) { [weak self] message in
            self?.downloadMessage = message
        }
    }

    func copyClipboardItem(_ item: ClipboardHistoryItem) {
        copyToSystemClipboard(item.text)
    }

    func deleteClipboardItem(_ item: ClipboardHistoryItem) {
        clipboardItems.removeAll { $0.id == item.id }
        saveClipboardHistory()
    }

    func openClipboardLink(_ item: ClipboardHistoryItem) {
        guard let url = item.linkURL else { return }
        newTab(url: url)
    }

    func openSelectedPageInSafari() {
        guard let url = selectedTab?.url, url.scheme == "http" || url.scheme == "https" else { return }
        BrowserSystemActions.openInSafari(url)
    }

    func openRecoveryPageInSafari() {
        guard let pageRecoveryURL else { return }
        BrowserSystemActions.openInSafari(pageRecoveryURL)
    }

    func clearClipboardHistory() {
        clipboardItems = []
        saveClipboardHistory()
    }

    private func copyToSystemClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        #endif
    }


    private func resolvedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        if trimmed.contains(".") && !trimmed.contains(" "), let url = URL(string: "https://\(trimmed)") {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private func displayTitle(for url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    private func cleanTitle(_ title: String?, fallbackURL: URL) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return displayTitle(for: fallbackURL)
        }

        return title
    }

    private func updateTab(at index: Int, url: URL, title: String, updateAddress: Bool = true) {
        let absoluteString = url.absoluteString
        let addressChanged = updateAddress && addressText != absoluteString
        let changed = tabs[index].url != url || tabs[index].title != title || addressChanged
        guard changed else { return }

        tabs[index].url = url
        tabs[index].title = title
        if updateAddress {
            addressText = absoluteString
        }
        saveSession()
    }

    private func faviconCandidates(from hrefs: [String], pageURL: URL) -> [URL] {
        var candidates = hrefs.compactMap { href in
            URL(string: href, relativeTo: pageURL)?.absoluteURL
        }

        if var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            if let fallbackURL = components.url {
                candidates.append(fallbackURL)
            }
        }

        var seen = Set<URL>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func fetchFirstFavicon(from candidates: [URL], for tabID: BrowserTab.ID, pageURL: URL) {
        Task {
            for candidate in candidates {
                var request = URLRequest(url: candidate, timeoutInterval: 8)
                request.setValue(BrowserDefaults.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          200..<400 ~= httpResponse.statusCode,
                          data.count <= 1_000_000,
                          faviconImageIsValid(data) else {
                        continue
                    }

                    await MainActor.run {
                        self.setFaviconData(data, for: tabID, pageURL: pageURL)
                    }
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func setFaviconData(_ data: Data, for tabID: BrowserTab.ID, pageURL: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].url.host(percentEncoded: false) == pageURL.host(percentEncoded: false) else {
            return
        }

        tabs[index].faviconData = data
        saveSession()
    }

    private func saveSession() {
        let restorableTabs = tabs.filter(\.isSessionRestorable)
        guard let data = try? JSONEncoder().encode(restorableTabs) else { return }
        UserDefaults.standard.set(data, forKey: sessionKey)
        if let groupData = try? JSONEncoder().encode(tabGroups) {
            UserDefaults.standard.set(groupData, forKey: groupsKey)
        }
        let selectedTabIDToSave = restorableTabs.contains { $0.id == selectedTabID } ? selectedTabID : restorableTabs.first?.id
        UserDefaults.standard.set(selectedTabIDToSave?.uuidString, forKey: selectedTabKey)
    }

    private func loadDailyTabCount() {
        let todayKey = Self.dayKey(for: Date())
        let savedDayKey = UserDefaults.standard.string(forKey: tabsOpenedTodayDateKey)
        let savedCount = savedDayKey == todayKey ? UserDefaults.standard.integer(forKey: tabsOpenedTodayKey) : 0
        tabsOpenedToday = max(savedCount, tabs.count)
        persistDailyTabCount(dayKey: todayKey)
    }

    private func recordTabOpened() {
        let todayKey = Self.dayKey(for: Date())
        if UserDefaults.standard.string(forKey: tabsOpenedTodayDateKey) != todayKey {
            tabsOpenedToday = 0
        }

        tabsOpenedToday += 1
        persistDailyTabCount(dayKey: todayKey)
    }

    private func persistDailyTabCount(dayKey: String) {
        UserDefaults.standard.set(dayKey, forKey: tabsOpenedTodayDateKey)
        UserDefaults.standard.set(tabsOpenedToday, forKey: tabsOpenedTodayKey)
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func startTemporaryTabExpirationTimer() {
        temporaryTabExpirationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = self
            Task { @MainActor in
                store.closeExpiredTemporaryTabs()
            }
        }
    }

    private func closeExpiredTemporaryTabs(now: Date = Date()) {
        let expiredTabIDs = Set<BrowserTab.ID>(tabs.compactMap { tab in
            guard let temporaryExpiresAt = tab.temporaryExpiresAt,
                  temporaryExpiresAt <= now else {
                return nil
            }
            return tab.id
        })
        guard !expiredTabIDs.isEmpty else { return }

        let removedSelectedTab = selectedTabID.map { expiredTabIDs.contains($0) } ?? false
        for tabID in expiredTabIDs {
            removeCachedWebView(for: tabID)
        }
        tabs.removeAll { expiredTabIDs.contains($0.id) }

        if tabs.isEmpty {
            let initialTab = BrowserTab()
            tabs = [initialTab]
            selectedTabID = initialTab.id
        } else if removedSelectedTab {
            selectedTabID = regularTabs.last?.id ?? tabs.last?.id
        }

        addressText = selectedTab?.url.absoluteString ?? ""
        saveSession()
    }

    private func installContentBlockers() {
        let rules: [[String: [String: String]]] = [
            [
                "trigger": ["url-filter": ".*doubleclick[.]net.*"],
                "action": ["type": "block"]
            ],
            [
                "trigger": ["url-filter": ".*googlesyndication[.]com.*"],
                "action": ["type": "block"]
            ],
            [
                "trigger": ["url-filter": ".*google-analytics[.]com.*"],
                "action": ["type": "block"]
            ]
        ]

        guard let rulesData = try? JSONSerialization.data(withJSONObject: rules),
              let encodedRules = String(data: rulesData, encoding: .utf8) else {
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "LightBrowserBuiltInRules",
            encodedContentRuleList: encodedRules
        ) { ruleList, error in
            Task { @MainActor in
                if let ruleList {
                    self.contentRuleList = ruleList
                    self.installCompiledContentRuleListIfNeeded()
                }
            }
        }
    }

    private func startCachedWebViewCleanupTimer() {
        cachedWebViewCleanupTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = self
            Task { @MainActor in
                store.unloadStaleCachedWebViews()
            }
        }
    }

    private func startMetricsTimer() {
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = self
            Task { @MainActor in
                store.refreshMemoryUsage()
            }
        }
    }

    private func startClipboardMonitor() {
        #if os(macOS)
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        clipboardMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = self
            Task { @MainActor in
                store.pollClipboard()
            }
        }
        #endif
    }

    private func pollClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string),
              !text.isEmpty else {
            return
        }

        addClipboardText(text)
        #endif
    }

    private func addClipboardText(_ text: String) {
        if clipboardItems.first?.text == text {
            return
        }

        clipboardItems.removeAll { $0.text == text }
        clipboardItems.insert(ClipboardHistoryItem(text: text), at: 0)
        if clipboardItems.count > clipboardHistoryLimit {
            clipboardItems.removeLast(clipboardItems.count - clipboardHistoryLimit)
        }
        saveClipboardHistory()
    }

    private func loadClipboardHistory() {
        guard let data = UserDefaults.standard.data(forKey: clipboardHistoryKey),
              let savedItems = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else {
            return
        }

        clipboardItems = Array(savedItems.prefix(clipboardHistoryLimit))
    }

    private func saveClipboardHistory() {
        guard let data = try? JSONEncoder().encode(clipboardItems) else { return }
        UserDefaults.standard.set(data, forKey: clipboardHistoryKey)
    }

    private func refreshMemoryUsage() {
        let newMemoryUsage = Self.currentMemoryUsageBytes()
        if memoryUsageBytes != newMemoryUsage {
            memoryUsageBytes = newMemoryUsage
        }
    }

    private static func currentMemoryUsageBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    private func installCompiledContentRuleListIfNeeded(on targetWebView: WKWebView? = nil) {
        guard let contentRuleList else { return }

        if let targetWebView {
            let identifier = ObjectIdentifier(targetWebView)
            guard !installedContentRuleListWebViewIDs.contains(identifier) else { return }
            targetWebView.configuration.userContentController.add(contentRuleList)
            installedContentRuleListWebViewIDs.insert(identifier)
            return
        }

        for cachedWebView in webViews.values {
            installCompiledContentRuleListIfNeeded(on: cachedWebView)
        }
    }
}

private enum BrowserNavigationError: LocalizedError {
    case unsupportedInternalURL

    var errorDescription: String? {
        "Extension pages need a dedicated extension view and cannot be opened as regular browser tabs yet."
    }
}

private extension URL {
    var isWebURL: Bool {
        scheme == "http" || scheme == "https"
    }

    var isGoogleAccountURL: Bool {
        guard let host = host(percentEncoded: false)?.lowercased() else { return false }
        return host == "accounts.google.com"
            || host == "mail.google.com"
            || host.hasSuffix(".accounts.google.com")
    }

    var isRestorableBrowserURL: Bool {
        scheme != "webkit-extension" && scheme != "lightbrowser"
    }

    var isLoadableInMainBrowser: Bool {
        scheme != "webkit-extension" && scheme != "lightbrowser"
    }
}

private extension BrowserTab {
    var isSessionRestorable: Bool {
        !isTemporary && !isIncognito && !isClipboard && url.isRestorableBrowserURL
    }

    var isManageableRegularTab: Bool {
        !isTemporary && !isIncognito && !isClipboard
    }

    var sidebarSubtitle: String {
        if isClipboard {
            return "History"
        }

        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    func matchesSearch(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let searchableText = [
            title,
            url.absoluteString,
            url.host(percentEncoded: false) ?? "",
            searchText
        ].joined(separator: " ")

        return searchableText.localizedCaseInsensitiveContains(trimmedQuery)
    }
}

private final class BrowserWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var store: BrowserStore?
    private weak var observedWebView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func observe(_ webView: WKWebView) {
        guard observedWebView !== webView else { return }
        observedWebView = webView
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let store = self?.store
                Task { @MainActor in
                    store?.refreshPageDetails(from: webView)
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let store = self?.store
                Task { @MainActor in
                    store?.refreshPageDetails(from: webView)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                let store = self?.store
                Task { @MainActor in
                    store?.updateNavigationState(from: webView)
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let store = self?.store
                Task { @MainActor in
                    store?.updateNavigationState(from: webView)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                let store = self?.store
                Task { @MainActor in
                    store?.updateNavigationState(from: webView)
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                let store = self?.store
                Task { @MainActor in
                    store?.updateNavigationState(from: webView)
                }
            }
        ]
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            if navigationAction.targetFrame?.isMainFrame != false,
               let url = navigationAction.request.url {
                store?.beginNavigation(to: url, from: webView)
            }
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        store?.clearPageError(from: webView)
        store?.updateNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        store?.refreshPageDetails(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.clearPageError(from: webView)
        if let url = webView.url {
            let tabID = store?.tabID(for: webView)
            store?.setTabURL(url, title: webView.title, for: tabID)
            store?.loadFavicon(for: tabID, pageURL: url, webView: webView)
            store?.updateSearchText(for: tabID, webView: webView)
        }
        store?.finishNavigation(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        store?.clearRequestedURL(from: webView)
        store?.showPageError(error, from: webView)
        store?.updateNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        store?.clearRequestedURL(from: webView)
        store?.showPageError(error, from: webView)
        store?.updateNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        store?.clearRequestedURL(from: webView)
        store?.beginDownload(download)
        store?.updateNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store?.clearRequestedURL(from: webView)
        store?.beginDownload(download)
        store?.updateNavigationState(from: webView)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        store?.newTabInSelectedContext(openInBackground: true, url: url)
        return nil
    }
}

@MainActor
private final class BrowserDownloadManager {
    private var handlers: [ObjectIdentifier: BrowserDownloadHandler] = [:]

    func track(_ download: WKDownload, statusHandler: @escaping @MainActor (String) -> Void) {
        let handler = BrowserDownloadHandler { [weak self] download, message, isFinished in
            statusHandler(message)
            if isFinished {
                self?.handlers[ObjectIdentifier(download)] = nil
            }
        }

        handlers[ObjectIdentifier(download)] = handler
        download.delegate = handler
    }
}

private final class BrowserDownloadHandler: NSObject, WKDownloadDelegate {
    private let statusHandler: @MainActor (WKDownload, String, Bool) -> Void
    private var destinationURL: URL?

    init(statusHandler: @escaping @MainActor (WKDownload, String, Bool) -> Void) {
        self.statusHandler = statusHandler
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = suggestedFilename
        savePanel.canCreateDirectories = true
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else {
                Task { @MainActor in
                    self?.statusHandler(download, "Download canceled.", true)
                }
                completionHandler(nil)
                return
            }

            self?.destinationURL = url
            Task { @MainActor in
                self?.statusHandler(download, "Downloading \(url.lastPathComponent)...", false)
            }
            completionHandler(url)
        }
        #else
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFilename)
        self.destinationURL = destinationURL
        Task { @MainActor in
            self.statusHandler(download, "Downloading \(destinationURL.lastPathComponent)...", false)
        }
        completionHandler(destinationURL)
        #endif
    }

    func downloadDidFinish(_ download: WKDownload) {
        let filename = destinationURL?.lastPathComponent ?? "file"
        Task { @MainActor in
            statusHandler(download, "Downloaded \(filename).", true)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            statusHandler(download, downloadFailureMessage(for: error), true)
        }
    }

    private func downloadFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        let permissionDenied = nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteNoPermission.rawValue
            || nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM))

        if permissionDenied {
            return "Download failed: LightBrowser has read-only user-selected file access. Enable App Sandbox > User Selected File > Read/Write in Xcode."
        }

        return "Download failed: \(error.localizedDescription)"
    }
}

struct ContentView: View {
    @State private var store = BrowserStore()

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                BrowserToolbar(store: store)
                ProgressView(value: store.estimatedProgress)
                    .opacity(store.isLoading ? 1 : 0)
                    .frame(height: 2)
                if let pageErrorMessage = store.pageErrorMessage {
                    BrowserErrorBanner(message: pageErrorMessage, recoveryURL: store.pageRecoveryURL) {
                        store.openRecoveryPageInSafari()
                    }
                }
                if let downloadMessage = store.downloadMessage {
                    BrowserStatusBanner(systemImage: "arrow.down.circle", message: downloadMessage)
                }
                if store.selectedTab?.isClipboard == true {
                    ClipboardTabView(store: store)
                } else {
                    WebContentView(store: store, selectedTabID: store.selectedTabID)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(store)
    }
}

private struct SidebarView: View {
    @Bindable var store: BrowserStore
    @State private var searchText = ""
    @State private var groupBeingRenamed: BrowserTabGroup?
    @State private var groupRenameText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        List(selection: $store.selectedTabID) {
            let pinnedTabs = store.pinnedTabs(matching: searchText)
            let ungroupedTabs = store.ungroupedTabs(matching: searchText)
            let temporaryTabs = store.temporaryTabs(matching: searchText)
            let incognitoTabs = store.incognitoTabs(matching: searchText)

            if !pinnedTabs.isEmpty {
                Section {
                    ForEach(pinnedTabs) { tab in
                        SidebarTabRow(store: store, tab: tab)
                    }
                } header: {
                    Text("Pinned")
                }
            }

            Section {
                ForEach(ungroupedTabs) { tab in
                    SidebarTabRow(store: store, tab: tab)
                }
            } header: {
                SidebarSectionHeader(title: "Tabs", buttonSystemName: "plus", buttonHelp: "New Tab") {
                    store.newTab()
                }
            }
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                handleTabDrop(providers, toGroupID: nil)
            }

            ForEach(store.tabGroups) { group in
                let groupedTabs = store.tabs(in: group, matching: searchText)
                Section {
                    ForEach(groupedTabs) { tab in
                        SidebarTabRow(store: store, tab: tab)
                    }
                } header: {
                    SidebarSectionHeader(title: group.name, buttonSystemName: "plus", buttonHelp: "New Tab in \(group.name)") {
                        store.newTab(in: group)
                    }
                    .contextMenu {
                        Button("Rename Group...") {
                            groupBeingRenamed = group
                            groupRenameText = group.name
                        }
                        Button("Delete Group") {
                            store.deleteGroup(group)
                        }
                    }
                }
                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                    handleTabDrop(providers, toGroupID: group.id)
                }
            }

            if !incognitoTabs.isEmpty || searchText.isEmpty {
                Section {
                    ForEach(incognitoTabs) { tab in
                        SidebarTabRow(store: store, tab: tab)
                    }
                } header: {
                    SidebarSectionHeader(title: "Incognito Tabs", buttonSystemName: "plus", buttonHelp: "New Incognito Tab") {
                        store.newIncognitoTab()
                    }
                }
            }

            Section {
                ForEach(temporaryTabs) { tab in
                    SidebarTabRow(store: store, tab: tab)
                }
            } header: {
                SidebarSectionHeader(title: "Temporary Tabs", buttonSystemName: "plus", buttonHelp: "New Temporary Tab") {
                    store.newTemporaryTab()
                }
            }
        }
        .onChange(of: store.selectedTabID) { _, newValue in
            store.selectTab(id: newValue)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                HStack {
                    Text("Tabs")
                        .font(.headline)
                    Spacer()
                    Button {
                        store.newTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New Tab")
                    Button {
                        store.createGroup()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("New Group")
                    Button {
                        store.newIncognitoTab()
                    } label: {
                        Image(systemName: "eye.slash")
                    }
                    .help("New Incognito Tab")
                }

                TextField("Search open tabs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                SidebarClipboardButton(store: store)
                SidebarStatusLine(store: store)
            }
        }
        .onChange(of: store.tabSearchFocusRequest) {
            isSearchFocused = true
        }
        .alert("Rename Group", isPresented: renameGroupBinding) {
            TextField("Group Name", text: $groupRenameText)
            Button("Cancel", role: .cancel) {
                groupBeingRenamed = nil
                groupRenameText = ""
            }
            Button("Rename") {
                if let groupBeingRenamed {
                    store.renameGroup(groupBeingRenamed, to: groupRenameText)
                }
                groupBeingRenamed = nil
                groupRenameText = ""
            }
            .disabled(groupRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var renameGroupBinding: Binding<Bool> {
        Binding {
            groupBeingRenamed != nil
        } set: { isPresented in
            if !isPresented {
                groupBeingRenamed = nil
                groupRenameText = ""
            }
        }
    }

    private func handleTabDrop(_ providers: [NSItemProvider], toGroupID groupID: BrowserTabGroup.ID?) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let rawValue: String?
            if let string = item as? String {
                rawValue = string
            } else if let data = item as? Data {
                rawValue = String(data: data, encoding: .utf8)
            } else if let nsString = item as? NSString {
                rawValue = nsString as String
            } else {
                rawValue = nil
            }

            guard let rawValue, let tabID = UUID(uuidString: rawValue) else { return }
            Task { @MainActor in
                store.moveTab(id: tabID, toGroupID: groupID)
            }
        }

        return true
    }
}

private struct ClipboardTabView: View {
    let store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Clipboard", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Button {
                    store.clearClipboardHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.clipboardItems.isEmpty)
                .help("Clear Clipboard")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if store.clipboardItems.isEmpty {
                ContentUnavailableView("Clipboard Empty", systemImage: "doc.on.doc", description: Text("Copied text will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.clipboardItems) { item in
                            ClipboardHistoryRow(item: item) {
                                store.copyClipboardItem(item)
                            } openLinkAction: {
                                store.openClipboardLink(item)
                            } deleteAction: {
                                store.deleteClipboardItem(item)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let copyAction: () -> Void
    let openLinkAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(8)

            HStack {
                Text(item.copiedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if item.linkURL != nil {
                    Button(action: openLinkAction) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                    .help("Open Link in New Tab")
                }
                Button("Copy", action: copyAction)
                    .controlSize(.small)
                Button("Delete", role: .destructive, action: deleteAction)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SidebarClipboardButton: View {
    let store: BrowserStore

    var body: some View {
        Button {
            store.openClipboardTab()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 16, height: 16)
                Text("Clipboard")
                    .lineLimit(1)
                Spacer()
                Text("\(store.clipboardItems.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(store.selectedTab?.isClipboard == true ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Clipboard")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        Divider()
    }
}

private struct InternalFaviconView: View {
    let tab: BrowserTab

    var body: some View {
        if tab.isClipboard {
            Image(systemName: "doc.on.doc")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        } else {
            FaviconView(data: tab.faviconData)
        }
    }
}

private struct SidebarStatusLine: View {
    let store: BrowserStore

    var body: some View {
        HStack(spacing: 8) {
            Label("\(store.tabsOpenedToday)", systemImage: "rectangle.stack")
                .help("Tabs opened today")
            Divider()
                .frame(height: 12)
            Label(loadDurationText, systemImage: "speedometer")
                .help("Last page load")
            Divider()
                .frame(height: 12)
            Label(memoryText, systemImage: "memorychip")
                .help("LightBrowser memory usage")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var loadDurationText: String {
        guard let lastPageLoadDuration = store.lastPageLoadDuration else {
            return "-"
        }

        return String(format: "%.2fs", lastPageLoadDuration)
    }

    private var memoryText: String {
        guard store.memoryUsageBytes > 0 else {
            return "-"
        }

        let measurement = Measurement(value: Double(store.memoryUsageBytes), unit: UnitInformationStorage.bytes)
        return measurement.formatted(.byteCount(style: .memory, allowedUnits: [.mb, .gb], spellsOutZero: false, includesActualByteCount: false))
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let buttonSystemName: String
    let buttonHelp: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                Image(systemName: buttonSystemName)
            }
            .buttonStyle(.borderless)
            .help(buttonHelp)
        }
    }
}

private struct SidebarTabRow: View {
    let store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                InternalFaviconView(tab: tab)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .lineLimit(1)
                    Text(tab.sidebarSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                TabActionButton(systemName: "plus.square.on.square", help: "Duplicate Tab") {
                    store.duplicate(tab)
                }

                TabActionButton(systemName: "xmark", help: "Close Tab", isDisabled: store.tabs.count == 1) {
                    store.close(tab)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.select(tab)
        }
        .onDrag {
            NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .tag(tab.id)
        .contextMenu {
            if tab.isManageableRegularTab {
                Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                    store.setPinned(!tab.isPinned, for: tab)
                }

                if !store.tabGroups.isEmpty {
                    Menu("Add to Group") {
                        ForEach(store.tabGroups) { group in
                            Button(group.name) {
                                store.moveTab(tab, to: group)
                            }
                        }
                    }
                }

                if tab.groupID != nil {
                    Button("Remove from Group") {
                        store.moveTab(tab, to: nil)
                    }
                }

                Divider()
            }

            if !tab.isClipboard {
                Button("Duplicate Tab") {
                    store.duplicate(tab)
                }
                Button("Duplicate in Background") {
                    store.duplicate(tab, openInBackground: true)
                }
            }
            Button("Close Tab") {
                store.close(tab)
            }
            .disabled(store.tabs.count == 1)
        }
    }
}

private struct TabActionButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .frame(width: 20, height: 20)
                .foregroundStyle(isDisabled ? .tertiary : .secondary)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering && !isDisabled ? Color.primary.opacity(0.12) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct BrowserToolbar: View {
    @Bindable var store: BrowserStore

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .help("Back")

            Button {
                store.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .help("Forward")

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")

            AddressField(text: $store.addressText) {
                store.submitAddress()
            }

            Button {
                store.openSelectedPageInSafari()
            } label: {
                Image(systemName: "globe")
            }
            .disabled(!(store.selectedTab?.url.isWebURL ?? false))
            .help("Open Current Page in Safari for Passkey Login")

            Button {
                BrowserSystemActions.openPasswords()
            } label: {
                Image(systemName: "key")
            }
            .help("Open Passwords")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

#if os(macOS)
private struct AddressField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = "Search or enter website"
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        textField.controlSize = .small
        textField.delegate = context.coordinator
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField

        init(parent: AddressField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            DispatchQueue.main.async {
                textField.currentEditor()?.selectAll(nil)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }

            parent.text = textView.string
            parent.onSubmit()
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
#else
private struct AddressField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField("Search or enter website", text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .onSubmit(onSubmit)
    }
}
#endif

private struct BrowserErrorBanner: View {
    let message: String
    let recoveryURL: URL?
    let recoveryAction: () -> Void

    var body: some View {
        BrowserStatusBanner(systemImage: "exclamationmark.triangle", message: message) {
            if recoveryURL != nil {
                Button("Open in Safari", action: recoveryAction)
                    .controlSize(.small)
            }
        }
    }
}

private struct BrowserStatusBanner<Accessory: View>: View {
    let systemImage: String
    let message: String
    let accessory: Accessory

    init(systemImage: String, message: String, @ViewBuilder accessory: () -> Accessory) {
        self.systemImage = systemImage
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(message)
                .lineLimit(2)
            Spacer()
            accessory
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary)
    }
}

private extension BrowserStatusBanner where Accessory == EmptyView {
    init(systemImage: String, message: String) {
        self.systemImage = systemImage
        self.message = message
        self.accessory = EmptyView()
    }
}

private struct FaviconView: View {
    let data: Data?

    var body: some View {
        Group {
            if let image = faviconImage(from: data) {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}

#if os(macOS)
private func faviconImage(from data: Data?) -> Image? {
    guard let data, let nsImage = NSImage(data: data) else { return nil }
    return Image(nsImage: nsImage)
}

private func faviconImageIsValid(_ data: Data) -> Bool {
    NSImage(data: data) != nil
}

private struct WebContentView: NSViewRepresentable {
    var store: BrowserStore
    var selectedTabID: BrowserTab.ID?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        store.displaySelectedTab(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        _ = selectedTabID
        store.displaySelectedTab(in: nsView)
    }
}
#else
private func faviconImage(from data: Data?) -> Image? {
    guard let data, let uiImage = UIImage(data: data) else { return nil }
    return Image(uiImage: uiImage)
}

private func faviconImageIsValid(_ data: Data) -> Bool {
    UIImage(data: data) != nil
}

private struct WebContentView: UIViewRepresentable {
    var store: BrowserStore
    var selectedTabID: BrowserTab.ID?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        store.displaySelectedTab(in: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        _ = selectedTabID
        store.displaySelectedTab(in: uiView)
    }
}
#endif

private func browserConfiguration(isIncognito: Bool = false) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = isIncognito ? .nonPersistent() : .default()
    configuration.allowsAirPlayForMediaPlayback = true
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.defaultWebpagePreferences.preferredContentMode = .desktop
    configuration.userContentController.addUserScript(passwordAutoFillAssistUserScript())
    configuration.userContentController.addUserScript(cookieConsentUserScript())
    configuration.webExtensionController = BrowserExtensionManager.shared.controller
    return configuration
}

private func passwordAutoFillAssistUserScript() -> WKUserScript {
    WKUserScript(
        source: passwordAutoFillAssistScriptSource,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}

private func cookieConsentUserScript() -> WKUserScript {
    WKUserScript(
        source: cookieConsentScriptSource,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}

private let passwordAutoFillAssistScriptSource = """
(() => {
    function visible(element) {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
    }

    function labelText(input) {
        const labels = [];
        if (input.id) {
            const label = document.querySelector(`label[for="${CSS.escape(input.id)}"]`);
            if (label) labels.push(label.innerText);
        }
        const wrappingLabel = input.closest("label");
        if (wrappingLabel) labels.push(wrappingLabel.innerText);
        labels.push(input.name, input.id, input.placeholder, input.getAttribute("aria-label"));
        return labels.filter(Boolean).join(" ").toLowerCase();
    }

    function annotateForm(form) {
        const inputs = Array.from(form.querySelectorAll("input")).filter(visible);
        const passwordInputs = inputs.filter(input => input.type === "password");
        if (passwordInputs.length === 0) return;

        for (const passwordInput of passwordInputs) {
            if (!passwordInput.autocomplete) {
                const text = labelText(passwordInput);
                passwordInput.autocomplete = /new|create|confirm|signup|sign up|register/.test(text) ? "new-password" : "current-password";
            }
        }

        const usernameInput = inputs.find(input => {
            if (input.type === "password" || input.type === "hidden") return false;
            const text = labelText(input);
            return /user|email|login|account|identifier/.test(text);
        }) || inputs.find(input => ["text", "email", "tel"].includes(input.type || "text"));

        if (usernameInput && !usernameInput.autocomplete) {
            usernameInput.autocomplete = "username";
        }
    }

    function annotate() {
        const forms = Array.from(document.forms);
        const loosePasswordInputs = Array.from(document.querySelectorAll("input[type='password']"));
        for (const form of forms) annotateForm(form);
        for (const input of loosePasswordInputs) {
            if (!input.form) annotateForm(input.closest("form") || document.body);
        }
    }

    annotate();
    const observer = new MutationObserver(annotate);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.setTimeout(() => observer.disconnect(), 30000);
})();
"""

private let cookieConsentScriptSource = """
(() => {
    const handledKey = "__lightBrowserCookieConsentHandled";
    const maxAttempts = 80;
    let attempts = 0;

    const rejectSelectors = [
        "#onetrust-reject-all-handler",
        "#CybotCookiebotDialogBodyButtonDecline",
        "#CybotCookiebotDialogBodyButtonReject",
        ".didomi-notice-disagree-button",
        ".ot-pc-refuse-all-handler",
        "#onetrust-pc-sdk .ot-pc-refuse-all-handler",
        "#onetrust-pc-sdk button[id*='reject' i]",
        "[data-testid='uc-deny-all-button']",
        "[data-testid='reject-all-button']",
        "[id*='reject' i]",
        "[class*='reject' i]",
        "[data-testid*='deny' i]",
        "[data-testid*='reject' i]",
        "[aria-label*='reject' i]",
        "[aria-label*='decline' i]"
    ];

    const manageSelectors = [
        "#onetrust-pc-btn-handler",
        "#CybotCookiebotDialogBodyButtonDetails",
        ".didomi-notice-learn-more-button",
        ".ot-sdk-show-settings",
        "[class*='manage' i][class*='cookie' i]",
        "[id*='manage' i][id*='cookie' i]",
        "[data-testid='uc-more-button']",
        "[data-testid*='more' i]",
        "[data-testid*='settings' i]",
        "[aria-label*='settings' i]",
        "[aria-label*='preferences' i]",
        "[aria-label*='manage' i]"
    ];

    const saveSelectors = [
        ".save-preference-btn-handler",
        "#onetrust-pc-sdk .save-preference-btn-handler",
        "#onetrust-pc-sdk .ot-pc-save-handler",
        "#CybotCookiebotDialogBodyLevelButtonCustomize",
        "#onetrust-pc-sdk button[aria-label*='save' i]",
        "[data-testid='uc-save-button']",
        "[data-testid*='save' i]",
        "[class*='save' i]",
        "[aria-label*='save' i]"
    ];

    const rejectText = /^(reject|reject all|decline|decline all|deny|deny all|refuse|refuse all|only necessary|necessary only|essential only|use necessary|continue without accepting)$/i;
    const manageText = /^(manage|manage cookies|manage options|cookie settings|cookie preferences|settings|preferences|customize|customise|more options|privacy settings)$/i;
    const saveText = /^(save|save choices|save preferences|confirm choices|apply choices|accept selected|agree to selected|confirm my choices)$/i;
    const bannerText = /accept all cookies|manage cookies|cookie preferences|cookie settings/i;
    const quickCookieText = /cookie|consent|privacy preferences|tracking/i;

    function visible(element) {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
    }

    function textOf(element) {
        return (element.innerText || element.value || element.getAttribute("aria-label") || element.title || "").trim().replace(/\\s+/g, " ");
    }

    function activate(element) {
        element.scrollIntoView?.({ block: "center", inline: "center" });
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
            element.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        element.click?.();
    }

    function roots() {
        const found = [document];
        const elements = Array.from(document.querySelectorAll("*"));
        for (const element of elements) {
            if (element.shadowRoot) found.push(element.shadowRoot);
        }
        return found;
    }

    function pageMayHaveConsent() {
        if (document.querySelector("#onetrust-banner-sdk, #onetrust-consent-sdk, #CybotCookiebotDialog, [id*='cookie' i], [class*='cookie' i], [aria-label*='cookie' i]")) {
            return true;
        }

        return quickCookieText.test((document.body?.innerText || "").slice(0, 3000));
    }

    function candidates(rootList) {
        return rootList.flatMap(root => Array.from(root.querySelectorAll("button, a, input[type='button'], input[type='submit'], [role='button']")))
            .filter(visible)
            .filter(element => !/^accept( all)?( cookies)?$/i.test(textOf(element)));
    }

    function consentContainers(rootList) {
        const elements = rootList.flatMap(root => Array.from(root.querySelectorAll("dialog, aside, section, div, form, [role='dialog'], [aria-modal='true']")));
        return elements
            .filter(visible)
            .filter(element => bannerText.test(textOf(element)))
            .sort((a, b) => textOf(a).length - textOf(b).length);
    }

    function clickFirstSelector(selectors, rootList) {
        for (const root of rootList) {
            for (const selector of selectors) {
                const element = root.querySelector(selector);
                if (element && visible(element) && !/^accept( all)?( cookies)?$/i.test(textOf(element))) {
                    activate(element);
                    return true;
                }
            }
        }
        return false;
    }

    function clickByText(pattern, rootList) {
        const element = candidates(rootList).find(candidate => pattern.test(textOf(candidate)));
        if (!element) return false;
        activate(element);
        return true;
    }

    function clickInConsentContainer(pattern, rootList) {
        for (const container of consentContainers(rootList)) {
            const element = Array.from(container.querySelectorAll("button, a, input[type='button'], input[type='submit'], [role='button']"))
                .filter(visible)
                .filter(candidate => !/^accept( all)?( cookies)?$/i.test(textOf(candidate)))
                .find(candidate => pattern.test(textOf(candidate)));
            if (!element) continue;
            activate(element);
            return true;
        }
        return false;
    }

    function disableOptionalToggles(rootList) {
        const toggles = rootList.flatMap(root => Array.from(root.querySelectorAll("input[type='checkbox'], [role='switch']")));
        for (const toggle of toggles) {
            const disabled = toggle.disabled || toggle.getAttribute("aria-disabled") === "true";
            if (disabled || !visible(toggle)) continue;

            const checked = toggle.checked === true || toggle.getAttribute("aria-checked") === "true";
            const label = (toggle.closest("label")?.innerText || toggle.getAttribute("aria-label") || toggle.closest("[class*='purpose'], [class*='category']")?.innerText || "").toLowerCase();
            const necessary = /necessary|essential|required|strictly|functional/.test(label);
            if (checked && !necessary) {
                activate(toggle);
            }
        }
    }

    function handleConsent() {
        if (window.localStorage.getItem(handledKey) === location.hostname) return true;
        attempts += 1;
        if (!pageMayHaveConsent()) return attempts >= maxAttempts;
        const rootList = roots();

        if (clickFirstSelector(rejectSelectors, rootList) || clickInConsentContainer(rejectText, rootList) || clickByText(rejectText, rootList)) {
            window.localStorage.setItem(handledKey, location.hostname);
            return true;
        }

        if (attempts <= 20 && (clickFirstSelector(manageSelectors, rootList) || clickInConsentContainer(manageText, rootList) || clickByText(manageText, rootList))) {
            window.setTimeout(() => {
                const delayedRoots = roots();
                disableOptionalToggles(delayedRoots);
                if (clickFirstSelector(rejectSelectors, delayedRoots) || clickInConsentContainer(rejectText, delayedRoots) || clickByText(rejectText, delayedRoots) || clickFirstSelector(saveSelectors, delayedRoots) || clickInConsentContainer(saveText, delayedRoots) || clickByText(saveText, delayedRoots)) {
                    window.localStorage.setItem(handledKey, location.hostname);
                }
            }, 600);
            return false;
        }

        disableOptionalToggles(rootList);
        if (clickFirstSelector(saveSelectors, rootList) || clickInConsentContainer(saveText, rootList) || clickByText(saveText, rootList)) {
            window.localStorage.setItem(handledKey, location.hostname);
            return true;
        }

        return attempts >= maxAttempts;
    }

    const interval = window.setInterval(() => {
        if (handleConsent()) {
            window.clearInterval(interval);
            observer.disconnect();
        }
    }, 1000);

    const observer = new MutationObserver(() => {
        if (attempts < maxAttempts) {
            window.setTimeout(handleConsent, 100);
        }
    });

    observer.observe(document.documentElement, { childList: true, subtree: true });
    handleConsent();
})();
"""

#Preview {
    ContentView()
}
