import SwiftUI
import UIKit
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
    private var webDialog: UIAlertController?
    private var dialogReply: ((Bool, String?) -> Void)?

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
            if webView === tab?.view { dismissWebDialog() }
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
        if webView === tab?.view { dismissWebDialog() }
        DownloadCenter.shared.notice = "페이지가 중단되었습니다. 새로고침해 다시 열 수 있습니다."
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
        let result: Any? = try? await withCheckedThrowingContinuation { (reply: CheckedContinuation<Any, Error>) in
            current.view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
                reply.resume(with: result)
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

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
