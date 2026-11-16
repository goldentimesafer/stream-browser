import SwiftUI
import UIKit
import WebKit

@MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    let view: WKWebView
    var observations: [NSKeyValueObservation] = []
    /// Requests the desktop version of pages in this tab only.
    var desktopMode = false
    /// Page released on a memory warning; reloaded when the tab is selected again.
    var unloaded: (url: URL, title: String?)?

    var displayTitle: String { unloaded?.title ?? view.title ?? "새 탭" }
    var displayHost: String? { (unloaded?.url ?? view.url)?.host }

    init(store: WKWebsiteDataStore, rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsInlineMediaPlayback = true
        if let rules { configuration.userContentController.add(rules) }
        view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = false
    }
}

@MainActor
final class PrivateBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selection: UUID?
    @Published private(set) var rulesStatus = "규칙 준비 중"
    @Published private(set) var exceptionHosts: Set<String> = []
    /// A link the user chose to save from the web view's long-press menu.
    @Published var pendingSaveURL: URL?
    private var store = WKWebsiteDataStore.nonPersistent()
    private var rules: WKContentRuleList?
    private var ruleTask: Task<Void, Never>?
    private var allowedDownloadNavigation: [UUID: URL] = [:]
    private var active = false
    private var webDialog: UIAlertController?
    private var dialogReply: ((Bool, String?) -> Void)?
    private let center: DownloadCenter
    private var memoryObserver: NSObjectProtocol?

    init(center: DownloadCenter) {
        self.center = center
        super.init()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.releaseBackgroundTabs() } }
    }

    var tab: BrowserTab? { tabs.first { $0.id == selection } }

    /// Frees the web content of every tab except the selected one. Form input and playback
    /// state in those tabs are lost (spec §12); the address and title are kept for the tab list.
    private func releaseBackgroundTabs() {
        for item in tabs where item.id != selection && item.unloaded == nil {
            guard let url = item.view.url, url.absoluteString != "about:blank" else { continue }
            item.unloaded = (url, item.view.title)
            item.view.stopLoading()
            item.view.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    /// WebKit link-menu actions that would persist the URL in Safari's Reading List or open it in another app.
    private static let leakingMenuActions: Set<String> = [
        "WKElementActionTypeAddToReadingList",
        "WKElementActionTypeOpenInDefaultBrowser",
        "WKElementActionTypeOpenInExternalApplication"
    ]

    func prepare() {
        guard ruleTask == nil else { return }
        ruleTask = Task {
            // Scoped tracker rules. Additions are reviewed and bundled with the app.
            let domains = ["doubleclick.net", "google-analytics.com", "googletagmanager.com",
                           "scorecardresearch.com", "adnxs.com", "googlesyndication.com"]
            let rule: [[String: Any]] = domains.map { domain in
                let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
                return ["trigger": ["url-filter": "^https://([a-z0-9-]+\\.)*\(escaped)[:/]",
                                    "load-type": ["third-party"]] as [String: Any], "action": ["type": "block"]]
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: rule)
                let json = String(decoding: data, as: UTF8.self)
                rules = try await withCheckedThrowingContinuation { (result: CheckedContinuation<WKContentRuleList, Error>) in
                    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "streambrowser-trackers-v1",
                                                                          encodedContentRuleList: json) { list, error in
                        if let list { result.resume(returning: list) }
                        else { result.resume(throwing: error ?? MediaError.storage) }
                    }
                }
                rulesStatus = "로컬 추적 차단 적용"
                for item in tabs { applyRules(item.view, host: item.view.url?.host) }
            } catch { rulesStatus = "차단 규칙을 불러오지 못했습니다" }
        }
    }

    func setActive(_ value: Bool) {
        active = value
        if value {
            for item in tabs { item.view.setAllMediaPlaybackSuspended(item.id != selection, completionHandler: nil) }
        } else {
            dismissWebDialog()
            allowedDownloadNavigation.removeAll()
            for item in tabs {
                item.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
                item.view.closeAllMediaPresentations(completionHandler: nil)
            }
        }
    }

    func newTab(url: URL? = nil) {
        guard tabs.count < 20 else { center.notice = "탭은 20개까지 열 수 있습니다."; return }
        let item = BrowserTab(store: store, rules: rules)
        item.view.navigationDelegate = self
        item.view.uiDelegate = self
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        item.view.scrollView.refreshControl = refresh
        item.observations = [
            item.view.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.loadingChanged() } },
            item.view.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } }
        ]
        tabs.append(item)
        select(item.id)
        if let url { load(url) }
    }

    func select(_ id: UUID) {
        if selection != id {
            dismissWebDialog()
            tab?.view.pauseAllMediaPlayback(completionHandler: nil)
            tab?.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        selection = id
        tab?.view.setAllMediaPlaybackSuspended(!active, completionHandler: nil)
        if let tab, let unloaded = tab.unloaded {
            tab.unloaded = nil
            load(unloaded.url)
        }
    }

    func close(_ id: UUID) {
        if selection == id { dismissWebDialog() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].view.stopLoading()
        tabs[index].view.pauseAllMediaPlayback(completionHandler: nil)
        tabs[index].view.navigationDelegate = nil
        allowedDownloadNavigation[id] = nil
        tabs.remove(at: index)
        if selection == id {
            selection = nil
            if let next = tabs.last?.id { select(next) }
        }
    }

    func clear() {
        center.stopPrivateTransfers()
        for id in tabs.map(\.id) { close(id) }
        exceptionHosts.removeAll()
        store = .nonPersistent()
    }

    func open(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { return }
        if var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
           ["https", "http"].contains(scheme) {
            components.scheme = "https"
            if let url = components.url { load(url) }
            return
        }
        if !value.contains(where: \.isWhitespace), value.contains("."),
           let url = URL(string: "https://" + value), MediaPolicy.secureWebURL(url) {
            load(url)
            return
        }
        var search = URLComponents()
        search.scheme = "https"; search.host = "duckduckgo.com"; search.path = "/"
        search.queryItems = [URLQueryItem(name: "q", value: value)]
        if let url = search.url { load(url) }
    }

    func load(_ url: URL) {
        guard active, MediaPolicy.secureWebURL(url) else { return }
        if tab == nil { newTab() }
        guard let tab else { return }
        applyRules(tab.view, host: url.host)
        tab.view.load(URLRequest(url: url))
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        guard active, let item = tabs.first(where: { $0.view.scrollView.refreshControl === sender }),
              item.view.url != nil else {
            sender.endRefreshing()
            return
        }
        item.view.reload()
    }

    private func loadingChanged() {
        for item in tabs where !item.view.isLoading { item.view.scrollView.refreshControl?.endRefreshing() }
        objectWillChange.send()
    }

    func toggleDesktopMode() {
        guard active, let tab else { return }
        tab.desktopMode.toggle()
        objectWillChange.send()
        if tab.view.url != nil { tab.view.reload() }
    }

    func toggleException() {
        guard let tab, let host = tab.view.url?.host?.lowercased() else { return }
        if !exceptionHosts.insert(host).inserted { exceptionHosts.remove(host) }
        applyRules(tab.view, host: host)
        tab.view.reload()
    }

    private func applyRules(_ view: WKWebView, host: String?) {
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let rules, host.map({ exceptionHosts.contains($0.lowercased()) }) != true { controller.add(rules) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let desktop = tabs.first(where: { $0.view === webView })?.desktopMode == true
        preferences.preferredContentMode = desktop ? .desktop : .recommended
        decideNavigation(webView, action: action) { decisionHandler($0, preferences) }
    }

    private func decideNavigation(_ webView: WKWebView, action: WKNavigationAction,
                                  decisionHandler: (WKNavigationActionPolicy) -> Void) {
        guard active, let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard MediaPolicy.secureWebURL(url) else { decisionHandler(.cancel); return }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { newTab(url: url) }
            return
        }
        if action.targetFrame?.isMainFrame == true {
            if webView === tab?.view { dismissWebDialog() }
            applyRules(webView, host: url.host)
            if let tab = tabs.first(where: { $0.view === webView }) {
                allowedDownloadNavigation[tab.id] = action.navigationType == .linkActivated ? url : nil
            }
        }
        decisionHandler(action.shouldPerformDownload && action.navigationType == .linkActivated &&
                        action.sourceFrame.isMainFrame ? .download : .allowWithoutAppLinks)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigation: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard active else { decisionHandler(.cancel); return }
        let response = navigation.response
        if navigation.isForMainFrame, let url = response.url, !MediaPolicy.secureWebURL(url), url.absoluteString != "about:blank" {
            decisionHandler(.cancel); return
        }
        if let http = response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true {
            let id = tabs.first(where: { $0.view === webView })?.id
            let userURL = id.flatMap { allowedDownloadNavigation[$0] }
            let permitted = navigation.isForMainFrame && userURL == response.url && MediaPolicy.videoExtension(response) != nil
            decisionHandler(permitted ? .download : .cancel)
            return
        }
        decisionHandler(navigation.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let source = navigationAction.sourceFrame.request.url
        if let source { center.acceptWebDownload(download, origin: source) }
        else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if let source = navigationResponse.response.url { center.acceptWebDownload(download, origin: source) }
        else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
        guard active, webView === tab?.view, let url = elementInfo.linkURL, MediaPolicy.secureWebURL(url) else {
            completionHandler(nil)
            return
        }
        // Keep WebKit's link actions except those that hand the URL to Safari or another app,
        // and add one that opens the save form for this link.
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let kept = suggested.filter { !Self.leakingMenuActions.contains(($0 as? UIAction)?.identifier.rawValue ?? "") }
            var items: [UIMenuElement] = []
            // For universal links WebKit replaces "Open" with the app/browser actions removed above.
            if !kept.contains(where: { ($0 as? UIAction)?.identifier.rawValue == "WKElementActionTypeOpen" }) {
                items.append(UIAction(title: "열기", image: UIImage(systemName: "safari")) { _ in
                    Task { @MainActor in self?.load(url) }
                })
            }
            items.append(UIAction(title: "이 링크의 영상 저장", image: UIImage(systemName: "arrow.down.to.line")) { _ in
                Task { @MainActor in self?.pendingSaveURL = url }
            })
            return UIMenu(children: items + kept)
        })
    }

    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating) {
        if webView === tab?.view, let url = elementInfo.linkURL { load(url) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        center.notice = "페이지를 열 수 없습니다. HTTPS 주소와 연결 상태를 확인하세요."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === tab?.view { dismissWebDialog() }
        center.notice = "페이지가 중단되었습니다. 새로고침해 다시 열 수 있습니다."
    }

    func detectedMedia() async -> [URL] {
        guard active, let current = tab else { return [] }
        let page = current.view.url
        let script = """
        const urls = [];
        for (const node of document.querySelectorAll('video, video source, a[href]')) {
            if (urls.length >= 64) break;
            const value = node.currentSrc || node.src || node.href;
            if (!value) continue;
            try {
                const url = new URL(value, document.baseURI);
                if (node.tagName !== 'A' || /\\.(mp4|mov|m4v|m3u8)$/i.test(url.pathname)) urls.push(url.href);
            } catch (_) {}
        }
        return urls;
        """
        // Call the Objective-C method directly. The Swift-refined wrapper lives in
        // libswiftWebKit.dylib, which the iOS 18.5 runtime does not provide, so linking it
        // makes the app abort at launch there (seen on the iOS 18.5 simulator).
        let result: Any? = try? await withCheckedThrowingContinuation { (reply: CheckedContinuation<Any, Error>) in
            current.view.__callAsyncJavaScript(script, arguments: nil, inFrame: nil, in: .defaultClient) { value, error in
                if let error { reply.resume(throwing: error) } else { reply.resume(returning: value ?? NSNull()) }
            }
        }
        guard let values = result as? [String], active, tab?.id == current.id, current.view.url == page else { return [] }
        var seen = Set<URL>()
        return values.compactMap { text in
            guard text.utf8.count <= 4096, let url = URL(string: text), MediaPolicy.secureWebURL(url),
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private func dismissWebDialog() {
        let reply = dialogReply
        dialogReply = nil
        webDialog?.dismiss(animated: false)
        webDialog = nil
        reply?(false, nil)
    }

    private func presentWebDialog(_ view: WKWebView, frame: WKFrameInfo, message: String,
                                  prompt: String? = nil, isPrompt: Bool = false, alertOnly: Bool = false,
                                  reply: @escaping (Bool, String?) -> Void) {
        guard active, view === tab?.view, webDialog == nil,
              var presenter = view.window?.rootViewController else { reply(false, nil); return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !(presenter is UIAlertController), !presenter.isBeingDismissed else { reply(false, nil); return }
        let host = frame.securityOrigin.host
        let dialog = UIAlertController(title: "웹사이트: \(host)", message: String(message.prefix(2000)), preferredStyle: .alert)
        if isPrompt { dialog.addTextField { $0.text = prompt; $0.autocorrectionType = .no } }
        dialogReply = reply
        webDialog = dialog
        let finish: (Bool) -> Void = { [weak self, weak dialog] accepted in
            guard let self, let dialog, self.webDialog === dialog else { return }
            let completion = self.dialogReply
            self.dialogReply = nil
            self.webDialog = nil
            completion?(accepted, accepted ? dialog.textFields?.first?.text : nil)
        }
        dialog.addAction(UIAlertAction(title: "확인", style: .default) { _ in finish(true) })
        if !alertOnly { dialog.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in finish(false) }) }
        presenter.present(dialog, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        presentWebDialog(webView, frame: frame, message: message, alertOnly: true) { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        presentWebDialog(webView, frame: frame, message: message) { accepted, _ in completionHandler(accepted) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        presentWebDialog(webView, frame: frame, message: prompt, prompt: defaultText, isPrompt: true) { accepted, text in
            completionHandler(accepted ? text : nil)
        }
    }
}

private extension WKNavigationActionPolicy {
    /// WebKit's `_WKNavigationActionPolicyAllowWithoutTryingAppLink` (allow + 2). Plain `.allow` lets WebKit
    /// open universal links in another installed app, which would carry a private page's URL out of the browser.
    static let allowWithoutAppLinks = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
