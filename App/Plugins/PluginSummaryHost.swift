import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AnyWhereCore

private final class SummaryWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// The launcher owns one WebView. Every plugin gets a different origin and a read-only bridge.
@MainActor
final class PluginSummaryHost: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let storageChanged = Notification.Name("AnyWhere.pluginStorageChanged")
    static let rowHeight: CGFloat = 64
    private var container = UUID().uuidString.lowercased()
    private var entries: [String: PluginLauncherEntry] = [:]
    private var order: [String] = []
    private var signature = ""
    private var navigated = Set<String>()
    private(set) weak var webView: WKWebView?
    // Recheck eligibility before every resource/bridge access, including after uninstall or disable.
    var isAllowed: (PluginLauncherEntry) -> Bool = { _ in true }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "anywhere-summary")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "summary")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = SummaryWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        webView = view
        return view
    }

    func update(_ values: [PluginLauncherEntry], revision: UUID, dark: Bool) {
        guard let webView else { return }
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let next = values.map { $0.id.uuidString + $0.directory.path }.joined(separator: "|") + revision.uuidString
        guard signature != next else { return }
        signature = next
        // Each load has a new origin: a pending policy callback from an older load cannot consume the new navigation.
        container = UUID().uuidString.lowercased()
        entries = [:]; order = []; navigated = []
        for entry in values {
            let token = UUID().uuidString.lowercased()
            entries[token] = entry; order.append(token)
        }
        webView.load(URLRequest(url: URL(string: "anywhere-summary://\(container)/index.html")!))
    }

    func close() {
        container = UUID().uuidString.lowercased()
        entries = [:]; order = []; signature = ""
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "summary", contentWorld: .page)
        webView?.navigationDelegate = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        do {
            guard message.webView === webView, !message.frameInfo.isMainFrame,
                  let url = message.frameInfo.request.url, url.scheme == "anywhere-summary", url.path == "/summary.html",
                  let entry = entries[url.host ?? ""], isAllowed(entry), let packKey = entry.action.packID else {
                throw PluginError(.denied, "摘要不可访问此插件的数据。")
            }
            guard let body = message.body as? [String: Any], body["method"] as? String == "storage.get",
                  let key = body["key"] as? String, key.utf8.count <= 1024 else {
                throw PluginError(.denied, "摘要只支持 storage.get。")
            }
            let value = try PluginDataStore(directory: PackManager.dataDirectory(packKey)).get(key) ?? .null
            let data = try JSONEncoder().encode(value)
            guard data.count <= 1024 * 1024 else { throw PluginError(.storageLimit, "摘要数据超过 1 MiB。") }
            replyHandler(["result": try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])], nil)
        } catch { replyHandler(["error": error.localizedDescription], nil) }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == "anywhere-summary" else { throw PluginError(.denied, "Invalid resource.") }
            let data: Data, mime: String, csp: String
            if url.host == container, url.path == "/index.html" {
                let frames = order.map { token in
                    "<iframe title=\"插件摘要\" sandbox=\"allow-scripts allow-same-origin\" tabindex=\"-1\" src=\"anywhere-summary://\(token)/summary.html\"></iframe>"
                }.joined()
                csp = "default-src 'none'; style-src 'unsafe-inline'; frame-src " + order.map { "anywhere-summary://" + $0 }.joined(separator: " ") + "; base-uri 'none'; form-action 'none'"
                mime = "text/html"
                data = Data(("<!doctype html><meta charset=\"utf-8\"><style>html,body{margin:0;background:transparent;overflow:hidden}iframe{display:block;border:0;width:100%;height:64px;pointer-events:none}</style>" + frames).utf8)
            } else {
                guard let entry = entries[url.host ?? ""], isAllowed(entry) else { throw PluginError(.denied, "Unavailable summary.") }
                let file = try PluginResourceResolver.resolve(root: entry.directory, relativePath: String(url.path.dropFirst()))
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1024 * 1024 else {
                    throw PluginError(.storageLimit, "摘要资源超过 1 MiB。")
                }
                mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
                data = try Data(contentsOf: file)
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff"])!
            // Custom schemes also need a meta policy; do not rely on response headers alone.
            let content = mime == "text/html" ? Data(("<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">").utf8) + data : data
            task.didReceive(response); task.didReceive(content); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme == "anywhere-summary", let host = url.host,
              action.navigationType == .other, !navigated.contains(host) else { decisionHandler(.cancel); return }
        let main = action.targetFrame?.isMainFrame == true
        let allowed = main ? host == container && url.path == "/index.html" :
            entries[host].map { isAllowed($0) && url.path == "/summary.html" } == true
        if allowed { navigated.insert(host) }
        decisionHandler(allowed ? .allow : .cancel)
    }

    static let sdk = #"""
    (() => {
      if (window === window.top || location.protocol !== 'anywhere-summary:' || location.pathname !== '/summary.html') return;
      window.anywhere = Object.freeze({storage: Object.freeze({get: async key => {
        const reply = await window.webkit.messageHandlers.summary.postMessage({method:'storage.get', key});
        if (reply.error) throw new Error(reply.error);
        return reply.result;
      }})});
      const style = document.createElement('style');
      style.textContent = `:root{color-scheme:light dark;--text:#27272a;--muted:#66666e;--accent:#6659d9;--separator:#8883}
        @media(prefers-color-scheme:dark){:root{--text:#f2f2f4;--muted:#b7b7c0;--accent:#b2a9ff}}
        *{box-sizing:border-box}html,body{margin:0;background:transparent;color:var(--text);font:13px -apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden}
        body{height:64px;padding:8px 14px}p,h1,h2,ul{margin:0}h1,h2{font-size:13px}small{color:var(--muted);font-size:11px}
        ul{padding-left:16px}li{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}a{color:inherit}`;
      const install = () => { if (!style.isConnected && document.documentElement) document.documentElement.prepend(style); };
      install(); document.addEventListener('DOMContentLoaded', install, {once:true});
      const fail = () => { if(document.body) {document.body.replaceChildren(); const text=document.createElement('p');text.textContent='摘要暂不可用，请打开插件查看';document.body.append(text);} };
      window.addEventListener('error', fail); window.addEventListener('unhandledrejection', fail);
    })();
    """#
}

struct PluginSummaryView: NSViewRepresentable {
    let entries: [PluginLauncherEntry]
    let revision: UUID
    var isAllowed: (PluginLauncherEntry) -> Bool
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> PluginSummaryHost { PluginSummaryHost() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.isAllowed = isAllowed
        context.coordinator.update(entries, revision: revision, dark: colorScheme == .dark)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: PluginSummaryHost) { coordinator.close() }
}
