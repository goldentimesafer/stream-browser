import SwiftUI
import UIKit
import WebKit

struct BrowserScreen: View {
    @ObservedObject var browser: PrivateBrowser
    @ObservedObject var center: DownloadCenter
    @State private var address = ""
    @FocusState private var editingAddress: Bool
    @State private var panel: Panel?
    @State private var confirmClear = false
    @State private var findText = ""
    @State private var findResult: String?
    @State private var showFind = false
    /// Link chosen from the long-press menu; nil means "use the current page".
    @State private var downloadURL: URL?
    @Environment(\.scenePhase) private var scenePhase

    private enum Panel: String, Identifiable {
        case tabs, download, bookmarks, site
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { panel = .site } label: { Image(systemName: "shield.lefthalf.filled") }
                    .accessibilityLabel("사이트 보호 상태")
                TextField("HTTPS 주소 또는 검색어", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.webSearch).submitLabel(.go).focused($editingAddress)
                    .onSubmit { editingAddress = false; browser.open(address) }
                    .accessibilityLabel("주소 또는 검색어")
                if !address.isEmpty && editingAddress {
                    Button { address = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("주소 지우기")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            // Autocomplete uses saved bookmarks only (spec §4.2): no history, no remote suggestions.
            if editingAddress, !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { bookmark in
                        Button {
                            editingAddress = false
                            address = bookmark.url.absoluteString
                            browser.load(bookmark.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.title).lineLimit(1)
                                Text(bookmark.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44).padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("북마크 \(bookmark.title)")
                        Divider()
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let url = browser.tab?.view.url, let host = url.host {
                Label(host, systemImage: "lock").font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).padding(.bottom, 5).accessibilityLabel("현재 HTTPS 호스트 \(host)")
            }
            if showFind, let tab = browser.tab {
                HStack {
                    TextField("페이지에서 찾기", text: $findText).submitLabel(.search)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { find(in: tab.view) }
                    Button("찾기") { find(in: tab.view) }
                    if let findResult { Text(findResult).font(.caption) }
                    Button { showFind = false; findText = ""; findResult = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("검색 닫기")
                }.padding(.horizontal, 12).padding(.bottom, 6)
            }
            if let tab = browser.tab {
                WebSurface(webView: tab.view).id(tab.id).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("비공개 탐색", systemImage: "safari", description: Text("주소나 검색어를 입력하세요."))
                    .frame(maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 0) {
                toolbarButton("chevron.left", "뒤로") { browser.tab?.view.goBack() }.disabled(browser.tab?.view.canGoBack != true)
                toolbarButton("chevron.right", "앞으로") { browser.tab?.view.goForward() }.disabled(browser.tab?.view.canGoForward != true)
                toolbarButton(browser.tab?.view.isLoading == true ? "xmark" : "arrow.clockwise",
                              browser.tab?.view.isLoading == true ? "중지" : "새로고침") {
                    if let view = browser.tab?.view { if view.isLoading { view.stopLoading() } else { view.reload() } }
                }.disabled(browser.tab == nil)
                toolbarButton("arrow.down.to.line", "영상 저장") { downloadURL = nil; panel = .download }
                toolbarButton("square.on.square", "탭 \(browser.tabs.count)개") { panel = .tabs }
                Menu {
                    Button("북마크 목록", systemImage: "book") { panel = .bookmarks }
                    Button("현재 페이지 북마크", systemImage: "bookmark") { addBookmark() }.disabled(browser.tab?.view.url == nil)
                    Button("페이지에서 찾기", systemImage: "magnifyingglass") { showFind = true }.disabled(browser.tab == nil)
                    if browser.tab?.desktopMode == true {
                        Button("모바일 사이트 보기", systemImage: "iphone") { browser.toggleDesktopMode() }
                    } else {
                        Button("데스크톱 사이트 보기", systemImage: "desktopcomputer") { browser.toggleDesktopMode() }
                            .disabled(browser.tab?.view.url == nil)
                    }
                    if let url = browser.tab?.view.url, MediaPolicy.secureWebURL(url) {
                        ShareLink(item: url) { Label("현재 링크 공유", systemImage: "square.and.arrow.up") }
                    }
                    Button("비공개 세션 종료", systemImage: "xmark.shield", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(maxWidth: .infinity, minHeight: 46)
                }.accessibilityLabel("탐색 메뉴")
            }.padding(.horizontal, 6)
        }
        .onChange(of: browser.tab?.view.url, initial: true) { _, url in
            if !editingAddress { address = url?.absoluteString ?? "" }
            findResult = nil
        }
        .onChange(of: browser.selection) { _, _ in address = browser.tab?.view.url?.absoluteString ?? "" }
        .onChange(of: scenePhase) { _, phase in if phase == .background { panel = nil } }
        .onChange(of: browser.pendingSaveURL) { _, url in
            guard let url else { return }
            browser.pendingSaveURL = nil
            downloadURL = url
            panel = .download
        }
        .sheet(item: $panel) { selected in
            NavigationStack {
                switch selected {
                case .download:
                    DownloadForm(initialURL: downloadURL ?? browser.tab?.view.url, browser: browser, center: center)
                case .tabs:
                    List {
                        Button("새 비공개 탭", systemImage: "plus") { browser.newTab(); panel = nil }
                        ForEach(browser.tabs) { tab in
                            Button {
                                browser.select(tab.id); panel = nil
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(tab.displayTitle)
                                    if let host = tab.displayHost { Text(host).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .swipeActions { Button("닫기", role: .destructive) { browser.close(tab.id) } }
                        }
                    }.navigationTitle("비공개 탭")
                case .bookmarks:
                    List(center.library.bookmarks) { bookmark in
                        Button(bookmark.title) { browser.load(bookmark.url); panel = nil }
                            .swipeActions { Button("삭제", role: .destructive) {
                                center.modifyLibrary { $0.bookmarks.removeAll { $0.id == bookmark.id } }
                            } }
                    }.navigationTitle("북마크")
                case .site:
                    List {
                        if let host = browser.tab?.view.url?.host {
                            LabeledContent("현재 사이트", value: host)
                            LabeledContent("연결", value: "HTTPS")
                            LabeledContent("추적 차단", value: browser.exceptionHosts.contains(host.lowercased()) ? "현재 세션 예외" : browser.rulesStatus)
                            Button(browser.exceptionHosts.contains(host.lowercased()) ? "이 사이트 차단 복원" : "이 사이트 차단 잠시 해제") {
                                browser.toggleException()
                            }
                        } else { Text(browser.rulesStatus) }
                        Text("탭과 웹 쿠키는 이 비공개 세션에 보관됩니다.").foregroundStyle(.secondary)
                    }.navigationTitle("보호 상태")
                }
            }
        }
        .confirmationDialog("비공개 세션을 종료할까요?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("세션 종료", role: .destructive) { browser.clear(); address = ""; showFind = false; findText = "" }
        } message: { Text("탭과 진행 중인 비공개 다운로드를 정리합니다. 저장한 영상, 북마크와 승인한 공개 전송은 유지됩니다.") }
    }

    /// Bookmarks whose title or address contains the typed text, excluding the page already shown.
    private var suggestions: [Bookmark] {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, query != browser.tab?.view.url?.absoluteString else { return [] }
        return Array(center.library.bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }.prefix(5))
    }

    private func toolbarButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 46) }
            .accessibilityLabel(title)
    }

    private func find(in view: WKWebView) {
        guard !findText.isEmpty else { return }
        // Objective-C entry point; the Swift wrapper requires libswiftWebKit.dylib (absent from the iOS 18.5 runtime).
        view.__find(findText, with: WKFindConfiguration()) { result in
            findResult = result.matchFound ? "찾음" : "일치 없음"
        }
    }

    private func addBookmark() {
        guard let view = browser.tab?.view, let url = view.url, MediaPolicy.secureWebURL(url),
              url.query == nil, url.fragment == nil else {
            center.notice = "북마크에는 쿼리나 토큰이 없는 HTTPS 주소를 저장할 수 있습니다."
            return
        }
        guard !center.library.bookmarks.contains(where: { $0.url == url }) else { return }
        center.modifyLibrary { $0.bookmarks.append(Bookmark(id: UUID(), title: MediaPolicy.displayName(view.title ?? url.host ?? "북마크"), url: url)) }
    }
}

struct DownloadForm: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: PrivateBrowser
    @ObservedObject var center: DownloadCenter
    @State private var input: String
    @State private var mode: TransferMode
    @State private var permitted = false
    @State private var candidates: [URL] = []
    @State private var scanning = false
    @State private var hlsOptions = HLSDownloadOptions()
    @State private var fileInfo: String?
    @State private var infoError: String?
    @State private var checkingInfo = false

    init(initialURL: URL?, browser: PrivateBrowser, center: DownloadCenter) {
        self.browser = browser; self.center = center
        _input = State(initialValue: initialURL?.absoluteString ?? "")
        _mode = State(initialValue: initialURL?.pathExtension.lowercased() == "m3u8" ? .hls : .web)
    }

    private var url: URL? { URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        Form {
            Section("페이지에서 찾은 영상") {
                if scanning { ProgressView() }
                ForEach(candidates, id: \.self) { candidate in
                    Button {
                        input = candidate.absoluteString
                        mode = candidate.pathExtension.lowercased() == "m3u8" ? .hls : .web
                        permitted = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(MediaPolicy.displayName(candidate.lastPathComponent)).lineLimit(1)
                            Text(candidate.host ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !scanning && candidates.isEmpty {
                    Text("현재 페이지에서 직접 영상 주소를 찾지 못했습니다. 로그인·DRM·blob 영상이나 다른 프레임의 영상은 감지되지 않을 수 있습니다.")
                        .font(.footnote)
                }
                Button("영상 주소 다시 찾기") { Task { await scan() } }.disabled(scanning)
            }
            Section("영상 주소") {
                TextField("https://…", text: $input, axis: .vertical).lineLimit(2...4)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                if let host = url?.host { LabeledContent("출처", value: host) }
            }
            if let url, MediaPolicy.secureWebURL(url) {
                Section("파일 정보") {
                    LabeledContent("파일", value: fileInfo ?? DownloadCenter.fileSummary(
                        name: url.lastPathComponent, ext: Self.knownExtension(url), bytes: nil))
                    LabeledContent("저장 위치", value: mode == .hls ? "iOS가 관리하는 오프라인 자산(앱 내 재생)" : "앱 내 보호 저장소(iCloud 백업 제외)")
                    LabeledContent("진행 조건", value: mode == .web ? "앱을 화면에 둔 상태에서만" : "화면 잠금·앱 종료 중에도 iOS가 진행")
                    if mode.usesSystemSession {
                        Button(checkingInfo ? "확인 중…" : "서버에서 크기·형식 확인") { Task { await probe(url) } }.disabled(checkingInfo)
                    } else {
                        Text("비공개 저장은 세션 밖에서 서버에 묻지 않습니다. 크기와 형식은 저장을 시작할 때 확인 창에 표시됩니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let infoError { Text(infoError).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section {
                Picker("저장 방식", selection: $mode) {
                    ForEach([TransferMode.web, .backgroundFile, .hls], id: \.self) { Text($0.label).tag($0) }
                }
                if mode.usesSystemSession {
                    Text("설정에 등록한 공개 HTTPS 출처에서 저장합니다. 셀룰러 데이터는 사용하지 않으며 시작 시간은 시스템 조건에 따릅니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("시스템 전송은 서버의 주소 변경을 자동으로 따를 수 있습니다. 등록한 출처 밖의 접속까지 차단하지 않으므로 신뢰하는 공개 제공자에만 사용하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if mode == .hls {
                        Text("비암호화 주문형 HLS를 앱 안에 보관합니다.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Toggle("저장이 허용된 영상입니다", isOn: $permitted)
            }
            if mode == .hls {
                Section("HLS 저장 옵션") {
                    Picker("최대 화질", selection: $hlsOptions.maximumHeight) {
                        Text("자동").tag(0)
                        Text("480p 이하").tag(480)
                        Text("720p 이하").tag(720)
                        Text("1080p 이하").tag(1080)
                    }
                    Picker("오디오 언어", selection: $hlsOptions.audioLanguage) {
                        Text("기본").tag("")
                        Text("한국어").tag("ko")
                        Text("영어").tag("en")
                        Text("일본어").tag("ja")
                    }
                    Picker("자막", selection: $hlsOptions.subtitleLanguage) {
                        Text("기본").tag("")
                        Text("저장 안 함").tag("none")
                        Text("한국어").tag("ko")
                        Text("영어").tag("en")
                        Text("일본어").tag("ja")
                    }
                    Text("제공되는 화질과 언어만 저장할 수 있습니다. 선택한 언어가 없으면 시작 전에 알려드립니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("저장 시작", systemImage: "arrow.down.circle") {
                    guard let url else { return }
                    if mode == .web && browser.tab == nil { browser.newTab() }
                    center.enqueue(url, mode: mode, webView: browser.tab?.view, options: hlsOptions)
                    dismiss()
                }.disabled(!permitted || url.map(MediaPolicy.secureWebURL) != true)
            }
        }.navigationTitle("영상 저장")
            .task { await scan() }
    }

    private static func knownExtension(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "m3u8"].contains(ext) ? ext : nil
    }

    /// Same request the queue makes before a public transfer, surfaced early so the
    /// confirmation can show real size and format (spec §4.1 "다운로드 확인").
    @MainActor private func probe(_ url: URL) async {
        guard !checkingInfo else { return }
        checkingInfo = true
        infoError = nil
        defer { checkingInfo = false }
        do {
            let bytes = try await PublicSourceCheck.verify(url, mode: mode, hosts: center.library.publicHosts)
            fileInfo = DownloadCenter.fileSummary(name: url.lastPathComponent, ext: mode == .hls ? "m3u8" : Self.knownExtension(url) ?? "mp4",
                                                  bytes: mode == .hls ? nil : bytes)
            if mode == .hls { fileInfo = "\(MediaPolicy.displayName(url.deletingPathExtension().lastPathComponent)) · HLS VOD · 크기는 iOS가 저장하며 선택 화질에 따라 다름" }
        } catch {
            infoError = MediaError.classify(error).message
        }
    }

    @MainActor private func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let found = await browser.detectedMedia()
        guard !Task.isCancelled else { return }
        candidates = found
    }
}
