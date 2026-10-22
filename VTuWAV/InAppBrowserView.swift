import SwiftUI
import WebKit

struct InAppBrowserView: View {
    @ObservedObject var store: DownloadStore
    @StateObject private var browser = BrowserController()
    @State private var address = ""

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
                if store.isDownloading { ProgressView() }
                Button {
                    Task { await store.downloadDirect(browser.webView.url?.absoluteString ?? address) }
                } label: {
                    Label("動画URLを保存", systemImage: "arrow.down.to.line")
                }
                .disabled(store.isDownloading)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

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

            Text("サイトの正規ダウンロードボタンにも対応。『動画URLを保存』は動画ファイルの直接URL専用です。DRM保護やサイトの制限は解除しません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
        .navigationTitle("ブラウザ")
        .onAppear { browser.store = store }
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
