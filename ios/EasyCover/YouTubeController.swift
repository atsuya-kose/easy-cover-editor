import SwiftUI
import WebKit
import QuartzCore

/// YouTube の原曲をアプリ内で再生する(プレビュー専用)。
/// 公式の埋め込みプレーヤー(IFrame Player API)を使い、音声は取り出さない。
@MainActor
final class YouTubeController: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var ready = false
    private(set) var state = -1          // -1 未開始 / 0 終了 / 1 再生中 / 2 一時停止 / 3 読み込み中 / 5 頭出し済み
    private(set) var duration: Double = 0
    private(set) var title = ""
    private var lastTime: Double = 0
    private var lastStamp: CFTimeInterval = 0

    var onReady: ((String, Double) -> Void)?
    var onError: ((Int) -> Void)?

    let webView: WKWebView

    /// 再生中は前回の報告からの経過時間で補間する
    var currentTime: Double {
        state == 1 ? lastTime + (CACurrentMediaTime() - lastStamp) : lastTime
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.configuration.userContentController.add(self, name: "yt")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
    }

    static func parseID(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ id: String) -> Bool {
            id.count == 11 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
        }
        if valid(s) { return s }
        guard let u = URLComponents(string: s) else { return nil }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value {
            let id = String(v.prefix(11))
            if valid(id) { return id }
        }
        let parts = u.path.split(separator: "/").map(String.init)
        if (u.host ?? "").hasSuffix("youtu.be"), let first = parts.first {
            let id = String(first.prefix(11))
            return valid(id) ? id : nil
        }
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < parts.count {
            let id = String(parts[i + 1].prefix(11))
            return valid(id) ? id : nil
        }
        return nil
    }

    func load(id: String) {
        ready = false; state = -1; duration = 0; lastTime = 0
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000}#p{width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var p;
        function post(o){ window.webkit.messageHandlers.yt.postMessage(o); }
        function onYouTubeIframeAPIReady(){
          p = new YT.Player('p', {
            videoId: '\(id)', width: '100%', height: '100%',
            playerVars: { playsinline: 1, controls: 0, rel: 0, disablekb: 1, fs: 0, origin: 'https://atsuya-kose.github.io' },
            events: {
              onReady: function(){
                var d = p.getVideoData ? p.getVideoData() : null;
                post({ t: 'ready', title: (d && d.title) || '', dur: p.getDuration() || 0 });
                setInterval(function(){
                  post({ t: 'tick', st: p.getPlayerState(), time: p.getCurrentTime() || 0, dur: p.getDuration() || 0 });
                }, 100);
              },
              onError: function(e){ post({ t: 'error', code: e.data }); }
            }
          });
        }
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://atsuya-kose.github.io/easy-cover-editor/"))
    }

    func unload() {
        ready = false; state = -1; duration = 0; lastTime = 0; title = ""
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
    }

    func play() { js("p && p.playVideo()") }
    func pause() { js("p && p.pauseVideo()") }

    func seek(_ t: Double) {
        js("p && p.seekTo(\(max(0, t)), true)")
        lastTime = max(0, t); lastStamp = CACurrentMediaTime()
    }

    /// iPhone では YouTube 側が音量変更を無視することがある(本体の音量ボタンで調整)
    func setVolume(_ v: Float) {
        js("p && p.setVolume(\(Int(min(max(v, 0), 1) * 100)))")
        js(v <= 0 ? "p && p.mute()" : "p && p.unMute()")
    }

    private func js(_ s: String) { webView.evaluateJavaScript(s, completionHandler: nil) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        switch type {
        case "ready":
            title = (body["title"] as? String) ?? ""
            duration = (body["dur"] as? Double) ?? 0
            ready = true
            onReady?(title, duration)
        case "tick":
            let st = (body["st"] as? Int) ?? -1
            let tm = (body["time"] as? Double) ?? 0
            if let d = body["dur"] as? Double, d > 0, abs(d - duration) > 0.5 {
                duration = d
                onReady?(title, duration)
            }
            if st != state || abs(tm - lastTime) > 0.001 {
                lastTime = tm
                lastStamp = CACurrentMediaTime()
            }
            state = st
        case "error":
            onError?((body["code"] as? Int) ?? -1)
        default:
            break
        }
    }
}

struct YouTubeView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
