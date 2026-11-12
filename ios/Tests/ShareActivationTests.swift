import Foundation
import UniformTypeIdentifiers

@main struct ShareActivationTests {
    static func main() throws {
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let attributes = (info["NSExtension"] as! [String: Any])["NSExtensionAttributes"] as! [String: Any]
            let predicate = NSPredicate(format: attributes["NSExtensionActivationRule"] as! String)
            func accepts(_ identifiers: [[String]]) -> Bool {
                predicate.evaluate(with: ["extensionItems": [["attachments": identifiers.map { ["registeredTypeIdentifiers": $0] }]]])
            }
            precondition(accepts([[UTType.livePhoto.identifier]]))
            precondition(accepts([[UTType.jpeg.identifier]]))
            precondition(accepts([[UTType.heic.identifier]]))
            precondition(accepts([[UTType.quickTimeMovie.identifier]]))
            precondition(accepts([[UTType.livePhoto.identifier], [UTType.jpeg.identifier], [UTType.mpeg4Movie.identifier]]))
            precondition(accepts(Array(repeating: [UTType.livePhoto.identifier], count: 20)))
            precondition(!accepts(Array(repeating: [UTType.jpeg.identifier], count: 21)))
            precondition(!accepts([[UTType.pdf.identifier]]))
            precondition(!accepts([]))
        }
        print("Share and action activation: Live Photo, image, movie, mixed selection, count and unsupported-input checks passed.")
    }
}
