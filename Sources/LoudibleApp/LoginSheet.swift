import AppKit
import SwiftUI
import WebKit
import LoudibleCore
import LoudiblePresentation

/// Embedded Amazon sign-in with an external-browser fallback. Both hand the redirect URL to
/// the same `SessionViewModel.completeSignIn(with:)`.
struct LoginSheet: View {
    @Bindable var session: SessionViewModel
    let login: PendingLogin

    var body: some View {
        LoginSheetContent(
            marketplaceName: login.marketplace.name,
            isRegistering: session.isWorking || session.isRegistering,
            pastedURL: $session.pastedCallbackURL,
            canSubmitPastedURL: session.canSubmitPastedURL,
            errorMessage: session.errorMessage,
            openInBrowser: { NSWorkspace.shared.open(login.loginURL) },
            submitPastedURL: { Task { await session.submitPastedURL() } },
            cancel: { Task { await session.cancelSignIn() } },
            browser: {
                LoginWebView(login: login) { url in
                    Task { await session.completeSignIn(with: url) }
                } isCallback: { session.isCallback($0) }
            }
        )
    }
}

/// The sign-in sheet around a browser. Previews pass a placeholder instead of `LoginWebView`,
/// so they never load Amazon.
struct LoginSheetContent<Browser: View>: View {
    let marketplaceName: String
    let isRegistering: Bool
    @Binding var pastedURL: String
    let canSubmitPastedURL: Bool
    let errorMessage: String?
    let openInBrowser: () -> Void
    let submitPastedURL: () -> Void
    let cancel: () -> Void
    @ViewBuilder let browser: () -> Browser
    @State private var showsBrowserFallback: Bool

    init(
        marketplaceName: String,
        isRegistering: Bool,
        pastedURL: Binding<String>,
        canSubmitPastedURL: Bool,
        errorMessage: String?,
        showsBrowserFallback: Bool = false,
        openInBrowser: @escaping () -> Void,
        submitPastedURL: @escaping () -> Void,
        cancel: @escaping () -> Void,
        @ViewBuilder browser: @escaping () -> Browser
    ) {
        self.marketplaceName = marketplaceName
        self.isRegistering = isRegistering
        _pastedURL = pastedURL
        self.canSubmitPastedURL = canSubmitPastedURL
        self.errorMessage = errorMessage
        _showsBrowserFallback = State(initialValue: showsBrowserFallback)
        self.openInBrowser = openInBrowser
        self.submitPastedURL = submitPastedURL
        self.cancel = cancel
        self.browser = browser
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to Audible (\(marketplaceName))").font(.headline)

            browser()
                .frame(minWidth: 480, minHeight: 560)
                .overlay {
                    if isRegistering { ProgressView("Registering device…") }
                }

            DisclosureGroup("Trouble signing in? Use your web browser", isExpanded: $showsBrowserFallback) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        """
                        Open the sign-in page in your browser. After signing in you will land on an error or blank \
                        page; copy that page's full address and paste it here.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open in Browser", action: openInBrowser)
                        TextField("https://www.amazon…/ap/maplanding?…", text: $pastedURL)
                        Button("Submit", action: submitPastedURL)
                            .disabled(!canSubmitPastedURL)
                    }
                }
                .padding(.top, 4)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }
}

/// A non-persistent WKWebView that loads the login URL with the required cookies and stops
/// at the callback redirect instead of loading it.
struct LoginWebView: NSViewRepresentable {
    let login: PendingLogin
    let onCallback: (URL) -> Void
    let isCallback: (URL) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback, isCallback: isCallback)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = login.userAgent
        context.coordinator.load(login, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCallback = onCallback
        context.coordinator.isCallback = isCallback
        if context.coordinator.loadedLoginID != login.id {
            context.coordinator.load(login, in: webView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onCallback: (URL) -> Void
        var isCallback: (URL) -> Bool
        private(set) var loadedLoginID: UUID?
        private var delivered = false

        init(onCallback: @escaping (URL) -> Void, isCallback: @escaping (URL) -> Bool) {
            self.onCallback = onCallback
            self.isCallback = isCallback
        }

        func load(_ login: PendingLogin, in webView: WKWebView) {
            loadedLoginID = login.id
            delivered = false
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let cookies = login.cookies.compactMap { cookie in
                HTTPCookie(properties: [
                    .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: "/", .secure: "TRUE",
                ])
            }
            Task {
                for cookie in cookies { await store.setCookie(cookie) }
                webView.load(URLRequest(url: login.loginURL))
            }
        }

        private func deliverIfCallback(_ url: URL?) -> Bool {
            guard let url, isCallback(url) else { return false }
            if !delivered {
                delivered = true
                onCallback(url)
            }
            return true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            deliverIfCallback(navigationAction.request.url) ? .cancel : .allow
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if deliverIfCallback(webView.url) { webView.stopLoading() }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error) {
            _ = deliverIfCallback((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
        }
    }
}

#if DEBUG
#Preview("Sign-in – idle") { PreviewCatalog.view(.loginIdle) }
#Preview("Sign-in – registering") { PreviewCatalog.view(.loginRegistering) }
#Preview("Sign-in – error") { PreviewCatalog.view(.loginError) }
#Preview("Sign-in – pasted URL") { PreviewCatalog.view(.loginPastedURL) }
#endif
