import SwiftUI
import AVFoundation
import PhotosUI
import Photos
import QuartzCore

/// 再生・同期・取り込み・書き出しをまとめて扱う
@MainActor
final class Engine: ObservableObject {
    @Published var state: ProjectState { didSet { Storage.save(state) } }
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var waitingYT = false
    @Published private(set) var importing: [UUID: Double] = [:]
    @Published private(set) var exportProgress: Double?
    @Published var message: String?

    let player = AVPlayer()
    let yt = YouTubeController()

    private var built: BuiltComposition?
    private var rebuildTask: Task<Void, Never>?
    private var timer: Timer?
    private var seekingPlayer = false
    // 再生位置の時計: base 秒 + (今 - wall)
    private var base: Double = 0
    private var wall: CFTimeInterval = CACurrentMediaTime()

    init() {
        var s = Storage.load()
        s.clips.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if let song = s.song, case let .file(f, _) = song.source,
           !FileManager.default.fileExists(atPath: Storage.mediaDir.appendingPathComponent(f).path) {
            s.song = nil
        }
        state = s
        player.actionAtItemEnd = .pause

        yt.onReady = { [weak self] title, dur in self?.ytReady(title: title, duration: dur) }
        yt.onError = { [weak self] code in self?.ytFailed(code) }
        if let song = state.song, case let .youtube(id, _) = song.source { yt.load(id: id) }

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        scheduleRebuild(delay: 0)
    }

    // MARK: - 時計

    private var clock: Double {
        guard isPlaying, !waitingYT else { return base }
        return min(duration, base + (CACurrentMediaTime() - wall))
    }

    private var compDuration: Double { built?.duration ?? 0 }

    /// 準備のできた YouTube 原曲
    private var ytSong: Song? {
        guard let s = state.song, s.isYouTube, yt.ready, yt.duration > 0 else { return nil }
        return s
    }

    private func ytInRange(_ t: Double) -> Bool {
        guard let s = ytSong else { return false }
        let local = t - s.offset
        return local >= 0 && local < yt.duration - 0.05
    }

