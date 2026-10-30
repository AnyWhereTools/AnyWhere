import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AnyWhereCore

@MainActor
final class PluginSession: NSObject, ObservableObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate {
    let entry: PluginLauncherEntry
    private(set) var invocation: PluginInvocation
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
    private lazy var documents = PluginDocuments(directory: PluginServices.directory(entry))
    private let notificationServices: PluginServices
    private let commandOperation: String?
    private let commandRuntime: PluginCommandRuntime
    private let commandAuthorization: @MainActor () throws -> Void
    private var storageObserver: NSObjectProtocol?
    private var commandWrote = false
    private var hostOperations = 0
    private(set) var webView: WKWebView!

    init(entry: PluginLauncherEntry, invocation: PluginInvocation, workflowInput: JSONValue? = nil,
         onComplete: ((JSONValue) -> Void)? = nil, notificationServices: PluginServices? = nil,
         command: String? = nil, commandRuntime: PluginCommandRuntime? = nil,
         commandAuthorization: @escaping @MainActor () throws -> Void = {}) {
        self.entry = entry; self.invocation = invocation
        self.notificationServices = notificationServices ?? .shared
        self.commandOperation = command; self.commandRuntime = commandRuntime ?? .shared
        self.commandAuthorization = commandAuthorization
        self.workflowInput = workflowInput; self.onComplete = onComplete
        pagePath = URL(fileURLWithPath: "/" + (command == nil ? entry.definition.ui!.entry : entry.definition.commands!.entry)).standardizedFileURL.path
        super.init()
        self.commandRuntime.remember(entry, services: self.notificationServices)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "anywhere-plugin")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "anywhere")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = UserDefaults.standard.bool(forKey: "pluginDeveloperMode") }
        var url = URLComponents()
        url.scheme = "anywhere-plugin"; url.host = id; url.path = pagePath
        webView.load(URLRequest(url: url.url!))
        if command == nil {
            storageObserver = NotificationCenter.default.addObserver(forName: PluginCommandRuntime.storageChanged, object: nil, queue: .main) { [weak self] note in
                guard let pack = note.object as? String else { return }
                Task { @MainActor in
                    guard let self, !self.closed, self.entry.action.packID == pack else { return }
                    self.webView.callAsyncJavaScript("window.__anywhereStorageChanged()", arguments: [:], in: nil, in: .page) { _ in }
                }
            }
        }
    }

    @discardableResult func close(waitForTask: Bool = false, discardUnsaved: Bool = false) -> Bool {
        guard !closed else { return task?.waitUntilFinished() ?? true }
        if documents.dirty && !discardUnsaved {
            let alert = NSAlert()
            alert.messageText = "草稿尚未保存"
            alert.informativeText = "请等待自动保存完成。现在关闭将丢弃尚未保存的编辑。"
            alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "丢弃并关闭")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        documents.close()
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver); self.storageObserver = nil }
        closed = true; task?.cancel()
        waiter?(nil, "sessionClosed: Session ended."); waiter = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "anywhere", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView = nil
        return !waitForTask || (task?.waitUntilFinished() ?? true)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    func performCommand(_ operation: String, params: JSONValue) async throws -> JSONValue {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.close(discardUnsaved: true)
        }
        defer { timeout.cancel() }
        do {
            for _ in 0..<200 {
                guard !closed else { throw PluginError(.timedOut, "Command timed out.") }
                if webView.url != nil && !webView.isLoading { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !closed else { throw PluginError(.timedOut, "Command timed out.") }
            let result = try await webView.callAsyncJavaScript("return await window.__anywhereCommand(operation, params)",
                arguments: ["operation": operation, "params": try encoded(params)], in: nil, contentWorld: .page)
            let envelope = result as? [String: Any] ?? [:]
            if let failure = envelope["error"] as? [String: String] {
                throw PluginError(PluginError.Code(rawValue: failure["code"] ?? "") ?? .failed, failure["message"] ?? "Command failed.")
            }
            guard let raw = envelope["value"] else { throw PluginError(.failed, "Command returned no result.") }
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
            guard data.count <= 1024 * 1024 else { throw PluginError(.outputLimit, "Command output exceeds 1 MiB.") }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            if commandWrote { throw PluginError(.outcomeUnknown, "Command ended after saving; query current state before retrying.") }
            throw error
        }
    }
    private func requireCommandWrite(key: String? = nil) throws {
        if let operation = commandOperation {
            guard commandRuntime.isCurrent(entry), entry.definition.commands?.operations[operation]?.readOnly == false,
                  key.map({ entry.definition.commands?.storageKeys.contains($0) == true }) ?? true else {
                throw PluginError(.denied, "Command cannot modify this resource.")
            }
            try commandAuthorization()
        } else if let key, commandRuntime.managedKeys(pack: entry.action.packID!).contains(key) {
            throw PluginError(.denied, "This storage key must be modified through a plugin command.")
        } else if key == nil && entry.definition.commands != nil {
            throw PluginError(.denied, "Reminders must be modified through a plugin command.")
        }
    }
    func activate(_ invocation: PluginInvocation) {
        guard !closed else { return }
        self.invocation = invocation
        guard let context = try? encoded(invocation) else { return }
        webView.callAsyncJavaScript("window.__anywhereEnter(context)", arguments: ["context": context], in: nil, in: .page) { _ in }
    }
    private func require(_ capability: PluginCapability) throws {
        guard entry.definition.capabilities.contains(capability) else { throw PluginError(.denied, "Capability not declared: \(capability.rawValue)") }
    }
    private func value(_ raw: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
    }
    private func decode<T: Decodable>(_ raw: Any, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
    }
    private func replyAsync(_ reply: @escaping (Any?, String?) -> Void, operation: @escaping @MainActor () async throws -> Any) {
        hostOperations += 1
        Task {
            defer { hostOperations -= 1 }
            do {
                guard !closed else { throw PluginError(.sessionClosed, "Session ended.") }
                if commandOperation != nil { try commandAuthorization() }
                let result = try await operation()
                guard !closed else { throw PluginError(.sessionClosed, "Session ended.") }
                reply(["result": result], nil)
            } catch {
                let failure = error as? PluginError ?? PluginError(.failed, error.localizedDescription)
                reply(["error": ["code": failure.code.rawValue, "message": failure.message]], nil)
            }
        }
    }
    func waitForHostOperations() async {
        if let task {
            task.cancel()
            while !task.waitUntilFinished(timeout: 0) { try? await Task.sleep(nanoseconds: 25_000_000) }
        }
        while hostOperations > 0 { try? await Task.sleep(nanoseconds: 25_000_000) }
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
            if commandOperation != nil {
                guard commandRuntime.isCurrent(entry) else { throw PluginError(.denied, "Command session is no longer active.") }
                try commandAuthorization()
                if method.hasPrefix("documents.") || ["launcher.open", "workflow.complete", "host.back"].contains(method) {
                    throw PluginError(.denied, "Interactive host methods are unavailable in command workers.")
                }
                if ["clipboard.writeText", "launcher.setEntries", "tasks.run"].contains(method) { try requireCommandWrite() }
            }
            func key() throws -> String {
                guard let key = params["key"] as? String else { throw PluginError(.invalidArguments, "Expected a storage key.") }
                return key
            }
            var response: Any = NSNull()
            switch method {
            case "commands.fingerprints":
                let values = try value(params["values"] ?? []).array ?? []
                response = values.map(\.fingerprint)
            case "commands.invoke":
                guard commandOperation == nil, let operation = params["operation"] as? String else { throw PluginError(.denied, "Nested command calls are not permitted.") }
                let input = try value(params["params"] ?? [:])
                replyAsync(replyHandler) { try self.encoded(await self.commandRuntime.invoke(entry: self.entry, operation: operation, params: input)) }; return
            case "documents.dirty", "documents.open", "documents.read", "documents.begin", "documents.append", "documents.finish", "documents.cancel":
                try require(.documents)
                let token = params["token"] as? String ?? ""
                switch method {
                case "documents.dirty": documents.markDirty(params["version"] as? Int ?? 0)
                case "documents.open":
                    replyAsync(replyHandler) { try await self.documents.open(draftOnly: params["draft"] as? Bool == true) }; return
                case "documents.read": response = try documents.read(token)
                case "documents.begin": response = try documents.beginWrite()
                case "documents.append": try documents.append(token, base64: params["data"] as? String ?? "")
                case "documents.finish":
                    if params["clipboard"] as? Bool == true { try require(.writeClipboard) }
                    replyAsync(replyHandler) { try await self.documents.finish(token, draftOnly: params["draft"] as? Bool == true,
                        version: params["version"] as? Int ?? 0, name: params["name"] as? String ?? "document.json", clipboard: params["clipboard"] as? Bool == true) }; return
                default: documents.cancel(token)
                }
            case "launcher.setEntries":
                try require(.launcherEntries)
                try PluginServices.store(entry).setLinks(decode(params["entries"] ?? [], as: [PluginLink].self))
                NotificationCenter.default.post(name: PluginServices.changed, object: nil)
            case "launcher.open":
                try require(.launcherEntries)
                guard let link = try PluginServices.store(entry).links().first(where: { $0.id == params["id"] as? String }) else { throw PluginError(.invalidArguments, "Website no longer exists.") }
                guard NSWorkspace.shared.open(try link.destination(argument: params["argument"] as? String ?? "")) else { throw PluginError(.failed, "Could not open browser.") }
            case "notifications.status":
                try require(.notifications)
                replyAsync(replyHandler) { await self.notificationServices.status() }; return
            case "notifications.replace":
                try require(.notifications)
                try requireCommandWrite()
                let reminders = try decode(params["reminders"] ?? [], as: [PluginReminder].self)
                replyAsync(replyHandler) { try await self.notificationServices.replace(reminders, entry: self.entry) }; return
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
                try requireCommandWrite(key: key())
                guard let raw = params["value"] else { throw PluginError(.invalidArguments, "Expected a JSON value.") }
                try dataStore.set(key(), value: value(raw))
                commandWrote = commandOperation != nil
                NotificationCenter.default.post(name: PluginCommandRuntime.storageChanged, object: entry.action.packID)
            case "storage.remove":
                try requireCommandWrite(key: key())
                try dataStore.remove(key())
                commandWrote = commandOperation != nil
                NotificationCenter.default.post(name: PluginCommandRuntime.storageChanged, object: entry.action.packID)
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
            let workers = entry.definition.capabilities.contains(.documents) ? "blob:" : "'none'"
            let csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; worker-src \(workers); style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
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
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard !closed, frame.isMainFrame else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = entry.definition.title; alert.informativeText = String(message.prefix(2000))
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认")
        completionHandler(alert.runModal() == .alertSecondButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard !closed, frame.isMainFrame else { completionHandler(nil); return }
        let alert = NSAlert(); alert.messageText = entry.definition.title; alert.informativeText = String(prompt.prefix(2000))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = defaultText ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
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
      let context = request('host.getInvocation');
      let notificationHandler;
      let commandHandlers;
      const changeListeners = new Set();
      window.__anywhereStorageChanged = () => changeListeners.forEach(fn => fn());
      window.__anywhereCommand = async (operation, params) => {
        try {
          for (let i = 0; i < 200 && !commandHandlers; i++) await new Promise(resolve => setTimeout(resolve, 25));
          if (!commandHandlers || typeof commandHandlers[operation] !== 'function') throw new Error('Command handler is not registered.');
          return {value: await commandHandlers[operation](params)};
        } catch (error) { return {error: {code: error.code || 'failed', message: error.message || String(error)}}; }
      };
      const enterListeners = new Set();
      window.__anywhereEnter = value => { context = Promise.resolve(value); enterListeners.forEach(fn => fn(value)); };
      const documentRead = async draft => {
        const info = await request('documents.open', {draft});
        if (!info) return null;
        const decoder = new TextDecoder('utf-8', {fatal: true}), parts = [];
        try {
          while (true) {
            const chunk = await request('documents.read', {token: info.id});
            if (chunk.done) break;
            parts.push(decoder.decode(Uint8Array.from(atob(chunk.data), c => c.charCodeAt(0)), {stream: true}));
          }
          parts.push(decoder.decode());
          return {name: info.name, text: parts.join('')};
        } finally { await request('documents.cancel', {token: info.id}); }
      };
      const documentWrite = async (text, draft, version = 0, name = 'document.json', clipboard = false) => {
        const bytes = new TextEncoder().encode(text);
        if (bytes.length > 50 * 1024 * 1024) throw new Error('文件超过 50 MiB');
        const token = await request('documents.begin');
        try {
          for (let i = 0; i < bytes.length; i += 196608) {
            const chunk = bytes.subarray(i, i + 196608); let binary = '';
            for (let j = 0; j < chunk.length; j += 8192) binary += String.fromCharCode(...chunk.subarray(j, j + 8192));
            await request('documents.append', {token, data: btoa(binary)});
          }
          return await request('documents.finish', {token, draft, version, name, clipboard});
        } finally { await request('documents.cancel', {token}); }
      };
      const channels = new Map();
      window.__anywhereOutput = event => {
        let channel = channels.get(event.id);
        if (!channel) { channel = {pending: [], listeners: new Set()}; channels.set(event.id, channel); }
        if (channel.listeners.size) channel.listeners.forEach(fn => fn(event));
        else channel.pending.push(event);
      };
      window.anywhere = Object.freeze({
        commands: {register: handlers => { if (commandHandlers) throw new Error('Handlers already registered'); commandHandlers = handlers; },
          invoke: (operation, params = {}) => request('commands.invoke', {operation, params}),
          fingerprints: values => request('commands.fingerprints', {values}),
          onChanged: callback => { changeListeners.add(callback); return () => changeListeners.delete(callback); }},
        onEnter: callback => { let active = true; enterListeners.add(callback); context.then(value => { if (active) callback(value); }); return () => { active = false; enterListeners.delete(callback); }; },
        getInvocation: () => context,
        documents: {open: () => documentRead(false), draft: () => documentRead(true),
          markDirty: version => request('documents.dirty', {version}),
          saveDraft: (text, version) => documentWrite(text, true, version),
          copyText: text => documentWrite(text, false, 0, 'document.json', true),
          saveAs: (text, name) => documentWrite(text, false, 0, name)},
        launcher: {setEntries: entries => request('launcher.setEntries', {entries}), open: (id, argument = '') => request('launcher.open', {id, argument})},
        notifications: {status: () => request('notifications.status'), replace: reminders => request('notifications.replace', {reminders})},
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
