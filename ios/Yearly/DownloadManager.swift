import UIKit
import WebKit

/// Download through WebKit so authenticated exports keep the app's cookies.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    weak var controller: UIViewController?
    private let state: BrowserState
    private var active: WKDownload?
    private var directory: URL?
    private var destination: URL?

    init(state: BrowserState) { self.state = state }

    func accept(_ download: WKDownload) {
        guard active == nil, directory == nil, let controller,
              controller.presentedViewController == nil else {
            download.cancel { _ in }
            state.downloadFailed = true
            return
        }
        active = download
        download.delegate = self
        state.isDownloading = true
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard download === active,
              let url = response.url, AppConfiguration.httpsURL(url.absoluteString) != nil,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            completionHandler(nil)
            return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            directory = folder
            let name = (suggestedFilename as NSString).lastPathComponent
            let safeName = name.isEmpty || name == "." || name == ".." || name == "/" ? "yearly-export" : name
            let file = folder.appendingPathComponent(safeName)
            destination = file
            completionHandler(file)
        } catch {
            completionHandler(nil)
            state.downloadFailed = true
            cleanup()
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(request.url.flatMap { AppConfiguration.httpsURL($0.absoluteString) } == nil ? .cancel : .allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === active else { return }
        active = nil
        state.isDownloading = false
        guard let destination, let controller, controller.presentedViewController == nil else {
            state.downloadFailed = true
            cleanup()
            return
        }
        let sheet = UIActivityViewController(activityItems: [destination], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        // Keep the file alive until the system share operation has finished.
        let folder = directory
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
            if let folder { try? FileManager.default.removeItem(at: folder) }
            Task { @MainActor in self?.cleanup() }
        }
        controller.present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === active else { return }
        state.downloadFailed = true
        cleanup()
    }

    func cancel() {
        active?.cancel { _ in }
        cleanup()
    }

    private func cleanup() {
        active = nil
        state.isDownloading = false
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        destination = nil
    }
}
