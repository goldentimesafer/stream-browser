import AVKit
import Photos
import SwiftUI
import UIKit

struct LibraryScreen: View {
    @ObservedObject var center: DownloadCenter
    let play: (SavedMedia) -> Void
    @State private var search = ""
    @State private var newestFirst = true
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var pendingDelete: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var renameItem: SavedMedia?
    @State private var renameValue = ""
    @State private var showRename = false
    @State private var exportItem: ExportItem?
    @State private var exportCopy: URL?
    @State private var retryRow: DownloadRow?
    @State private var showRetry = false
    @State private var retryAddress = ""
    @Environment(\.scenePhase) private var phase

    private var results: [SavedMedia] {
        let matches = center.library.media.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return matches.sorted { newestFirst ? $0.date > $1.date : $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                if !center.rows.isEmpty {
                    Section("다운로드") {
                        ForEach(center.rows) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.name).font(.headline).lineLimit(1)
                                Text(row.mode.label + " · " + row.state).font(.caption).foregroundStyle(.secondary)
                                if let progress = row.progress { ProgressView(value: progress) }
                                if row.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)).font(.caption) }
                                if let error = row.failure {
                                    Text(error).font(.footnote).foregroundStyle(.secondary)
                                    if row.mode.usesSystemSession {
                                        Button("주소를 다시 입력해 재시도") {
                                            retryRow = row; retryAddress = ""; showRetry = true
                                        }.buttonStyle(.borderless)
                                    }
                                    Button("기록 지우기") { center.cancel(row.id) }.buttonStyle(.borderless)
                                } else {
                                    Button("취소", role: .destructive) { center.cancel(row.id) }.buttonStyle(.borderless)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section("저장한 영상") {
                    if results.isEmpty { Text(search.isEmpty ? "저장한 영상이 없습니다." : "검색 결과가 없습니다.").foregroundStyle(.secondary) }
                    ForEach(results) { item in
                        Button {
                            if selecting {
                                if !selected.insert(item.id).inserted { selected.remove(item.id) }
                            } else if center.localURL(item) != nil { play(item) }
                            else { center.notice = "저장한 파일을 찾을 수 없습니다. 항목을 삭제하고 다시 저장하세요." }
                        } label: {
                            HStack {
                                Image(systemName: selecting ? (selected.contains(item.id) ? "checkmark.circle.fill" : "circle") : "play.circle")
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text(item.name).foregroundStyle(.primary).lineLimit(1)
                                    HStack {
                                        Text(item.kind == .hls ? "HLS · 앱 내 재생" : "영상 파일")
                                        if let bytes = item.bytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(minHeight: 44)
                        }.contextMenu {
                            Button("이름 변경", systemImage: "pencil") { renameItem = item; renameValue = item.name; showRename = true }
                            if item.kind == .file {
                                Button("공유 또는 파일 앱에 저장", systemImage: "square.and.arrow.up") { share(item) }
                                Button("사진 앱에 저장", systemImage: "photo") { saveToPhotos(item) }
                            }
                            Button("삭제", systemImage: "trash", role: .destructive) { askDelete([item.id]) }
                        }
                    }
                }
            }
            .navigationTitle("저장함")
            .searchable(text: $search, prompt: "저장한 영상 검색")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(newestFirst ? "오래된 순" : "최신 순") { newestFirst.toggle() }
                        Button(selecting ? "선택 취소" : "여러 영상 선택") { selecting.toggle(); selected.removeAll() }
                        if !selected.isEmpty { Button("선택한 영상 삭제", role: .destructive) { askDelete(selected) } }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("저장함 메뉴") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selected.isEmpty {
                    Button("선택한 \(selected.count)개 삭제", role: .destructive) { askDelete(selected) }
                        .frame(maxWidth: .infinity, minHeight: 48).background(.regularMaterial)
                }
            }
            .confirmationDialog("영상 \(pendingDelete.count)개를 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    center.delete(pendingDelete); pendingDelete.removeAll(); selected.removeAll(); selecting = false
                }
            } message: {
                let bytes = center.library.media.filter { pendingDelete.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
                Text(bytes > 0 ? "확인된 일반 영상 용량 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "선택한 영상과 재생 기록을 정리합니다.")
            }
            .alert("영상 이름 변경", isPresented: $showRename) {
                TextField("이름", text: $renameValue)
                Button("저장") {
                    if let id = renameItem?.id {
                        center.modifyLibrary { data in
                            if let index = data.media.firstIndex(where: { $0.id == id }) {
                                data.media[index].name = MediaPolicy.displayName(renameValue)
                            }
                        }
                    }
                }
                Button("취소", role: .cancel) { }
            }
            .alert("다운로드 재시도", isPresented: $showRetry) {
                TextField("공개 HTTPS 주소", text: $retryAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("시작") {
                    guard let row = retryRow, let url = URL(string: retryAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
                          MediaPolicy.secureWebURL(url) else { center.notice = MediaError.address.message; return }
                    center.cancel(row.id)
                    center.enqueue(url, mode: row.mode)
                }
                Button("취소", role: .cancel) { }
            }
            .sheet(item: $exportItem, onDismiss: cleanupExport) { item in ActivitySheet(url: item.url) }
            .onChange(of: phase) { _, value in if value == .background { exportItem = nil } }
            .task {
                while !Task.isCancelled {
                    center.refreshProgress()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    private func askDelete(_ ids: Set<UUID>) { pendingDelete = ids; confirmDelete = true }

    private func share(_ item: SavedMedia) {
        guard let url = center.export(item) else { return }
        exportCopy = url
        exportItem = ExportItem(url: url)
    }

    private func cleanupExport() {
        if let exportCopy { center.removeExport(exportCopy) }
        exportCopy = nil
    }

    private func saveToPhotos(_ item: SavedMedia) {
        Task { @MainActor in
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                center.notice = "사진 앱에 추가하려면 사진 추가 권한이 필요합니다."
                return
            }
            guard let url = center.localURL(item), item.kind == .file else { return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                center.notice = "사진 앱에 영상을 저장했습니다."
            } catch { center.notice = "사진 앱에서 이 영상을 저장할 수 없습니다. 파일 앱으로 내보낼 수 있습니다." }
        }
    }
}

private struct ExportItem: Identifiable { let id = UUID(); let url: URL }

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct OfflinePlayer: View {
    private struct StoredTracks: Identifiable {
        let id: String
        let group: AVMediaSelectionGroup
        let options: [AVMediaSelectionOption]
    }

    let item: SavedMedia
    @ObservedObject var center: DownloadCenter
    let close: () -> Void
    @State private var player: AVPlayer?
    @State private var rate: Float = 1
    @State private var error: String?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var storedTracks: [StoredTracks] = []
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let player {
                    PlayerSurface(player: player).background(.black)
                    if let error { Text(error).font(.footnote).padding() }
                } else if let error {
                    ContentUnavailableView("재생할 수 없음", systemImage: "play.slash", description: Text(error))
                } else { ProgressView().frame(maxHeight: .infinity) }
            }
            .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기", systemImage: "xmark") { rememberAndStop(); close() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { value in
                            Button("\(value.formatted())배") {
                                rate = value
                                player?.defaultRate = value
                                if player?.rate != 0 { player?.rate = value }
                            }
                        }
                    } label: { Text("\(rate.formatted())×").accessibilityLabel("재생 배속") }
                }
                if !storedTracks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(storedTracks) { tracks in
                                Section(tracks.id) {
                                    if tracks.group.allowsEmptySelection {
                                        Button("끄기") { player?.currentItem?.select(nil, in: tracks.group) }
                                    }
                                    ForEach(tracks.options, id: \.self) { option in
                                        Button(option.displayName) { player?.currentItem?.select(option, in: tracks.group) }
                                    }
                                }
                            }
                        } label: { Image(systemName: "captions.bubble").accessibilityLabel("오프라인 오디오와 자막") }
                    }
                }
            }
        }
        .task {
            guard let url = center.localURL(item) else { error = "파일을 찾을 수 없습니다."; return }
            let asset = LocalMediaAsset.make(url, kind: item.kind)
            if item.kind == .hls, asset.assetCache?.isPlayableOffline != true {
                error = "오프라인 자산이 없습니다. 다시 저장하세요."
                return
            }
            guard (try? await asset.load(.isPlayable)) == true, !Task.isCancelled else {
                error = "기기에서 재생할 수 없는 영상입니다."
                return
            }
            let playerItem = AVPlayerItem(asset: asset)
            let value = AVPlayer()
            var tracks: [StoredTracks] = []
            if item.kind == .hls, let cache = asset.assetCache {
                value.appliesMediaSelectionCriteriaAutomatically = false
                if let audio = try? await asset.loadMediaSelectionGroup(for: .audible) {
                    let options = cache.mediaSelectionOptions(in: audio)
                    if let cachedAudio = options.first { playerItem.select(cachedAudio, in: audio) }
                    if !options.isEmpty { tracks.append(StoredTracks(id: "오디오", group: audio, options: options)) }
                }
                if let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible) {
                    let options = cache.mediaSelectionOptions(in: subtitles)
                    if subtitles.allowsEmptySelection { playerItem.select(nil, in: subtitles) }
                    else if let option = options.first { playerItem.select(option, in: subtitles) }
                    if !options.isEmpty { tracks.append(StoredTracks(id: "자막", group: subtitles, options: options)) }
                }
            }
            guard !Task.isCancelled, phase == .active, center.unlocked else { return }
            value.replaceCurrentItem(with: playerItem)
            statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { item, _ in
                if item.status == .failed {
                    Task { @MainActor in error = "이 영상을 재생할 수 없습니다." }
                }
            }
            value.allowsExternalPlayback = false
            value.defaultRate = rate
            if center.library.rememberPosition, let position = item.position, position.isFinite, position > 0 {
                value.seek(to: CMTime(seconds: position, preferredTimescale: 600), completionHandler: { _ in })
            }
            player = value
            storedTracks = tracks
        }
        .onChange(of: phase) { _, value in if value != .active { rememberAndStop() } }
        .onDisappear { rememberAndStop() }
    }

    private func rememberAndStop() {
        guard let player else { return }
        player.pause()
        if center.library.rememberPosition, center.unlocked {
            let seconds = player.currentTime().seconds
            if seconds.isFinite && seconds >= 0 {
                center.modifyLibrary { data in
                    if let index = data.media.firstIndex(where: { $0.id == item.id }) { data.media[index].position = seconds }
                }
            }
        }
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        self.player = nil
    }
}

private struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = false
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
