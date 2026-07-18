import WebKit
import XCTest
@testable import Clearance

@MainActor
final class MarginNotesWebScriptTests: XCTestCase {
    func testScriptAnchorsQuoteAndRendersMarginNote() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: MarginNotesWebScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(
            frame: .init(x: 0, y: 0, width: 1200, height: 800),
            configuration: configuration
        )
        let delegate = MarginNotesNavigationDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><head><style>
            :root { --surface: #fff; --surface-border: #ddd; --text: #111; --muted: #777; --bg: #f5f5f5; }
            .document { max-width: 760px; margin: 20px auto; }
            </style></head><body>
            <main class="document"><article class="markdown"><p>Agent's job is to max cumulative rewards over time.</p></article></main>
            </body></html>
            """,
            baseURL: nil
        )
        try await delegate.waitForLoad()

        let installed = try await evaluateBoolean(
            "typeof window.clearanceMarginNotes?.setNotes === 'function'",
            in: webView
        )
        XCTAssertTrue(installed)

        _ = try await webView.evaluateJavaScript(
            """
            window.clearanceMarginNotes.setNotes([{
              id: '3DC1AF59-8441-45A7-A2D5-E271EA58A282',
              quote: 'cumulative rewards',
              prefix: 'Agent\\'s job is to max ',
              suffix: ' over time.',
              text: 'Meaning total sum'
            }]);
            true;
            """
        )

        let anchorRendered = try await evaluateBoolean(
            "document.querySelector('.clearance-note-anchor')?.textContent === 'cumulative rewards'",
            in: webView
        )
        XCTAssertTrue(anchorRendered)
        let bubbleRendered = try await evaluateBoolean(
            "document.querySelector('.clearance-margin-note')?.textContent.includes('Meaning total sum') === true",
            in: webView
        )
        XCTAssertTrue(bubbleRendered)
    }

    private func evaluateBoolean(_ script: String, in webView: WKWebView) async throws -> Bool {
        let value = try await webView.evaluateJavaScript(script)
        if let bool = value as? Bool {
            return bool
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}

@MainActor
private final class MarginNotesNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForLoad() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: ())
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
