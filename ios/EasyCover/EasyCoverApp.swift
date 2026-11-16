import SwiftUI
import AVFoundation

@main
struct EasyCoverApp: App {
    init() {
        // 演奏動画の音と YouTube(WKWebView)の音を同時に鳴らす
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
