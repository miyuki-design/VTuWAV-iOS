import SwiftUI
import WebKit

struct InAppBrowserView: View {
    @ObservedObject var store: DownloadStore
    @StateObject private var browser = BrowserController()
    @State private var address = ""
    @StateObject private var pageDownloader = PageVideoDownloader()
    @AppStorage("vtuwav.serverAddress") private var serverAddress = ""
    @AppStorage("vtuwav.accessKey") private var accessKey = ""
    @State private var showServerSettings = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("https://example.com", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.open(address) }
                Button("開く") { browser.open(address) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            HStack {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward)
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                if store.isDownloading || pageDownloader.isWorking { ProgressView() }
                Button {
                    showServerSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            HStack(spacing: 8) {
                Button {
                    let page = browser.webView.url?.absoluteString ?? address
                    Task {
                        await pageDownloader.download(pageAddress: page,
                                                      serverAddress: serverAddress,
                                                      accessKey: accessKey, store: store)
                    }
                } label: {
                    Label("このページの動画を保存", systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .disabled(pageDownloader.isWorking || store.isDownloading)
                Button {
                    Task { await store.downloadDirect(browser.webView.url?.absoluteString ?? address) }
                } label: {
                    Text("直接URL")
                }
                .disabled(pageDownloader.isWorking || store.isDownloading)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            if !pageDownloader.message.isEmpty {
                Text(pageDownloader.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.message.isEmpty {
                Text(store.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .lineLimit(3)
            }

            BrowserHost(webView: browser.webView)
                .background(.white)

            Text("動画視聴ページからの保存には、個人用サーバーの設定が必要です。権利者の許可のある動画のみ保存してください。DRMは解除しません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
        .navigationTitle("ブラウザ")
        .onAppear { browser.store = store }
        .sheet(isPresented: $showServerSettings) {
            NavigationStack {
                Form {
                    Section("動画取得サーバー") {
                        TextField("https://サーバーの公開URL", text: $serverAddress)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("アクセスキー", text: $accessKey)
                    }
                    Section {
                        Text("YouTube等の動画ページの解析はiPhoneだけでは行わず、yt-dlpを動かす自分のサーバーが担当します。HTTPSで接続できるアドレスを入力してください。")
                            .font(.footnote)
                    }
                }
                .navigationTitle("サーバー設定")
                .toolbar { Button("完了") { showServerSettings = false } }
            }
        }
        .onReceive(browser.$currentAddress) { address = $0 }
        .alert("ブラウザ", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "")
        }
    }
}

private struct BrowserHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    weak var store: DownloadStore?
    @Published var currentAddress = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?

    private var activeDownloads: [ObjectIdentifier: URL] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func open(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            errorMessage = "WebサイトのURLを入力してください。"
            return
        }
        webView.load(URLRequest(url: url))
        currentAddress = url.absoluteString
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentAddress = webView.url?.absoluteString ?? currentAddress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let contentDisposition = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if navigationResponse.isForMainFrame &&
            (contentDisposition.contains("attachment") || !navigationResponse.canShowMIMEType) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let store, let destination = store.destination(for: suggestedFilename, response: response) else {
            store?.message = "動画・音声ファイルだけを保存できます。"
            completionHandler(nil)
            return
        }
        activeDownloads[ObjectIdentifier(download)] = destination
        store.message = "ダウンロード中：\(destination.lastPathComponent)"
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        store?.refresh()
        store?.message = "✅ \(destination.lastPathComponent) をiPhoneに保存しました。"
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        store?.message = "ダウンロードに失敗しました：\(error.localizedDescription)"
    }
}
