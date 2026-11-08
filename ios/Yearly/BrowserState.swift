import SwiftUI
import WebKit

@MainActor
final class BrowserState: ObservableObject {
    @Published var isLoading = true
    @Published var canGoBack = false
    @Published var loadFailed = false
    @Published var downloadFailed = false
    @Published var isDownloading = false
    weak var webView: WKWebView?

    func retry(site: SiteOrigin) {
        loadFailed = false
        if let url = webView?.url, site.contains(url) {
            webView?.reload()
        } else {
            webView?.load(URLRequest(url: site.url))
        }
    }
}
