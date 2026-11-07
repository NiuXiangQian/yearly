import PhotosUI
import SwiftUI
import WebKit

struct SiteView: UIViewControllerRepresentable {
    let site: SiteOrigin
    let state: BrowserState

    func makeCoordinator() -> Coordinator { Coordinator(site: site, state: state) }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "yearlyLivePhoto")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        controller.view = webView
        coordinator.controller = controller
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        state.webView = webView
        coordinator.downloads.controller = controller
        coordinator.backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak coordinator] view, _ in
            let canGoBack = view.canGoBack
            Task { @MainActor in coordinator?.state.canGoBack = canGoBack }
        }
        webView.load(URLRequest(url: site.url))
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.reset()
        coordinator.backObservation = nil
        coordinator.downloads.cancel()
        (controller.view as? WKWebView)?.stopLoading()
        (controller.view as? WKWebView)?.configuration.userContentController
            .removeScriptMessageHandler(forName: "yearlyLivePhoto", contentWorld: .page)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply, PHPickerViewControllerDelegate {
        private typealias Reply = (Any?, String?) -> Void
        let site: SiteOrigin
        let state: BrowserState
        weak var controller: UIViewController?
        private weak var picker: PHPickerViewController?
        private var pending: (id: UUID, reply: Reply)?
        private var transfer: LivePhotoTransfer?
        let downloads: DownloadManager
        var backObservation: NSKeyValueObservation?

        init(site: SiteOrigin, state: BrowserState) {
            self.site = site
            self.state = state
            self.downloads = DownloadManager(state: state)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if site.contains(url) {
                if action.shouldPerformDownload {
                    decisionHandler(.download)
                } else if action.targetFrame == nil {
                    decisionHandler(.cancel)
                    webView.load(action.request)
                } else {
                    decisionHandler(.allow)
                }
                return
            }
            decisionHandler(.cancel)
            // Never navigate the bridge-bearing web view to an outside origin.
            guard action.sourceFrame.isMainFrame, site.contains(action.sourceFrame.request.url),
                  action.navigationType == .linkActivated,
                  AppConfiguration.httpsURL(url.absoluteString) != nil else { return }
            if SiteOrigin.isAttachmentURL(url) {
                webView.startDownload(using: action.request) { [weak self] download in
                    self?.downloads.accept(download)
                }
            } else {
                UIApplication.shared.open(url)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard site.contains(response.response.url) else { decisionHandler(.cancel); return }
            if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                state.isLoading = false
                state.loadFailed = true
                decisionHandler(.cancel)
                return
            }
            let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType {
                state.isLoading = false
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            state.isLoading = false
            downloads.accept(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            state.isLoading = false
            downloads.accept(download)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            reset()
            state.isLoading = true
            state.loadFailed = false
            state.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            state.loadFailed = false
            state.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let error = error as NSError
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            // WebKit reports an interrupted navigation when it becomes a download.
            if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
            state.isLoading = false
            state.loadFailed = true
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reset()
            state.isLoading = false
            state.loadFailed = true
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, site.contains(message.frameInfo.request.url),
                  site.contains(message.webView?.url),
                  let request = message.body as? [String: Any],
                  let action = request["action"] as? String else {
                replyHandler(nil, "invalidRequest")
                return
            }
            if action == "pick" {
                choosePhoto(replyHandler)
                return
            }
            guard let transfer, request["id"] as? String == transfer.id.uuidString else {
                replyHandler(nil, "invalidTransfer")
                return
            }
            switch action {
            case "read":
                guard let role = request["role"] as? String, let offset = request["offset"] as? Int,
                      let data = try? transfer.read(role: role, offset: offset) else {
                    replyHandler(nil, "readFailed")
                    return
                }
                replyHandler(data, nil)
            case "release":
                self.transfer = nil
                replyHandler(NSNull(), nil)
            default:
                replyHandler(nil, "invalidRequest")
            }
        }

        private func choosePhoto(_ reply: @escaping Reply) {
            guard pending == nil, let controller, controller.presentedViewController == nil else {
                reply(nil, "pickerBusy")
                return
            }
            transfer = nil
            // The picker hands us only the selected asset, without library-wide access.
            var configuration = PHPickerConfiguration()
            configuration.filter = .livePhotos
            configuration.selectionLimit = 1
            configuration.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            picker.modalPresentationStyle = .fullScreen
            self.picker = picker
            pending = (UUID(), reply)
            controller.present(picker, animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard picker === self.picker, let id = pending?.id else { return }
            picker.dismiss(animated: true)
            self.picker = nil
            guard let provider = results.first?.itemProvider else {
                finish(id, value: NSNull())
                return
            }
            Task {
                do {
                    let transfer = try await LivePhotoTransfer.load(from: provider)
                    guard pending?.id == id else { return }
                    self.transfer = transfer
                    finish(id, value: transfer.manifest)
                } catch LivePhotoTransfer.Failure.tooLarge {
                    finish(id, value: ["error": "tooLarge"])
                } catch {
                    finish(id, value: ["error": "readFailed"])
                }
            }
        }

        private func finish(_ id: UUID, value: Any) {
            guard let request = pending, request.id == id else { return }
            pending = nil
            request.reply(value, nil)
        }

        func reset() {
            picker?.dismiss(animated: false)
            picker = nil
            if let id = pending?.id { finish(id, value: NSNull()) }
            transfer = nil
        }
    }
}
