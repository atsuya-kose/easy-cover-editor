import AVFoundation
import CoreGraphics

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioTrackIDs: [UUID: CMPersistentTrackID]
    let songTrackID: CMPersistentTrackID?

    var duration: Double { composition.duration.sec }
}

/// 演奏動画と原曲ファイルを 1 本のタイムラインにまとめる。
/// YouTube の原曲はここには入らない(プレビュー専用・書き出しにも入らない)。
enum CompositionBuilder {

    static func renderSize(_ aspect: Aspect) -> CGSize {
        switch aspect {
        case .wide: return CGSize(width: 1920, height: 1080)
        case .tall: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }

    private struct VideoLayer {
        let track: AVMutableCompositionTrack
        let natural: CGSize
        let transform: CGAffineTransform
        let end: CMTime
    }

    static func build(state: ProjectState) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        var layers: [VideoLayer] = []
        var audioIDs: [UUID: CMPersistentTrackID] = [:]
        var songID: CMPersistentTrackID?

        /// offset 秒ずらして置くときの「素材のどこから」「タイムラインのどこに」
        func placement(_ asset: AVURLAsset, offset: Double) async throws -> (range: CMTimeRange, at: CMTime)? {
            let dur = try await asset.load(.duration)
            let skip = max(0, -offset).cm
            guard CMTimeCompare(skip, dur) < 0 else { return nil }
            return (CMTimeRange(start: skip, end: dur), max(0, offset).cm)
        }

        func insert(_ src: AVAssetTrack, into dst: AVMutableCompositionTrack,
                    range: CMTimeRange, at: CMTime) async throws -> CMTime {
            let tr = try await src.load(.timeRange)
            let end = CMTimeMinimum(range.end, tr.end)
            guard CMTimeCompare(range.start, end) < 0 else { return at }
            let r = CMTimeRange(start: range.start, end: end)
            try dst.insertTimeRange(r, of: src, at: at)
            return CMTimeAdd(at, r.duration)
        }

        for clip in state.clips {
            let asset = AVURLAsset(url: clip.url)
            guard let p = try await placement(asset, offset: clip.offset) else { continue }

            if clip.visible,
               let v = try await asset.loadTracks(withMediaType: .video).first,
               let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let end = try await insert(v, into: ct, range: p.range, at: p.at)
                let (natural, transform) = try await v.load(.naturalSize, .preferredTransform)
                layers.append(VideoLayer(track: ct, natural: natural, transform: transform, end: end))
            }

            if let a = try await asset.loadTracks(withMediaType: .audio).first,
               let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                _ = try await insert(a, into: ct, range: p.range, at: p.at)
                audioIDs[clip.id] = ct.trackID
            }
        }

        if let song = state.song, case let .file(fileName, _) = song.source {
            let asset = AVURLAsset(url: Storage.mediaDir.appendingPathComponent(fileName))
            if let p = try await placement(asset, offset: song.offset),
               let a = try await asset.loadTracks(withMediaType: .audio).first,
               let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                _ = try await insert(a, into: ct, range: p.range, at: p.at)
                songID = ct.trackID
            }
        }

        var videoComp: AVMutableVideoComposition?
        if !layers.isEmpty, CMTimeCompare(comp.duration, .zero) > 0 {
            let size = renderSize(state.aspect)
            let cells = gridCells(count: layers.count, layout: state.layout, size: size)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = layers.enumerated().map { (i, layer) -> AVVideoCompositionLayerInstruction in
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: layer.track)
                let (t, crop) = place(natural: layer.natural, preferred: layer.transform,
                                      cell: cells[i].insetBy(dx: 2, dy: 2), fit: state.fit)
                li.setTransform(t, at: .zero)
                if let crop { li.setCropRectangle(crop, at: .zero) }
                li.setOpacity(0, at: layer.end)
                return li
            }
            let vc = AVMutableVideoComposition()
            vc.renderSize = size
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.instructions = [instruction]
            videoComp = vc
        }

        return BuiltComposition(composition: comp, videoComposition: videoComp,
                                audioTrackIDs: audioIDs, songTrackID: songID)
    }

    // MARK: - 音量

    static func anySolo(_ s: ProjectState) -> Bool {
        s.clips.contains { $0.solo } || (s.song?.solo ?? false)
    }

    static func effective(_ v: Float, mute: Bool, solo: Bool, anySolo: Bool) -> Float {
        (mute || (anySolo && !solo)) ? 0 : v
    }

    static func effectiveSongVolume(_ s: ProjectState) -> Float {
        guard let song = s.song else { return 0 }
        return effective(song.volume, mute: song.mute, solo: song.solo, anySolo: anySolo(s))
    }

    static func audioMix(state: ProjectState, built: BuiltComposition, master: Float = 1) -> AVMutableAudioMix {
        let solo = anySolo(state)
        var params: [AVMutableAudioMixInputParameters] = []
        for clip in state.clips {
            guard let id = built.audioTrackIDs[clip.id] else { continue }
            let p = AVMutableAudioMixInputParameters()
            p.trackID = id
            p.setVolume(effective(clip.volume, mute: clip.mute, solo: clip.solo, anySolo: solo) * master, at: .zero)
            params.append(p)
        }
        if let id = built.songTrackID {
            let p = AVMutableAudioMixInputParameters()
            p.trackID = id
            p.setVolume(effectiveSongVolume(state) * master, at: .zero)
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    // MARK: - 配置

    static func gridCells(count n: Int, layout: Layout, size: CGSize) -> [CGRect] {
        guard n > 0 else { return [] }
        let cols = layout == .row ? n : min(n, Int(ceil(sqrt(Double(n) * Double(size.width / size.height)))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
        return (0..<n).map { i in
            let r = i / cols, c = i % cols
            let inRow = min(cols, n - r * cols)
            let x = (size.width - CGFloat(inRow) * cw) / 2 + CGFloat(c) * cw
            return CGRect(x: x, y: CGFloat(r) * ch, width: cw, height: ch)
        }
    }

    /// 縦撮り・横撮り(preferredTransform)を考慮して、動画をセルに収める変換と切り抜き範囲
    static func place(natural: CGSize, preferred: CGAffineTransform,
                      cell: CGRect, fit: Fit) -> (CGAffineTransform, CGRect?) {
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let fix = preferred.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
        let w = abs(oriented.width), h = abs(oriented.height)
        guard w > 0, h > 0 else { return (.identity, nil) }
        let s = fit == .cover ? max(cell.width / w, cell.height / h) : min(cell.width / w, cell.height / h)
        let dw = w * s, dh = h * s
        let t = fix
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: cell.midX - dw / 2, y: cell.midY - dh / 2))
        guard fit == .cover else { return (t, nil) }
        // セルに見える範囲(向きを直した座標)を、元の動画の座標に戻して切り抜く
        let visible = CGRect(x: (dw - cell.width) / 2 / s, y: (dh - cell.height) / 2 / s,
                             width: cell.width / s, height: cell.height / s)
        return (t, visible.applying(fix.inverted()).standardized)
    }
}
