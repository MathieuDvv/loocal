import UIKit
import UniformTypeIdentifiers

/// "Loocal" in the share sheet: takes the page you shared (a Hugging Face model, say) and
/// hands it straight to the app, which adds the model to its list. Nothing shows here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await forward() }
    }

    private func forward() async {
        let shared = await sharedURL()
        guard let shared, var components = URLComponents(string: "loocal://add-model") else { return finish() }
        components.queryItems = [URLQueryItem(name: "url", value: shared.absoluteString)]
        guard let link = components.url else { return finish() }
        // Share extensions can't open URLs through the public API; the application object
        // sits at the end of the responder chain and still can, called by selector.
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                let done: @convention(block) (Bool) -> Void = { _ in DispatchQueue.main.async { self.finish() } }
                open(current, selector, link as NSURL, NSDictionary(), done)
                return
            }
            responder = current.next
        }
        finish()
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first web link among what was shared: a URL, or one inside shared text.
    private func sharedURL() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, url.scheme?.hasPrefix("http") == true { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let match = text.firstMatch(of: /https?:\/\/\S+/), let url = URL(string: String(match.output)) { return url }
        }
        return nil
    }
}
