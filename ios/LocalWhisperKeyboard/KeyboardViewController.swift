import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let viewModel = KeyboardViewModel()
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        wireViewModelCallbacks()

        let rootView = KeyboardRootView(viewModel: viewModel) { [weak self] button, event in
            self?.handleInputModeList(from: button, with: event)
        }
        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.hostingController = host

        let hc = view.heightAnchor.constraint(equalToConstant: 264)
        hc.priority = UILayoutPriority(999)
        hc.isActive = true
        self.heightConstraint = hc

        // Attach the 1x1 invisible WKWebView directly to the keyboard's root UIView
        viewModel.hasFullAccess = hasFullAccess
        viewModel.attachRecorder(to: view)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.handleAppear(
            hasFullAccess: hasFullAccess,
            needsInputModeSwitchKey: needsInputModeSwitchKey
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel.attachRecorder(to: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.handleDisappear()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        viewModel.handleMemoryWarning()
    }

    private func wireViewModelCallbacks() {
        viewModel.onInsertText = { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }

        viewModel.onDeleteBackward = { [weak self] count in
            guard let proxy = self?.textDocumentProxy else { return }
            for _ in 0..<max(0, count) {
                proxy.deleteBackward()
            }
        }

        viewModel.onContextBeforeCursor = { [weak self] in
            self?.textDocumentProxy.documentContextBeforeInput
        }

        viewModel.onAdvanceKeyboard = { [weak self] in
            self?.advanceToNextInputMode()
        }

        viewModel.onOpenURL = { [weak self] url in
            self?.openURLFromExtension(url)
        }
    }

    /// Opens a URL scheme in the containing app safely under APPLICATION_EXTENSION_API_ONLY.
    private func openURLFromExtension(_ url: URL) {
        let modernSelector = NSSelectorFromString("openURL:options:completionHandler:")
        let legacySelector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: modernSelector),
               let imp = class_getMethodImplementation(type(of: current), modernSelector) {
                typealias OpenURLFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let fn = unsafeBitCast(imp, to: OpenURLFn.self)
                fn(current, modernSelector, url as NSURL, [:], nil)
                return
            }
            if current.responds(to: legacySelector) {
                _ = current.perform(legacySelector, with: url)
                return
            }
            responder = current.next
        }
    }
}
