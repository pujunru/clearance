import AppKit
import SwiftUI
import WebKit

struct HeadingScrollRequest: Equatable {
    let headingIndex: Int
    let sequence: Int
}

private let renderedHTMLStagingRegistry = RenderedHTMLStagingRegistry()

private final class RenderedHTMLStagingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: Set<URL> = []

    func insert(_ url: URL) {
        _ = lock.withLock {
            urls.insert(url)
        }
    }

    func remove(_ url: URL) {
        _ = lock.withLock {
            urls.remove(url)
        }
    }

    func removeAll() -> Set<URL> {
        lock.withLock {
            let currentURLs = urls
            urls.removeAll()
            return currentURLs
        }
    }

    func contains(_ url: URL) -> Bool {
        lock.withLock {
            urls.contains(url)
        }
    }
}

@MainActor
final class RenderedHTMLLoadHandle {
    static let stagedDirectoryPrefix = ".clearance-rendered-preview-"

    let fileURL: URL
    let readAccessURL: URL
    private let stagedDirectoryURL: URL

    init(html: String, relatedContentURL: URL) throws {
        let stagedDirectoryURL = try Self.makeStagedDirectoryURL(near: relatedContentURL)
        let fileURL = stagedDirectoryURL.appendingPathComponent("rendered-preview.html")
        try html.write(to: fileURL, atomically: true, encoding: .utf8)

        self.fileURL = fileURL
        self.readAccessURL = relatedContentURL
        self.stagedDirectoryURL = stagedDirectoryURL

        renderedHTMLStagingRegistry.insert(stagedDirectoryURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: stagedDirectoryURL)
        renderedHTMLStagingRegistry.remove(stagedDirectoryURL)
    }

    static func load(
        html: String,
        baseURL: URL,
        allowingReadAccessTo relatedContentURL: URL?,
        in webView: WKWebView
    ) -> RenderedHTMLLoadHandle? {
        guard let relatedContentURL,
              baseURL.isFileURL,
              relatedContentURL.isFileURL,
              let handle = try? RenderedHTMLLoadHandle(
                html: html,
                relatedContentURL: relatedContentURL
              ) else {
            webView.loadHTMLString(html, baseURL: baseURL)
            return nil
        }

        webView.loadFileURL(handle.fileURL, allowingReadAccessTo: handle.readAccessURL)
        return handle
    }

    static func removeActiveStagedDirectories() {
        for stagedDirectoryURL in renderedHTMLStagingRegistry.removeAll() {
            try? FileManager.default.removeItem(at: stagedDirectoryURL)
        }
    }

    static func sweepOrphanedStagedDirectories(in contentDirectoryURL: URL) {
        guard let siblingURLs = try? FileManager.default.contentsOfDirectory(
            at: contentDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
        }

        for siblingURL in siblingURLs {
            guard siblingURL.lastPathComponent.hasPrefix(stagedDirectoryPrefix),
                  renderedHTMLStagingRegistry.contains(siblingURL) == false,
                  (try? siblingURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            try? FileManager.default.removeItem(at: siblingURL)
        }
    }

    private static func makeStagedDirectoryURL(near relatedContentURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let contentDirectoryURL = relatedContentURL.hasDirectoryPath
            ? relatedContentURL
            : relatedContentURL.deletingLastPathComponent()
        let stagedDirectoryURL = contentDirectoryURL
            .appendingPathComponent("\(stagedDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(
            at: stagedDirectoryURL,
            withIntermediateDirectories: true
        )

        return stagedDirectoryURL
    }
}

struct RenderedMarkdownView: NSViewRepresentable {
    fileprivate struct RenderContentKey: Equatable {
        let body: String
        let flattenedFrontmatter: [String: String]
        let sourceDocumentURL: URL
        let isRemoteContent: Bool
        let allowsLocalFileStaging: Bool
        let theme: AppTheme
        let appearance: AppearancePreference
    }

    let document: ParsedMarkdownDocument
    let sourceDocumentURL: URL
    let isRemoteContent: Bool
    let allowsLocalFileStaging: Bool
    let headingScrollRequest: HeadingScrollRequest?
    let theme: AppTheme
    let appearance: AppearancePreference
    let textScale: Double
    let contentWidth: RenderedContentWidth
    @ObservedObject var marginNoteStore: MarginNoteStore
    let onOpenLinkedDocument: (URL) -> Void
    private let builder = RenderedHTMLBuilder()

