import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = Engine()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showSongImporter = false
    @State private var ytText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    preview
                    transport
                    settings
                    sources
                    if engine.state.isYouTubeSong { youtube }
                    importingList
                    mixer
                    master
                    exportArea
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("合奏ミキサー")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            engine.importVideos(items)
            pickerItems = []
        }
        .fileImporter(isPresented: $showSongImporter, allowedContentTypes: [.audio, .movie]) { result in
            if case let .success(url) = result { engine.importSong(url) }
        }
        .overlay(alignment: .bottom) { toast }
    }

    // MARK: - 部品

    private var preview: some View {
        PlayerView(player: engine.player)
            .aspectRatio(engine.state.aspect.ratio, contentMode: .fit)
            .frame(maxHeight: 440)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if engine.state.clips.isEmpty {
                    Text("演奏動画を追加するとここに表示されます")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if engine.waitingYT { ProgressView().padding(8) }
            }
    }

    private var transport: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { engine.time }, set: { engine.seek($0) }),
                   in: 0...max(engine.duration, 0.1))
            HStack(spacing: 12) {
                Button { engine.seek(0) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.bordered)
                Button { engine.togglePlay() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 56, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.duration == 0)
                Spacer()
                Text("\(formatTime(engine.time)) / \(formatTime(engine.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(spacing: 8) {
            Picker("配置", selection: Binding(get: { engine.state.layout },
                                              set: { engine.state.layout = $0; engine.scheduleRebuild(delay: 0) })) {
                Text("グリッド").tag(Layout.grid)
                Text("横一列").tag(Layout.row)
            }
            .pickerStyle(.segmented)
            HStack {
                Picker("比率", selection: Binding(get: { engine.state.aspect },
                                                  set: { engine.state.aspect = $0; engine.scheduleRebuild(delay: 0) })) {
                    ForEach(Aspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("表示", selection: Binding(get: { engine.state.fit },
                                                  set: { engine.state.fit = $0; engine.scheduleRebuild(delay: 0) })) {
                    Text("切り抜き").tag(Fit.cover)
                    Text("全体").tag(Fit.contain)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var sources: some View {
        VStack(spacing: 8) {
            HStack {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .videos,
                             preferredItemEncoding: .current) {
                    Label("演奏動画を追加", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { showSongImporter = true } label: {
                    Label("原曲ファイル", systemImage: "music.note").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                TextField("YouTubeのリンクを原曲にする", text: $ytText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(useYouTube)
                Button("使う", action: useYouTube)
                    .buttonStyle(.bordered)
                    .disabled(ytText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func useYouTube() {
        engine.useYouTube(ytText)
        ytText = ""
    }

    private var youtube: some View {
        VStack(alignment: .leading, spacing: 6) {
            YouTubeView(webView: engine.yt.webView)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("YouTubeの原曲はプレビュー専用で、書き出す動画には入りません。iPhoneではYouTubeの音量は本体の音量ボタンで調整してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var importingList: some View {
        ForEach(Array(engine.importing.keys), id: \.self) { key in
            ProgressView(value: engine.importing[key] ?? 0) {
                Text("動画を取り込み中…(iCloudからのダウンロードを含む)").font(.caption)
            }
        }
    }

    private var mixer: some View {
        VStack(spacing: 10) {
            if let song = engine.state.song {
                StripView(title: song.title,
                          icon: song.isYouTube ? "▶︎" : "♪",
                          volume: songBinding(\.volume, 1),
                          mute: songBinding(\.mute, false),
                          solo: songBinding(\.solo, false),
                          offset: songBinding(\.offset, 0, structural: true),
                          note: song.isYouTube ? "原曲(YouTube・プレビュー専用)" : "原曲",
                          onStartHere: { engine.songStartHere() },
                          onDelete: { engine.removeSong() })
            }
            ForEach(engine.state.clips) { clip in
                StripView(title: clip.name,
                          icon: "🎸",
                          volume: clipBinding(clip, \.volume),
                          mute: clipBinding(clip, \.mute),
                          solo: clipBinding(clip, \.solo),
                          offset: clipBinding(clip, \.offset, structural: true),
                          visible: clipBinding(clip, \.visible, structural: true),
                          onStartHere: { engine.clipStartHere(clip.id) },
                          onDelete: { engine.removeClip(clip.id) })
            }
        }
    }

    private var master: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("マスター").font(.subheadline.bold())
            HStack {
                Slider(value: Binding(get: { engine.state.masterVolume },
                                      set: { engine.state.masterVolume = $0; engine.mixChanged() }),
                       in: 0...1)
                Text("\(Int(engine.state.masterVolume * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12)))
    }

    private var exportArea: some View {
        VStack(spacing: 6) {
            if let p = engine.exportProgress {
                ProgressView(value: p) { Text("書き出し中… \(Int(p * 100))%").font(.caption) }
            } else {
                Button {
                    Task { await engine.export() }
                } label: {
                    Label("完成動画を書き出して写真に保存", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.state.clips.isEmpty)
            }
            Text("YouTubeの原曲は書き出す動画に入りません。原曲も入れたいときは「原曲ファイル」で音声ファイルを選んでください。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 40)
    }

    @ViewBuilder private var toast: some View {
        if let m = engine.message {
            Text(m)
                .font(.footnote)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .onTapGesture { engine.message = nil }
                .task(id: m) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if engine.message == m { engine.message = nil }
                }
        }
    }

    // MARK: - バインディング

    private func clipBinding<T>(_ clip: Clip, _ kp: WritableKeyPath<Clip, T>, structural: Bool = false) -> Binding<T> {
        Binding(
            get: { engine.state.clips.first(where: { $0.id == clip.id })?[keyPath: kp] ?? clip[keyPath: kp] },
            set: { value in
                guard let i = engine.state.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                engine.state.clips[i][keyPath: kp] = value
                if structural { engine.scheduleRebuild() } else { engine.mixChanged() }
            })
    }

    private func songBinding<T>(_ kp: WritableKeyPath<Song, T>, _ fallback: T, structural: Bool = false) -> Binding<T> {
        Binding(
            get: { engine.state.song?[keyPath: kp] ?? fallback },
            set: { value in
                engine.state.song?[keyPath: kp] = value
                if structural { engine.scheduleRebuild() } else { engine.mixChanged() }
            })
    }
}

// MARK: - ミキサーの 1 段

struct StripView: View {
    let title: String
    let icon: String
    @Binding var volume: Float
    @Binding var mute: Bool
    @Binding var solo: Bool
    @Binding var offset: Double
    var visible: Binding<Bool>? = nil
    var note: String? = nil
    let onStartHere: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(icon) \(title)").font(.subheadline.bold()).lineLimit(1)
                Spacer()
                if let visible {
                    Button { visible.wrappedValue.toggle() } label: {
                        Image(systemName: visible.wrappedValue ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Chip(label: "M", isOn: $mute, color: .orange)
                Chip(label: "S", isOn: $solo, color: .yellow)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...1)
                Text("\(Int(volume * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            OffsetControl(offset: $offset, onStartHere: onStartHere)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12)))
    }
}

struct Chip: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        Button(label) { isOn.toggle() }
            .font(.caption.bold())
            .frame(width: 30, height: 28)
            .background(isOn ? color : Color(white: 0.25))
            .foregroundStyle(isOn ? Color.black : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct OffsetControl: View {
    @Binding var offset: Double
    let onStartHere: () -> Void
    private let steps: [Double] = [-1, -0.1, -0.01, 0.01, 0.1, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("開始位置").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%+.2f 秒", offset)).font(.caption.monospacedDigit())
                Spacer()
                Button("ここから開始", action: onStartHere)
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
            }
            HStack(spacing: 4) {
                ForEach(steps, id: \.self) { d in
                    Button(label(d)) { offset = ((offset + d) * 1000).rounded() / 1000 }
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func label(_ d: Double) -> String {
        let s = abs(d) >= 1 ? String(format: "%.0f", abs(d)) : (abs(d) < 0.1 ? String(format: "%.2f", abs(d)) : String(format: "%.1f", abs(d)))
        return (d > 0 ? "+" : "−") + s
    }
}

// MARK: - プレビュー表示

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}
