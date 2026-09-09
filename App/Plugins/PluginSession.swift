import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AnyWhereCore

@MainActor
final class PluginSession: NSObject, ObservableObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler, WKNavigationDelegate {
    let entry: PluginLauncherEntry
    let invocation: PluginInvocation
    private let pagePath: String
    let id = UUID().uuidString.lowercased()
    @Published var error: String?
    @Published private(set) var closed = false
    var onBack: (() -> Void)?
    let workflowInput: JSONValue?
    private let onComplete: ((JSONValue) -> Void)?
    private var submitted = false
    private var task: PluginTask?
    private var taskID: String?
    private var result: PluginTaskResult?
    private var waiter: ((Any?, String?) -> Void)?
    private var navigationStarted = false
    private lazy var dataStore = PluginDataStore(directory: PackManager.dataDirectory(entry.action.packID!))
    private(set) var webView: WKWebView!

    init(entry: PluginLauncherEntry, invocation: PluginInvocation, workflowInput: JSONValue? = nil,
         onComplete: ((JSONValue) -> Void)? = nil) {
        self.entry = entry; self.invocation = invocation
        self.workflowInput = workflowInput; self.onComplete = onComplete
        pagePath = URL(fileURLWithPath: "/" + entry.definition.ui!.entry).standardizedFileURL.path
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "anywhere-plugin")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "anywhere")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = UserDefaults.standard.bool(forKey: "pluginDeveloperMode") }
        var url = URLComponents()
        url.scheme = "anywhere-plugin"; url.host = id; url.path = pagePath
        webView.load(URLRequest(url: url.url!))
    }

    @discardableResult func close(waitForTask: Bool = false) -> Bool {
        guard !closed else { return task?.waitUntilFinished() ?? true }
        closed = true; task?.cancel()
        waiter?(nil, "sessionClosed: Session ended."); waiter = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "anywhere", contentWorld: .page)
        webView.navigationDelegate = nil
        webView = nil
        return !waitForTask || (task?.waitUntilFinished() ?? true)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    private func require(_ capability: PluginCapability) throws {
        guard entry.definition.capabilities.contains(capability) else { throw PluginError(.denied, "Capability not declared: \(capability.rawValue)") }
    }
    private func value(_ raw: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        do {
            guard !closed else { throw PluginError(.sessionClosed, "Session ended.") }
            guard message.frameInfo.isMainFrame, message.webView === webView,
                  message.frameInfo.request.url?.scheme == "anywhere-plugin",
                  message.frameInfo.request.url?.host == id,
                  message.frameInfo.request.url?.path == pagePath else { throw PluginError(.denied, "Only the plugin main page may call the host.") }
            guard let body = message.body as? [String: Any], let method = body["method"] as? String,
                  body["id"] is String,
                  try JSONSerialization.data(withJSONObject: body).count <= 1024 * 1024 else {
                throw PluginError(.invalidArguments, "Invalid request or request exceeds 1 MiB.")
            }
            let params = body["params"] as? [String: Any] ?? [:]
            func key() throws -> String {
                guard let key = params["key"] as? String else { throw PluginError(.invalidArguments, "Expected a storage key.") }
                return key
            }
            var response: Any = NSNull()
            switch method {
            case "host.getInvocation": response = try encoded(invocation)
            case "workflow.context":
                response = ["active": workflowInput != nil, "input": try encoded(workflowInput ?? .null)]
            case "workflow.complete":
                guard workflowInput != nil, let onComplete else { throw PluginError(.denied, "This tool is not running in a workflow.") }
                guard !submitted else { throw PluginError(.busy, "This step already submitted its output.") }
                guard task == nil else { throw PluginError(.busy, "Wait for the current task to finish.") }
                guard let raw = params["output"] else { throw PluginError(.invalidArguments, "Expected step output.") }
                let output = try value(raw)
                submitted = true
                replyHandler(["result": NSNull()], nil)
                DispatchQueue.main.async { [weak self] in
                    guard self?.closed == false else { return }
                    onComplete(output)
                }
                return
            case "host.back":
                // Reply before tearing down this WebView and its bridge.
                replyHandler(["result": NSNull()], nil)
                DispatchQueue.main.async { [weak self] in self?.onBack?() }
                return
            case "host.error": error = String((params["message"] as? String ?? "JavaScript error").prefix(2000))
            case "config.get":
                let fields = entry.definition.settings.filter { $0.type != .password }
                response = try PackConfiguration.store().load(actionID: entry.id, fields: fields)
            case "storage.get": response = try encoded(dataStore.get(key()) ?? .null)
            case "storage.set":
                guard let raw = params["value"] else { throw PluginError(.invalidArguments, "Expected a JSON value.") }
                try dataStore.set(key(), value: value(raw))
            case "storage.remove": try dataStore.remove(key())
            case "clipboard.writeText":
                try require(.writeClipboard)
                guard let text = params["text"] as? String else { throw PluginError(.invalidArguments, "Expected text.") }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else { throw PluginError(.failed, "Clipboard write failed.") }
            case "tasks.run":
                try require(.runTask)
                guard task == nil else { throw PluginError(.busy, "A task is already running.") }
                guard let script = entry.definition.script else { throw PluginError(.denied, "No task script declared.") }
                let scriptURL = try PluginResourceResolver.resolve(root: entry.directory, relativePath: script)
                let input = try value(params["input"] ?? NSNull())
                let values = try PackConfiguration.store().load(actionID: entry.id, fields: entry.definition.settings)
                let env = ActionRunner.contractEnv().merging(try PackSettings.environment(fields: entry.definition.settings, values: values)) { _, new in new }
                let secrets = entry.definition.settings.filter { $0.type == .password }.compactMap { values[$0.key] }
                let running = PluginTask(), identifier = UUID().uuidString
                task = running; taskID = identifier; result = nil
                response = identifier
                let invocation = invocation, directory = entry.directory, timeout = entry.definition.timeoutSeconds
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = running.run(script: scriptURL, directory: directory, invocation: invocation,
                                             input: input, environment: env, secrets: secrets, timeout: TimeInterval(timeout)) { stream, text in
                        Task { @MainActor [weak self] in self?.sendOutput(taskID: identifier, stream: stream, text: text) }
                    }
                    Task { @MainActor [weak self] in
                        guard let self, !self.closed, self.taskID == identifier else { return }
                        self.task = nil; self.result = result
                        self.waiter?(self.taskResponse(result), nil); self.waiter = nil
                        if let error = result.error { self.error = error.message }
                    }
                }
            case "tasks.result", "tasks.cancel":
                guard let identifier = params["id"] as? String, identifier == taskID else { throw PluginError(.invalidArguments, "Unknown task.") }
                if method == "tasks.cancel" { task?.cancel() }
                else if let result { replyHandler(taskResponse(result), nil); return }
                else {
                    guard waiter == nil else { throw PluginError(.busy, "Task result is already being awaited.") }
                    waiter = replyHandler; return
                }
            default: throw PluginError(.invalidArguments, "Unknown host method.")
            }
            guard try JSONSerialization.data(withJSONObject: response, options: [.fragmentsAllowed]).count <= 1024 * 1024 else {
                throw PluginError(.invalidArguments, "Response exceeds 1 MiB.")
            }
            replyHandler(["result": response], nil)
        } catch {
            let failure = error as? PluginError ?? PluginError(.failed, error.localizedDescription)
            replyHandler(["error": ["code": failure.code.rawValue, "message": failure.message]], nil)
        }
    }

    private func taskResponse(_ result: PluginTaskResult) -> [String: Any] {
        // Full output arrives as events; the result carries bounded summaries.
        ["result": ["exitCode": result.exitCode, "stdout": String(result.stdout.prefix(32768)),
                    "stderr": String(result.stderr.prefix(32768)), "error": (try? encoded(result.error)) ?? NSNull()]]
    }
    private func sendOutput(taskID: String, stream: String, text: String) {
        guard !closed, self.taskID == taskID else { return }
        webView.callAsyncJavaScript("window.__anywhereOutput(event)", arguments: ["event": ["id": taskID, "stream": stream, "text": text]], in: nil, in: .page) { _ in }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard !closed, let url = urlSchemeTask.request.url, url.host == id else { throw PluginError(.denied, "Invalid plugin resource.") }
            let file = try PluginResourceResolver.resolve(root: entry.directory, relativePath: String(url.path.dropFirst()))
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
            var data = try Data(contentsOf: file)
            if mime == "text/html" {
                data = Data(("<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">").utf8) + data
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if !closed, !navigationStarted, navigationAction.targetFrame?.isMainFrame == true,
           url?.scheme == "anywhere-plugin", url?.host == id,
           url?.path == pagePath, navigationAction.navigationType == .other {
            navigationStarted = true; decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = String(localized: "plugins.pageFailed"); task?.cancel() }

    static let sdk = #"""
    (() => {
      let sequence = 0;
      const request = async (method, params = {}) => {
        const reply = await window.webkit.messageHandlers.anywhere.postMessage({id: String(++sequence), method, params});
        if (reply.error) throw Object.assign(new Error(reply.error.message), {code: reply.error.code});
        return reply.result;
      };
      const context = request('host.getInvocation');
      const channels = new Map();
      window.__anywhereOutput = event => {
        let channel = channels.get(event.id);
        if (!channel) { channel = {pending: [], listeners: new Set()}; channels.set(event.id, channel); }
        if (channel.listeners.size) channel.listeners.forEach(fn => fn(event));
        else channel.pending.push(event);
      };
      window.anywhere = Object.freeze({
        onEnter: callback => { let active = true; context.then(value => { if (active) callback(value); }); return () => { active = false; }; },
        getInvocation: () => context,
        workflow: {context: () => request('workflow.context'), complete: output => request('workflow.complete', {output})},
        config: {get: () => request('config.get')},
        storage: {get: key => request('storage.get', {key}), set: (key, value) => request('storage.set', {key, value}), remove: key => request('storage.remove', {key})},
        clipboard: {writeText: text => request('clipboard.writeText', {text})},
        tasks: {run: async input => {
          const id = await request('tasks.run', {input});
          if (!channels.has(id)) channels.set(id, {pending: [], listeners: new Set()});
          const channel = channels.get(id);
          const result = request('tasks.result', {id});
          result.finally(() => setTimeout(() => channels.delete(id), 1000)).catch(() => {});
          return {id, result, cancel: () => request('tasks.cancel', {id}), onOutput: fn => {
            channel.listeners.add(fn); channel.pending.splice(0).forEach(fn); return () => channel.listeners.delete(fn);
          }};
        }}
      });
      window.addEventListener('keydown', event => {
        queueMicrotask(() => { if (event.key === 'Escape' && !event.isComposing && !event.defaultPrevented) request('host.back').catch(() => {}); });
      });
      window.addEventListener('error', event => request('host.error', {message: event.message}).catch(() => {}));
      window.addEventListener('unhandledrejection', event => request('host.error', {message: String(event.reason)}).catch(() => {}));
    })();
    """#
}

struct PluginWebView: NSViewRepresentable {
    let session: PluginSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