    init(
        document: ParsedMarkdownDocument,
        sourceDocumentURL: URL,
        isRemoteContent: Bool,
        allowsLocalFileStaging: Bool = true,
        headingScrollRequest: HeadingScrollRequest?,
        theme: AppTheme,
        appearance: AppearancePreference,
        textScale: Double,
        contentWidth: RenderedContentWidth = .compact,
        marginNoteStore: MarginNoteStore,
        onOpenLinkedDocument: @escaping (URL) -> Void
    ) {
        self.document = document
        self.sourceDocumentURL = sourceDocumentURL
        self.isRemoteContent = isRemoteContent
        self.allowsLocalFileStaging = allowsLocalFileStaging
        self.headingScrollRequest = headingScrollRequest
        self.theme = theme
        self.appearance = appearance
        self.textScale = textScale
        self.contentWidth = contentWidth
        _marginNoteStore = ObservedObject(wrappedValue: marginNoteStore)
        self.onOpenLinkedDocument = onOpenLinkedDocument
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sourceDocumentURL: sourceDocumentURL,
            onOpenLinkedDocument: onOpenLinkedDocument,
            onCreateNote: { _, _, _, _ in },
            onUpdateNote: { _, _ in },
            onDeleteNote: { _ in }
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: MarginNotesWebScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: context.coordinator),
            name: MarginNotesWebScript.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let renderContentKey = RenderContentKey(
            body: document.body,
            flattenedFrontmatter: document.flattenedFrontmatter,
            sourceDocumentURL: sourceDocumentURL,
            isRemoteContent: isRemoteContent,
            allowsLocalFileStaging: allowsLocalFileStaging,
            theme: theme,
            appearance: appearance
        )
        let html = builder.build(
            document: document,
            sourceDocumentURL: sourceDocumentURL,
            theme: theme,
            appearance: appearance,
            textScale: textScale,
            contentWidth: contentWidth,
            isRemoteContent: isRemoteContent
        )
        let coordinator = context.coordinator
        coordinator.sourceDocumentURL = sourceDocumentURL
        coordinator.onOpenLinkedDocument = onOpenLinkedDocument
        coordinator.onCreateNote = { quote, prefix, suffix, text in
            marginNoteStore.addNote(
                documentURL: sourceDocumentURL,
                quote: quote,
                prefix: prefix,
                suffix: suffix,
                text: text
            )
        }
        coordinator.onUpdateNote = { id, text in
            marginNoteStore.updateNote(id: id, text: text)
        }
        coordinator.onDeleteNote = { id in
            marginNoteStore.deleteNote(id: id)
        }
        let marginNotes = marginNoteStore.notes(for: sourceDocumentURL)
        let baseURL = Self.navigationBaseURL(for: sourceDocumentURL)
        if coordinator.renderContentKey != renderContentKey {
            coordinator.renderContentKey = renderContentKey
            coordinator.appliedTextScale = textScale
            coordinator.appliedContentWidth = contentWidth
            coordinator.pendingTextScale = nil
            coordinator.pendingContentWidth = nil
            coordinator.appliedMarginNotes = nil
            coordinator.pendingMarginNotes = marginNotes
            coordinator.pendingScrollRequest = headingScrollRequest
            coordinator.loadHandle = RenderedHTMLLoadHandle.load(
                html: html,
                baseURL: baseURL,
                allowingReadAccessTo: Self.readAccessURL(
                    for: sourceDocumentURL,
                    isRemoteContent: isRemoteContent,
                    allowsLocalFileStaging: allowsLocalFileStaging
                ),
                in: webView
            )
            return
        }

        coordinator.applyTextScaleIfNeeded(textScale, in: webView)
        coordinator.applyContentWidthIfNeeded(contentWidth, in: webView)
        coordinator.applyMarginNotesIfNeeded(marginNotes, in: webView)
        coordinator.applyScrollRequestIfNeeded(headingScrollRequest, in: webView)
    }

    nonisolated static func navigationBaseURL(for sourceDocumentURL: URL) -> URL {
        sourceDocumentURL.deletingLastPathComponent()
    }

