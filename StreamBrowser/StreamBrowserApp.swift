import LocalAuthentication
import SwiftUI
import UIKit

@MainActor
final class BrowserAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadCenter.shared.acceptSystemEvents(identifier, completion: completionHandler)
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        if DownloadCenter.shared.unlocked { DownloadCenter.shared.unlock() }
    }
}

@MainActor
private enum WindowPrivacyCover {
    private static let tag = 78493

    static func setVisible(_ visible: Bool) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if visible {
                if let cover = window.viewWithTag(tag) { window.bringSubviewToFront(cover); continue }
                let cover = UIView(frame: window.bounds)
                cover.tag = tag
                cover.backgroundColor = .systemBackground
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.accessibilityViewIsModal = true
                window.addSubview(cover)
            } else {
                window.viewWithTag(tag)?.removeFromSuperview()
            }
        }
    }
}

@main
struct StreamBrowserApp: App {
    @UIApplicationDelegateAdaptor(BrowserAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { BrowserRoot() }
    }
}

enum BrowserSection: String, CaseIterable {
    case browser = "탐색", library = "저장함", settings = "설정"

    var icon: String {
        switch self {
        case .browser: "safari"
        case .library: "tray.full"
        case .settings: "gearshape"
        }
    }
}

struct BrowserRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var browser = PrivateBrowser()
    @StateObject private var downloads = DownloadCenter.shared
    @AppStorage("appLockEnabled") private var lockEnabled = true
    @State private var locked = true
    @State private var section = BrowserSection.browser
    @State private var authenticating = false
    @State private var authentication: LAContext?
    @State private var authenticationAttempt: UUID?
    @State private var authenticationMessage: String?
    @State private var playback: SavedMedia?
    @State private var showErase = false
    @State private var transientReset = UUID()
    @State private var privacyCover = false

    var body: some View {
        ZStack {
            if locked {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield").font(.system(size: 48)).accessibilityHidden(true)
                    Text("Stream Browser").font(.largeTitle.bold())
                    if let authenticationMessage { Text(authenticationMessage).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Button("잠금 해제", action: authenticate).buttonStyle(.borderedProminent).disabled(authenticating)
                    if authenticating { ProgressView() }
                }
                .padding()
            } else {
                VStack(spacing: 0) {
                    if let playback {
                        OfflinePlayer(item: playback, center: downloads) { self.playback = nil }
                    } else {
                        Group {
                            switch section {
                            case .browser: BrowserScreen(browser: browser, center: downloads)
                            case .library: LibraryScreen(center: downloads) { playback = $0 }
                            case .settings:
                                SettingsScreen(browser: browser, center: downloads, lockEnabled: $lockEnabled,
                                               erase: { showErase = true })
                            }
                        }
                        .id(transientReset)
                        Divider()
                        HStack(spacing: 0) {
                            ForEach(BrowserSection.allCases, id: \.self) { item in
                                Button {
                                    if item != .browser { browser.tab?.view.pauseAllMediaPlayback(completionHandler: nil) }
                                    section = item
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: item.icon).font(.title3)
                                        Text(item.rawValue).font(.caption)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .foregroundStyle(item == section ? Color.accentColor : Color.secondary)
                                .accessibilityAddTraits(item == section ? .isSelected : [])
                            }
                        }
                        .padding(.top, 4)
                        .background(.regularMaterial)
                    }
                }
            }
            if scenePhase != .active || privacyCover {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.secondary) }
                    .accessibilityHidden(true)
            }
        }
        .task {
            browser.prepare()
            if scenePhase == .active { enterForeground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            privacyCover = true
            WindowPrivacyCover.setVisible(true)
            browser.setActive(false)
            playback = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { enterForeground() }
            else {
                browser.setActive(false)
                playback = nil
                if phase == .background {
                    authentication?.invalidate()
                    authentication = nil
                    authenticationAttempt = nil
                    authenticating = false
                    downloads.setForeground(false)
                    downloads.lock()
                    locked = true
                    transientReset = UUID()
                }
            }
        }
        .alert("Stream Browser", isPresented: Binding(get: { downloads.notice != nil && !locked },
                                                       set: { if !$0 { downloads.notice = nil } })) {
            Button("확인", role: .cancel) { downloads.notice = nil }
        } message: { Text(downloads.notice ?? "") }
        .confirmationDialog("이 영상을 비공개로 저장할까요?", isPresented: Binding(
            get: { downloads.webOffer != nil && !locked },
            set: { value in
                if !value {
                    let offer = downloads.webOffer
                    Task { @MainActor in
                        if downloads.webOffer == offer { downloads.answerWebOffer(save: false) }
                    }
                }
            }), titleVisibility: .visible) {
            Button("저장") { downloads.answerWebOffer(save: true) }
            Button("취소", role: .cancel) { downloads.answerWebOffer(save: false) }
        } message: { Text("현재 탭의 웹 세션에서 영상을 내려받습니다. 저장한 영상은 세션을 닫은 뒤에도 기기에 남습니다.") }
        .confirmationDialog("이 기기의 Stream Browser 데이터를 삭제할까요?", isPresented: $showErase, titleVisibility: .visible) {
            Button("앱 데이터 삭제", role: .destructive) {
                Task { @MainActor in
                    browser.clear()
                    guard await downloads.clear() else { return }
                    lockEnabled = true
                    downloads.lock()
                    browser.setActive(false)
                    locked = true
                    section = .browser
                }
            }
        } message: { Text("다운로드 작업, 저장 영상, 북마크와 설정을 정리합니다. 내보낸 사본은 사용자가 관리합니다.") }
    }

    private func enterForeground() {
        privacyCover = false
        WindowPrivacyCover.setVisible(false)
        downloads.setForeground(true)
        if !lockEnabled { completeUnlock(); return }
        if !locked { browser.setActive(true); downloads.unlock() }
    }

    private func authenticate() {
        guard !authenticating else { return }
        guard lockEnabled else { completeUnlock(); return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authenticationMessage = "잠금 해제에 기기 암호가 필요합니다. iPhone 설정에서 암호를 설정하세요."
            return
        }
        authenticating = true
        authentication = context
        let attempt = UUID()
        authenticationAttempt = attempt
        Task { @MainActor in
            let result = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "저장한 영상과 비공개 탭을 열려면 인증하세요.")) == true
            guard authenticationAttempt == attempt else { return }
            authenticating = false
            authentication = nil
            authenticationAttempt = nil
            if result { completeUnlock() }
            else { authenticationMessage = "인증을 완료하지 못했습니다. 다시 시도하세요." }
        }
    }

    private func completeUnlock() {
        locked = false
        authenticationMessage = nil
        browser.setActive(scenePhase == .active)
        downloads.unlock()
    }
}
