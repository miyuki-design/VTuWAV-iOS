# VTuWAV v0.1 — iPhone native / TestFlight prototype

VTuLog・VTuRECファミリーの「DRM保護のないローカル音声・動画 → WAV」変換アプリです。

## できること
- 「ファイル」アプリ内にある MP3 / M4A / MP4 / MOV 等（AVFoundationが対応するもの）を取り込む。
- 音声トラックだけを展開し、PCM16 WAVとして保存（元ファイルのサンプルレートとチャンネル数を維持）。
- iOS共有シートから「ファイルに保存」したり、VTuRECなどへ共有したりする。
- ネイティブSwiftUI実装（Python、FFmpeg、サーバ、Macの手操作不要）。WindowsからGitHubに置き、GitHub ActionsのmacOSランナーでビルド可能。

## できないこと・制限
- **Apple Musicサブスク配信曲は抽出不可**。MusicKitは再生・カタログ参照等の機能であり、DRM保護された楽曲の音声ファイルをエクスポートするAPIではありません。
- **YouTube URL直接取得機能は非搭載**。規約に従って正当に入手した自分の動画など、iPhoneの「ファイル」に保存したメディアから変換できます。
- サンプルレート変換、ボーカル分離、Off Vocal化は未実装。
- 本作の出力WAVにはRIFF形式の仕様上の最大サイズがあります。長い音声は失敗する場合があります。
- iOS実機での動作およびGitHub Actionsのビルドは**未検証**。現時点ではアップロード済みのTestFlightアプリではありません。

## 手順：初回だけ

### 1. GitHub リポジトリ
新規リポジトリ `VTuWAV-iOS` を作成し、このZIPを展開した**中身**をルートへアップロード。`.github/workflows/testflight.yml` も配置（GitHub画面で隠しフォルダに注意）。`main` ブランチへコミット。

### 2. Apple Developer / App Store Connect
- Certificates, Identifiers & Profiles → Identifiers → 新しいApp IDを作成: `dev.miminoz.vtuwav`。
- 新しいApp ID用の **App Store Connect配布プロビジョニングプロファイル**を作成し、既存のApple Distribution証明書を指定。プロファイルの`.mobileprovision`をBase64化。
- App Store Connect → App → 新規アプリ登録: Bundle ID `dev.miminoz.vtuwav`、表示名 `VTuWAV`（利用可能な名称を選択）。

### 3. 新しいGitHubリポジトリのActions設定

Secrets（4つ）:
1. `IOS_DISTRIBUTION_P12_BASE64` — 今までの配布証明書を再利用可能（有効期限内）。
2. `IOS_DISTRIBUTION_P12_PASSWORD` — そのP12のパスワード。
3. `IOS_APPSTORE_PROFILE_BASE64` — **VTuWAV専用**プロファイルをBase64にした値（他の4アプリのものは使えない）。
4. `APPSTORE_API_PRIVATE_KEY` — 既存のAuthKey_*.p8の中身。改行も含め全文。

Variables（3つ）:
1. `APPLE_TEAM_ID`
2. `APPSTORE_ISSUER_ID`
3. `APPSTORE_API_KEY_ID`

> 他アプリのリポジトリで登録済みでも、新リポジトリへSecrets/Variablesは自動コピーされません。個人リポジトリなら新しく設定する必要があります。

WindowsでのBase64化の例（PowerShell）:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\\path\\to\\VTuWAV.mobileprovision"))
```

### 4. GitHub Actions実行
`Actions` → `VTuWAV iOS to TestFlight` → `Run workflow`。

1. GitHubのmacOSランナーがXcodeGenでプロジェクトを生成。
2. 新プロファイルと証明書で署名しIPAを作成。
3. `apple-actions/upload-testflight-build@v5` がApp Store Connectへ送信。
4. App Store ConnectのTestFlight画面で処理完了を確認。内部テスト開始。外部テストには審査が必要になる場合があります。

## テスト手順
- 「ファイル」に置いた自作MP3/M4A/MP4で変換し、WAVを共有・保存できるか。
- MP4から映像抜きで音声のみ出力されるか。
- 音声なしMP4や保護コンテンツはエラーメッセージで停止するか。
- 出力したWAVをVTuRECで取り込めるか（VTuREC側の受け取り機能に依存）。

## 設計メモ
- iOS17以降。録音などの権限は使用しません。
- バックグラウンド実行は保証しません。変換中はアプリを開いてください。
- `VTuWAV/WAVConverter.swift` はローカルファイルしか受け取りません。保護解除コードはありません。
- 他社配信音声の保存・変換は、Apple App Reviewガイドライン5.2.3により配信元の明示的な許可が必要です。
- 本ZIPは**署名・TestFlight公開済みバイナリではなく、ビルド用のソース一式**です。
