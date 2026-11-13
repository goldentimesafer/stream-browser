import SwiftUI
import WebKit

@MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    let view: WKWebView
    var observations: [NSKeyValueObservation] = []

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
    private var store = WKWebsiteDataStore.nonPersistent()
    private var rules: WKContentRuleList?
    private var ruleTask: Task<Void, Never>?
    private var allowedDownloadNavigation: [UUID: URL] = [:]
    private var active = false

    var tab: BrowserTab? { tabs.first { $0.id == selection } }

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
            for item in tabs { item.view.setAllMediaPlaybackSuspended(false, completionHandler: nil) }
        } else {
            allowedDownloadNavigation.removeAll()
            for item in tabs {
                item.view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
                item.view.closeAllMediaPresentations(completionHandler: nil)
            }
        }
    }

    func newTab(url: URL? = nil) {
        guard tabs.count < 20 else { DownloadCenter.shared.notice = "탭은 20개까지 열 수 있습니다."; return }
        let item = BrowserTab(store: store, rules: rules)
        item.view.navigationDelegate = self
        item.view.uiDelegate = self
        item.observations = [
            item.view.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            item.view.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } }
        ]
        tabs.append(item)
        selection = item.id
        if let url { load(url) }
    }

    func select(_ id: UUID) {
        if selection != id { tab?.view.pauseAllMediaPlayback(completionHandler: nil) }
        selection = id
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].view.stopLoading()
        tabs[index].view.pauseAllMediaPlayback(completionHandler: nil)
        tabs[index].view.navigationDelegate = nil
        allowedDownloadNavigation[id] = nil
        tabs.remove(at: index)
        if selection == id { selection = tabs.last?.id }
    }

    func clear() {
        DownloadCenter.shared.stopPrivateTransfers()
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

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard active, let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard MediaPolicy.secureWebURL(url) else { decisionHandler(.cancel); return }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { newTab(url: url) }
            return
        }
        if action.targetFrame?.isMainFrame == true {
            applyRules(webView, host: url.host)
            if let tab = tabs.first(where: { $0.view === webView }) {
                allowedDownloadNavigation[tab.id] = action.navigationType == .linkActivated ? url : nil
            }
        }
        decisionHandler(action.shouldPerformDownload && action.navigationType == .linkActivated &&
                        action.sourceFrame.isMainFrame ? .download : .allow)
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
        if let source { DownloadCenter.shared.acceptWebDownload(download, origin: source) }
        else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if let source = navigationResponse.response.url { DownloadCenter.shared.acceptWebDownload(download, origin: source) }
        else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        DownloadCenter.shared.notice = "페이지를 열 수 없습니다. HTTPS 주소와 연결 상태를 확인하세요."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DownloadCenter.shared.notice = "페이지가 중단되었습니다. 새로고침해 다시 열 수 있습니다."
    }
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