    // MARK: - 再生

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard duration > 0 else { return }
        if base >= duration - 0.05 { base = 0 }
        wall = CACurrentMediaTime()
        isPlaying = true
        if let s = ytSong, ytInRange(base) {
            // YouTube が鳴り始めるまで時計を止めて待つ
            waitingYT = true
            player.pause()
            yt.seek(base - s.offset)
            yt.play()
        } else {
            waitingYT = false
            startPlayer(at: base)
        }
    }

    func pause() {
        base = clock
        isPlaying = false
        waitingYT = false
        player.pause()
        yt.pause()
        time = base
    }

    func seek(_ t: Double) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        base = min(max(t, 0), duration)
        wall = CACurrentMediaTime()
        time = base
        player.seek(to: base.cm, toleranceBefore: .zero, toleranceAfter: .zero)
        if let s = ytSong { yt.seek(min(max(base - s.offset, 0), yt.duration - 0.1)) }
        if wasPlaying { play() }
    }

    private func finish() {
        pause()
        seek(0)
    }

    private func startPlayer(at t: Double) {
        guard t < compDuration - 0.05 else { player.pause(); return }
        seekingPlayer = true
        player.seek(to: t.cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekingPlayer = false
                if self.isPlaying && !self.waitingYT { self.player.rate = 1 }
            }
        }
    }

    /// YouTube の時計に演奏動画を合わせる(小さいずれは速度の微調整、大きいずれはシーク)
    private func syncPlayer(to t: Double) {
        guard !seekingPlayer else { return }
        guard t < compDuration - 0.05 else { if player.rate != 0 { player.pause() }; return }
        switch player.timeControlStatus {
        case .paused:
            startPlayer(at: t)
        case .playing:
            let d = player.currentTime().sec - t
            if abs(d) > 0.3 { startPlayer(at: t); return }
            let r: Float = abs(d) < 0.03 ? 1 : (d > 0 ? 0.97 : 1.03)
            if player.rate != r { player.rate = r }
        default:
            break
        }
    }

    private func tick() {
        guard isPlaying else { return }
        let now = CACurrentMediaTime()

        if let s = ytSong, ytInRange(clock) {
            let st = yt.state
            if st == 1 {
                let t = yt.currentTime + s.offset
                if waitingYT {
                    waitingYT = false
                    base = t; wall = now
                    startPlayer(at: t)
                } else if abs(t - clock) > 0.08 {
                    base = t; wall = now
                }
            } else if !waitingYT && st != 0 {
                // 読み込み中や未開始: 時計と演奏動画を止めて YouTube を待つ
                base = clock
                waitingYT = true
                player.pause()
                if st != 3 { yt.seek(base - s.offset) }
            }
            if waitingYT && (st == 2 || st == 5 || st == -1) { yt.play() }
            if !waitingYT { syncPlayer(to: clock) }
        } else {
            if waitingYT {
                waitingYT = false
                wall = now
                startPlayer(at: base)
            }
            if yt.state == 1 || yt.state == 3 { yt.pause() }
            // YouTube が鳴っていない区間は演奏動画の再生位置が基準
            if player.timeControlStatus == .playing, !seekingPlayer {
                base = player.currentTime().sec; wall = now
            } else if !seekingPlayer, player.timeControlStatus == .paused, clock < compDuration - 0.05 {
                startPlayer(at: clock)
            }
        }

        let c = clock
        time = c
        if c >= duration - 0.02 { finish() }
    }

    // MARK: - タイムラインの組み直し

    func scheduleRebuild(delay: Double = 0.25) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            await self.rebuild()
        }
    }

    private func rebuild() async {
        let snapshot = state
        do {
            let b = try await CompositionBuilder.build(state: snapshot)
            if Task.isCancelled { return }
            built = b
            let item = AVPlayerItem(asset: b.composition)
            item.videoComposition = b.videoComposition
            item.audioMix = CompositionBuilder.audioMix(state: state, built: b)
            item.audioTimePitchAlgorithm = .timeDomain
            let resume = isPlaying
            if resume { base = clock; wall = CACurrentMediaTime() }
            player.replaceCurrentItem(with: item)
            player.volume = state.masterVolume
            updateDuration()
            if resume {
                if !waitingYT { startPlayer(at: base) }
            } else {
                player.seek(to: base.cm, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } catch {
            message = "動画の読み込みに失敗しました: \(error.localizedDescription)"
        }
    }

    private func updateDuration() {
        var d = compDuration
        if let s = state.song, s.isYouTube, yt.duration > 0 { d = max(d, yt.duration + s.offset) }
        duration = max(0, d)
        if base > duration { base = duration; time = base }
    }

    /// 音量・ミュート・ソロの変更(タイムラインは組み直さない)
    func mixChanged() {
        player.volume = state.masterVolume
        if let b = built { player.currentItem?.audioMix = CompositionBuilder.audioMix(state: state, built: b) }
        if state.isYouTubeSong {
            yt.setVolume(CompositionBuilder.effectiveSongVolume(state) * state.masterVolume)
        }
    }

    // MARK: - 演奏動画

    func importVideos(_ items: [PhotosPickerItem]) {
        for item in items {
            let key = UUID()
            importing[key] = 0
            let progress = item.loadTransferable(type: ImportedMovie.self) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.importing[key] = nil
                    switch result {
                    case let .success(movie?):
                        let n = self.state.clips.count + 1
                        self.state.clips.append(Clip(fileName: movie.fileName, name: "演奏 \(n)"))
                        self.scheduleRebuild(delay: 0)
                    case .success(nil):
                        self.message = "動画を読み込めませんでした"
                    case let .failure(error):
                        self.message = "動画を読み込めませんでした: \(error.localizedDescription)"
                    }
                }
            }
            // iCloud からのダウンロードを含む取り込みの進み具合
            Task { @MainActor [weak self] in
                while true {
                    guard let self, self.importing[key] != nil else { return }
                    self.importing[key] = progress.fractionCompleted
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }

    func removeClip(_ id: UUID) {
        if let c = state.clips.first(where: { $0.id == id }) { Storage.remove(c.fileName) }
        state.clips.removeAll { $0.id == id }
        scheduleRebuild(delay: 0)
    }

    func clipStartHere(_ id: UUID) {
        guard let i = state.clips.firstIndex(where: { $0.id == id }) else { return }
        state.clips[i].offset = (time * 100).rounded() / 100
        scheduleRebuild(delay: 0)
    }

    // MARK: - 原曲

    func importSong(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = try Storage.importFile(url)
            removeSong(rebuild: false)
            state.song = Song(source: .file(fileName: name, name: url.deletingPathExtension().lastPathComponent))
            scheduleRebuild(delay: 0)
        } catch {
            message = "原曲を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func useYouTube(_ text: String) {
        guard let id = YouTubeController.parseID(text) else {
            message = "YouTubeのリンクを読み取れませんでした"
            return
        }
        pause()
        removeSong(rebuild: false)
        state.song = Song(source: .youtube(id: id, title: "YouTube"))
        yt.load(id: id)
        scheduleRebuild(delay: 0)
    }

    func removeSong(rebuild: Bool = true) {
        if let s = state.song {
            switch s.source {
            case let .file(f, _): Storage.remove(f)
            case .youtube: yt.unload()
            }
        }
        state.song = nil
        if rebuild { scheduleRebuild(delay: 0) }
    }

    func songStartHere() {
        guard state.song != nil else { return }
        state.song?.offset = (time * 100).rounded() / 100
        scheduleRebuild(delay: 0)
    }

    private func ytReady(title: String, duration: Double) {
        if var s = state.song, case let .youtube(id, _) = s.source, !title.isEmpty {
            s.source = .youtube(id: id, title: title)
            state.song = s
        }
        updateDuration()
        mixChanged()
    }

    private func ytFailed(_ code: Int) {
        message = (code == 101 || code == 150 || code == 152)
            ? "この動画は埋め込み再生が許可されていません。別の動画を試してください"
            : "YouTubeの動画を再生できませんでした(エラー \(code))"
        pause()
        removeSong()
    }

    // MARK: - 書き出し

    func export() async {
        pause()
        do {
            let b = try await CompositionBuilder.build(state: state)
            guard b.duration > 0 else { message = "書き出す動画がありません"; return }
            guard let session = AVAssetExportSession(asset: b.composition,
                                                     presetName: AVAssetExportPresetHighestQuality) else {
                message = "書き出しを開始できませんでした"; return
            }
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("合奏_\(f.string(from: Date())).mp4")
            try? FileManager.default.removeItem(at: out)
            session.outputURL = out
            session.outputFileType = .mp4
            session.videoComposition = b.videoComposition
            session.audioMix = CompositionBuilder.audioMix(state: state, built: b, master: state.masterVolume)
            session.shouldOptimizeForNetworkUse = true

            exportProgress = 0
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.exportProgress = Double(session.progress)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
            poll.cancel()

            guard session.status == .completed else {
                throw session.error ?? NSError(domain: "EasyCover", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: "書き出しに失敗しました"])
            }

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                message = "写真への保存が許可されていません(設定アプリ > 合奏ミキサー > 写真)"
                exportProgress = nil
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: out, options: nil)
            }
            try? FileManager.default.removeItem(at: out)
            message = state.isYouTubeSong
                ? "写真アプリに保存しました(YouTubeの原曲は入っていません)"
                : "写真アプリに保存しました"
        } catch {
            message = "書き出しに失敗しました: \(error.localizedDescription)"
        }
        exportProgress = nil
    }
}
