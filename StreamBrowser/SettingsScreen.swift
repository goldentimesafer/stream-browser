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
                Section("저장함") {
                    Toggle("재생 위치 기억", isOn: Binding(get: { center.library.rememberPosition }, set: { enabled in
                        center.modifyLibrary { data in
                            data.rememberPosition = enabled
                            if !enabled { for index in data.media.indices { data.media[index].position = nil } }
                        }
                    }))
                    LabeledContent("앱 관리 파일", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    Text("시스템에서 보관하는 HLS 용량은 이 수치에서 제외됩니다.").font(.footnote).foregroundStyle(.secondary)
                    Button("사용량 다시 계산") { bytes = center.usage() }
                }
                Section { Button("앱 데이터 삭제", role: .destructive, action: erase) }
            }
            .navigationTitle("설정")
            .onAppear { bytes = center.usage() }
        }
    }

    private func addHost() {
        guard let name = MediaPolicy.publicHost(host) else { return }
        center.modifyLibrary { $0.publicHosts.insert(name) }
        host = ""
    }
}