    nonisolated static func readAccessURL(
        for sourceDocumentURL: URL,
        isRemoteContent: Bool,
        allowsLocalFileStaging: Bool
    ) -> URL? {
        guard sourceDocumentURL.isFileURL,
              !isRemoteContent,
              allowsLocalFileStaging else {
            return nil
        }

        return sourceDocumentURL.deletingLastPathComponent()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var sourceDocumentURL: URL
        var onOpenLinkedDocument: (URL) -> Void
        var onCreateNote: (String, String, String, String) -> Void
        var onUpdateNote: (UUID, String) -> Void
        var onDeleteNote: (UUID) -> Void
        fileprivate var renderContentKey: RenderContentKey?
        var pendingScrollRequest: HeadingScrollRequest?
        var pendingTextScale: Double?
        var appliedTextScale: Double?
        var pendingContentWidth: RenderedContentWidth?
        var appliedContentWidth: RenderedContentWidth?
        var pendingMarginNotes: [MarginNote]?
        var appliedMarginNotes: [MarginNote]?
        var loadHandle: RenderedHTMLLoadHandle?
        private var appliedScrollRequest: HeadingScrollRequest?

        init(
            sourceDocumentURL: URL,
            onOpenLinkedDocument: @escaping (URL) -> Void,
            onCreateNote: @escaping (String, String, String, String) -> Void,
            onUpdateNote: @escaping (UUID, String) -> Void,
            onDeleteNote: @escaping (UUID) -> Void
        ) {
            self.sourceDocumentURL = sourceDocumentURL
            self.onOpenLinkedDocument = onOpenLinkedDocument
            self.onCreateNote = onCreateNote
            self.onUpdateNote = onUpdateNote
            self.onDeleteNote = onDeleteNote
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MarginNotesWebScript.messageHandlerName,
                  let payload = message.body as? [String: Any],
                  let action = payload["action"] as? String else {
                return
            }

            switch action {
            case "create":
                guard let quote = payload["quote"] as? String,
                      let prefix = payload["prefix"] as? String,
                      let suffix = payload["suffix"] as? String,
                      let text = payload["text"] as? String else {
                    return
                }
                onCreateNote(quote, prefix, suffix, text)
            case "update":
                guard let rawID = payload["id"] as? String,
                      let id = UUID(uuidString: rawID),
                      let text = payload["text"] as? String else {
                    return
                }
                onUpdateNote(id, text)
            case "delete":
                guard let rawID = payload["id"] as? String,
                      let id = UUID(uuidString: rawID) else {
                    return
                }
                onDeleteNote(id)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                switch MarkdownLinkRouter.action(for: navigationAction.request.url, sourceDocumentURL: sourceDocumentURL) {
                case .allowWebView:
                    break
                case .openInApp(let url):
                    onOpenLinkedDocument(url)
                    decisionHandler(.cancel)
                    return
                case .openExternal(let url):
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }

            if LocalNavigationPolicy.allows(navigationAction.request.url) {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyTextScaleIfNeeded(pendingTextScale, in: webView)
            pendingTextScale = nil
            applyContentWidthIfNeeded(pendingContentWidth, in: webView)
            pendingContentWidth = nil
            applyMarginNotesIfNeeded(pendingMarginNotes, in: webView)
            pendingMarginNotes = nil
            applyScrollRequestIfNeeded(pendingScrollRequest, in: webView)
            pendingScrollRequest = nil
        }

        func applyTextScaleIfNeeded(_ textScale: Double?, in webView: WKWebView) {
            guard let textScale,
                  textScale != appliedTextScale else {
                return
            }

            guard !webView.isLoading else {
                pendingTextScale = textScale
                return
            }

            let formattedTextScale = RenderedHTMLBuilder.formatCSSNumber(textScale)
            let script = "document.documentElement.style.setProperty('--text-scale', '\(formattedTextScale)');"
            webView.evaluateJavaScript(script)
            appliedTextScale = textScale
            pendingTextScale = nil
        }

        func applyContentWidthIfNeeded(_ contentWidth: RenderedContentWidth?, in webView: WKWebView) {
            guard let contentWidth,
                  contentWidth != appliedContentWidth else {
                return
            }

            guard !webView.isLoading else {
                pendingContentWidth = contentWidth
                return
            }

            let script = "document.documentElement.style.setProperty('--content-width', '\(contentWidth.cssValue)');"
            webView.evaluateJavaScript(script)
            appliedContentWidth = contentWidth
            pendingContentWidth = nil
        }

        func applyMarginNotesIfNeeded(_ notes: [MarginNote]?, in webView: WKWebView) {
            guard let notes,
                  notes != appliedMarginNotes else {
                return
            }

            guard !webView.isLoading else {
                pendingMarginNotes = notes
                return
            }

            guard let data = try? JSONEncoder().encode(notes),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("window.clearanceMarginNotes?.setNotes(\(json));")
            appliedMarginNotes = notes
            pendingMarginNotes = nil
        }

        func applyScrollRequestIfNeeded(_ request: HeadingScrollRequest?, in webView: WKWebView) {
            guard let request,
                  request != appliedScrollRequest else {
                return
            }

            let script = """
            (function() {
              const headings = document.querySelectorAll('article.markdown h1, article.markdown h2, article.markdown h3, article.markdown h4, article.markdown h5, article.markdown h6');
              const target = headings[\(request.headingIndex)];
              if (!target) { return false; }
              target.scrollIntoView({ behavior: 'smooth', block: 'start', inline: 'nearest' });
              return true;
            })();
            """

            webView.evaluateJavaScript(script)
            appliedScrollRequest = request
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
