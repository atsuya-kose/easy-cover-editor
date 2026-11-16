# easy-cover-editor(合奏ミキサー)

バンドの演奏動画(各パートを iPhone で撮ったもの)を重ねて、原曲と一緒に再生し、
簡単なミキサーで音量を整えて 1 本の動画に書き出すための個人用アプリ。

## 構成

- `index.html` … Web 版(GitHub Pages: https://atsuya-kose.github.io/easy-cover-editor/ )。
  1 ファイル完結。Mac のブラウザでの確認用として残す。iPhone のブラウザでは動画が重くカクつくので、
  iPhone 向けはネイティブ版に移行した。
- `ios/` … iPhone ネイティブ版(SwiftUI + AVFoundation、iOS 17+)。**今後の開発の中心。**
  - `EasyCover.xcodeproj` … Xcode 16 形式(フォルダ同期グループ)。`ios/EasyCover/` 内の .swift は自動で含まれる
  - `EasyCoverApp.swift` … エントリ。AVAudioSession を .playback + mixWithOthers に設定
  - `Models.swift` … ProjectState / Clip / Song、Documents/Media への保存、PhotosPicker 用 Transferable
  - `CompositionBuilder.swift` … AVMutableComposition で動画をグリッド合成(preferredTransform 考慮、cover は crop)、AudioMix
  - `Engine.swift` … 再生・同期・取り込み・書き出し(AVAssetExportSession → 写真に保存)
  - `YouTubeController.swift` … WKWebView + YouTube IFrame Player API(プレビュー専用)
  - `ContentView.swift` … UI(プレビュー、トランスポート、ミキサー、書き出し)

## 仕様(ユーザーと合意済み)

- 演奏動画を複数追加し、グリッド / 横一列で重ねる。比率 16:9 / 9:16 / 1:1、切り抜き / 全体表示
- 動画ごとに開始位置をずらせる(±1 / ±0.1 / ±0.01 秒、「ここから開始」)
- ミキサー:トラックごとの音量・ミュート・ソロ・映像表示切替、マスター音量
- 原曲は「音声ファイル」または「YouTube のリンク」
- **YouTube の原曲はプレビューで鳴らすだけ。書き出す動画には絶対に含めない。**
  YouTube から音声をダウンロード/抽出する機能(外部の変換サイト経由を含む)は作らない(規約違反のため、ユーザーにも説明済み)
- YouTube 再生中は YouTube を時計の基準にし、読み込み中は演奏動画も止めて待つ(すぐ止まる不具合の対策)
- 書き出しは写真アプリに保存。YouTube 原曲のときは演奏動画の音だけになる

## 現状

- `ios/` のコードは Linux 環境で書いたため**まだ一度もビルドしていない**。
  まず `xcodebuild` でビルドを通し、コンパイルエラーを直すところから。
- iPhone の写真ライブラリの動画は iCloud にあることが多い(取り込み時にダウンロードが走る)。
- 署名は Automatic。Team はユーザーが Xcode で設定する(無料 Apple ID の Personal Team)。

## よく使うコマンド

```sh
# シミュレータ向けビルド(署名不要でエラー確認に便利)
xcodebuild -project ios/EasyCover.xcodeproj -scheme EasyCover \
  -destination 'generic/platform=iOS Simulator' build

# 接続中の実機を確認
xcrun devicectl list devices

# 実機向けビルド(Team 設定後)
xcodebuild -project ios/EasyCover.xcodeproj -scheme EasyCover \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## ユーザーについて

- ソフトウェアエンジニア。日本語でやりとりする。
- 自分のバンドの演奏動画を作るのに使う。
