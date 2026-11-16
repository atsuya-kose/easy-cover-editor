import Foundation
import CoreMedia
import CoreTransferable
import UniformTypeIdentifiers

struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String
    var name: String
    var offset: Double = 0
    var volume: Float = 1
    var mute = false
    var solo = false
    var visible = true

    var url: URL { Storage.mediaDir.appendingPathComponent(fileName) }
}

enum SongSource: Codable, Equatable {
    case file(fileName: String, name: String)
    case youtube(id: String, title: String)
}

struct Song: Codable, Equatable {
    var source: SongSource
    var offset: Double = 0
    var volume: Float = 1
    var mute = false
    var solo = false

    var title: String {
        switch source {
        case let .file(_, name): return name
        case let .youtube(_, title): return title
        }
    }

    var isYouTube: Bool {
        if case .youtube = source { return true }
        return false
    }
}

enum Layout: String, Codable, CaseIterable { case grid, row }

enum Aspect: String, Codable, CaseIterable {
    case wide = "16:9", tall = "9:16", square = "1:1"
    var ratio: CGFloat {
        switch self {
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .square: return 1
        }
    }
}

enum Fit: String, Codable, CaseIterable { case cover, contain }

struct ProjectState: Codable {
    var clips: [Clip] = []
    var song: Song?
    var layout: Layout = .grid
    var aspect: Aspect = .wide
    var fit: Fit = .cover
    var masterVolume: Float = 1

    var isYouTubeSong: Bool { song?.isYouTube ?? false }
}

enum Storage {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let mediaDir: URL = {
        let u = docs.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let stateURL = docs.appendingPathComponent("project.json")

    static func load() -> ProjectState {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(ProjectState.self, from: data) else { return ProjectState() }
        return s
    }

    static func save(_ s: ProjectState) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }

    /// ファイルをアプリ内にコピーして、保存したファイル名を返す
    static func importFile(_ src: URL) throws -> String {
        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
        let name = UUID().uuidString + "." + ext
        try FileManager.default.copyItem(at: src, to: mediaDir.appendingPathComponent(name))
        return name
    }

    static func remove(_ fileName: String) {
        try? FileManager.default.removeItem(at: mediaDir.appendingPathComponent(fileName))
    }
}

/// 写真ライブラリから選んだ動画を受け取る
struct ImportedMovie: Transferable {
    let fileName: String
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let name = try Storage.importFile(received.file)
            return ImportedMovie(fileName: name,
                                 originalName: received.file.deletingPathExtension().lastPathComponent)
        }
    }
}

extension Double {
    var cm: CMTime { CMTime(seconds: self, preferredTimescale: 600) }
}

extension CMTime {
    var sec: Double {
        let s = seconds
        return s.isFinite ? s : 0
    }
}

func formatTime(_ s: Double) -> String {
    let v = max(0, s)
    let m = Int(v) / 60
    let r = v - Double(m * 60)
    return String(format: "%d:%04.1f", m, r)
}
