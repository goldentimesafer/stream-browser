import LocalAuthentication
import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var browser: PrivateBrowser
    @ObservedObject var center: DownloadCenter
    @Binding var lockEnabled: Bool
    let erase: () -> Void
    @State private var host = ""
    @State private var bytes: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("프라이버시") {
                    Toggle("앱 잠금", isOn: $lockEnabled)
                    LabeledContent("추적 차단", value: browser.rulesStatus)
                    Text("탐색 기록과 쿠키를 앱에 저장하지 않습니다. 북마크와 다운로드는 기기에 남습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        TextField("media.example.com", text: $host).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("추가", action: addHost).disabled(MediaPolicy.publicHost(host) == nil)
                    }
                    ForEach(center.library.publicHosts.sorted(), id: \.self) { source in Text(source) }
                        .onDelete { offsets in
                            let sorted = center.library.publicHosts.sorted()
                            center.modifyLibrary { data in for index in offsets { data.publicHosts.remove(sorted[index]) } }
                        }
                } header: { Text("공개 다운로드 출처") } footer: {
                    Text("공개 파일과 HLS를 저장할 때만 사용합니다. 직접 관리하거나 신뢰하는 호스트의 이름을 등록하세요. HLS가 별도 미디어 호스트를 쓰면 그 이름도 필요합니다.")
                }
                Section {
                    if center.libraryRecoveryRequired {
                        Text("저장 목록을 읽을 수 없습니다. 손상된 원본과 영상은 보존한 채 백업·파일에서 목록을 복구합니다.")
                        Button("저장 목록 복구") { center.repairLibrary() }
                    } else {
                        Button("저장 작업 복구") { center.unlock() }
                    }
                    Toggle("재생 위치 기억", isOn: Binding(get: { center.library.rememberPosition }, set: { enabled in
                        center.modifyLibrary { data in
                            data.rememberPosition = enabled
                            if !enabled { for index in data.media.indices { data.media[index].position = nil } }
                        }
                    }))
                    LabeledContent("앱 관리 파일", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    Text("앱이 참조하는 HLS 패키지와 임시 파일을 포함합니다. 시스템이 별도로 관리하는 전송 캐시는 포함되지 않을 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
                    Button("사용량 다시 계산") { bytes = center.usage() }
                } header: { Text("저장함") } footer: {
                    Text("앱은 저장한 일반 영상과 저장 목록에 백업 제외를 설정합니다. HLS는 저장함 등록 시 제외를 설정하며, 등록 전 파일은 iOS가 관리합니다. 기기 이전이 필요한 일반 영상은 파일 앱에 따로 내보내세요.")
                }
                Section { Button(center.isErasing ? "삭제 처리 중…" : "앱 데이터 삭제", role: .destructive, action: erase)
                        .disabled(center.isErasing || center.libraryRecoveryRequired) }
                Section {
                    if center.diagnostics.isEmpty {
                        Text("기록된 다운로드 실패가 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(center.diagnostics) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.mode.label + " · " + entry.code)
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !center.diagnostics.isEmpty {
                        Button("진단 기록 지우기", role: .destructive) { center.clearDiagnostics() }
                    }
                } header: { Text("다운로드 진단") } footer: {
                    Text("최근 \(DiagnosticLog.limit)건의 실패 오류 코드와 저장 방식만 기록합니다. 주소·호스트·파일 이름은 저장하지 않습니다.")
                }
                Section {
                    LabeledContent("버전", value: Self.versionLabel)
                } footer: { Text("괄호 안은 GitHub Actions 빌드 번호입니다. 설치된 빌드를 구분할 때 사용합니다.") }
            }
            .navigationTitle("설정")
            .onAppear { bytes = center.usage() }
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func addHost() {
        guard let name = MediaPolicy.publicHost(host) else { return }
        center.modifyLibrary { $0.publicHosts.insert(name) }
        host = ""
    }
}
