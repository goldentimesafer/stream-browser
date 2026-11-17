import AVKit
import Photos
import SwiftUI
import UIKit

struct LibraryScreen: View {
    @ObservedObject var center: DownloadCenter
    let isSelected: Bool
    let play: (SavedMedia) -> Void
    @State private var search = ""
    @State private var filter = LibraryFilter.all
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var results: [SavedMedia] {
        let matches = center.library.media.filter {
            filter.includes($0.kind) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
        return matches.sorted { newestFirst ? $0.date > $1.date : $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !center.rows.isEmpty { downloadsSection }
                    filterChips
                    mediaGrid
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("저장함")
            .searchable(text: $search, prompt: "저장한 미디어 검색")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(newestFirst ? "오래된 순" : "최신 순") { newestFirst.toggle() }
                        Button(selecting ? "선택 취소" : "여러 항목 선택") { selecting.toggle(); selected.removeAll() }
                        if !selected.isEmpty { Button("선택한 항목 삭제", role: .destructive) { askDelete(selected) } }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("저장함 메뉴") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selected.isEmpty {
                    Button("선택한 \(selected.count)개 삭제", role: .destructive) { askDelete(selected) }
                        .frame(maxWidth: .infinity, minHeight: 48).background(.regularMaterial)
                }
            }
            .confirmationDialog("저장 항목 \(pendingDelete.count)개를 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    center.delete(pendingDelete); pendingDelete.removeAll(); selected.removeAll(); selecting = false
                }
            } message: {
                let bytes = center.library.media.filter { pendingDelete.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
                Text(bytes > 0 ? "확인된 용량 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "선택한 파일과 재생 기록을 정리합니다.")
            }
            .alert("이름 변경", isPresented: $showRename) {
                TextField("이름", text: $renameValue).autocorrectionDisabled()
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
        }
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("다운로드").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(center.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(row.mode.label + " · " + row.state.label).font(.caption).foregroundStyle(.secondary)
                    if let progress = row.progress { ProgressView(value: progress) }
                    if row.bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = row.failure {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        if row.mode.usesSystemSession {
                            Button("주소를 다시 입력해 재시도") {
                                retryRow = row; retryAddress = ""; showRetry = true
                            }
                        }
                        Button("기록 지우기") { center.cancel(row.id) }
                    } else {
                        if center.canPause(row.id) {
                            Button(row.paused ? "계속 다운로드" : "일시정지") { center.togglePause(row.id) }
                        }
                        Button("취소", role: .destructive) { center.cancel(row.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases, id: \.self) { chip in
                    Button {
                        filter = chip
                        selected.removeAll()
                    } label: {
                        Text(chip.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .frame(minHeight: 44)
                            .foregroundStyle(chip == filter ? Color.accentColor : Color.primary)
                            .background(
                                chip == filter ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemGroupedBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chip == filter ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var mediaGrid: some View {
        let items = results
        if items.isEmpty {
            let message = search.isEmpty ? filter.emptyMessage : "검색 결과가 없습니다."
            ContentUnavailableView(message, systemImage: "tray")
                .frame(maxWidth: .infinity)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    mediaCard(item)
                }
            }
        }
    }

    private func mediaCard(_ item: SavedMedia) -> some View {
        Button {
            if selecting {
                if !selected.insert(item.id).inserted { selected.remove(item.id) }
            } else if center.localURL(item) != nil { play(item) }
            else { center.notice = "저장한 파일을 찾을 수 없습니다. 항목을 삭제하고 다시 저장하세요." }
        } label: {
            LibraryMediaCard(item: item, showsSelection: selecting, isChecked: selected.contains(item.id),
                             showsProgress: center.library.rememberPosition,
                             canLoadPreview: isSelected && phase == .active,
                             localURL: { center.localURL(item) })
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
        .contextMenu {
            Button("이름 변경", systemImage: "pencil") { renameItem = item; renameValue = item.name; showRename = true }
            if item.kind != .hls {
                Button("공유 또는 파일 앱에 저장", systemImage: "square.and.arrow.up") { share(item) }
            }
            if item.kind == .file {
                Button("사진 앱에 저장", systemImage: "photo") { saveToPhotos(item) }
            }
            Button("삭제", systemImage: "trash", role: .destructive) { askDelete([item.id]) }
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

private enum LibraryFilter: String, CaseIterable {
    case all = "전체", video = "동영상", audio = "오디오"

    func includes(_ kind: MediaKind) -> Bool {
        switch self {
        case .all: true
        case .video: kind != .audio
        case .audio: kind == .audio
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "저장한 미디어가 없습니다."
        case .video: "저장한 동영상이 없습니다."
        case .audio: "저장한 오디오가 없습니다."
        }
    }
}

private struct LibraryMediaCard: View {
    let item: SavedMedia
    let showsSelection: Bool
    let isChecked: Bool
    let showsProgress: Bool
    let canLoadPreview: Bool
    let localURL: () -> URL?

    @State private var duration: Double?
    @State private var thumbnail: CGImage?

    private var mediaLabel: String {
        switch item.kind {
        case .file: "동영상"
        case .hls: "HLS · 앱 내 재생"
        case .audio: "오디오"
        }
    }

    private var progress: Double? {
        guard showsProgress, let duration else { return nil }
        let position = item.position ?? 0
        guard position.isFinite else { return nil }
        return min(1, max(0, position / duration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(mediaLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("재생 진행률")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilitySummary)
        .task(id: canLoadPreview) {
            clearPreview()
            if canLoadPreview { await loadPreview() }
        }
        .onDisappear { clearPreview() }
    }

    private var preview: some View {
        Rectangle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .aspectRatio(16 / 9.0, contentMode: .fit)
            .overlay {
                if canLoadPreview, let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.kind == .audio ? "waveform" : "play.rectangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Text(durationText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if showsSelection {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.65), in: Circle())
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
    }

    private var accessibilitySummary: String {
        var values = [mediaLabel]
        if duration != nil { values.append("재생 시간 \(durationText)") }
        if let progress { values.append("재생 진행률 \(progress.formatted(.percent.precision(.fractionLength(0))))") }
        return values.joined(separator: ", ")
    }

    private var durationText: String {
        guard let duration, let total = Int(exactly: duration.rounded(.down)) else { return "—:—" }
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    @MainActor private func loadPreview() async {
        guard let url = localURL() else { return }
        let asset = LocalMediaAsset.make(url, kind: item.kind)
        if item.kind == .hls, asset.assetCache?.isPlayableOffline != true { return }
        let seconds = (try? await asset.load(.duration))?.seconds
        guard !Task.isCancelled else { return }
        if let seconds, seconds.isFinite, seconds > 0 { duration = seconds }
        guard item.kind != .audio else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let time = CMTime(seconds: min((duration ?? 0) * 0.1, 2), preferredTimescale: 600)
        let frame = try? await generator.image(at: time)
        guard !Task.isCancelled else { return }
        thumbnail = frame?.image
    }

    private func clearPreview() {
        thumbnail = nil
        duration = nil
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
    @State private var audioConfigured = false
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
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                audioConfigured = true
            } catch {
                self.error = "영상 오디오를 준비하지 못했습니다. 다시 열어 주세요."
                return
            }
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
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            player?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable { player?.pause() }
        }
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
        if audioConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioConfigured = false
        }
    }
}

private struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
