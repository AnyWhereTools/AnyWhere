import XCTest
import WebKit
import UserNotifications
import AnyWhereCore
@testable import AnyWhere

/// Fixture-only access stays outside the production storage bridge.
@MainActor private final class TodoFixtureSeeder: NSObject, WKScriptMessageHandlerWithReply {
    let packKey: String
    init(packKey: String) { self.packKey = packKey }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: message.body))
            try PluginDataStore(directory: PackManager.dataDirectory(packKey)).set("todos", value: value)
            replyHandler(NSNull(), nil)
        } catch { replyHandler(nil, error.localizedDescription) }
    }
}

@MainActor
final class OfficialPluginTests: XCTestCase {
    private var sessions: [PluginSession] = []
    private var folders: [URL] = []
    private var windows: [NSWindow] = []
    override func tearDown() {
        for session in sessions { session.close(discardUnsaved: true) }
        for window in windows { window.contentView = nil; window.close() }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url); return url
    }
    private func load(_ repo: String, argument: String = "", notificationServices: PluginServices? = nil) async throws -> PluginSession {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(repo)
        let manifest = try PackManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let packKey = "test-official-" + UUID().uuidString
        let id = PluginActionIdentity.uuid(packKey: packKey, actionID: manifest.actions[0].id)
        let action = MenuAction(id: id, title: manifest.name, icon: .symbol("bolt"), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: packKey, isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: id, action: action, definition: manifest.actions[0], directory: root)
        if let notificationServices {
            notificationServices.reconcile([entry])
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let session = PluginSession(entry: entry, invocation: PluginInvocation(actionID: id, source: .launcher, argument: argument), notificationServices: notificationServices)
        session.webView.configuration.userContentController.addScriptMessageHandler(TodoFixtureSeeder(packKey: packKey), contentWorld: .page, name: "seedTodo")
        folders.append(PackManager.dataDirectory(packKey)); sessions.append(session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = session.webView; windows.append(window)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 {
            if session.webView.url != nil && !session.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return session
    }
    private func js(_ session: PluginSession, _ code: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await session.webView.callAsyncJavaScript(code, arguments: arguments, in: nil, contentWorld: .page)
    }
    private func capture(_ session: PluginSession, name: String) async throws {
        let snapshot = try await session.webView.takeSnapshot(configuration: nil)
        if let tiff = snapshot.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/anywhere-" + name + ".png"))
        }
    }

    func testDocumentChunksAndAtomicDraft() async throws {
        let folder = try temporary(), documents = PluginDocuments(directory: folder)
        defer { documents.close() }
        let text = String(repeating: "汉🙂\n", count: 200000), bytes = Data(text.utf8)
        documents.markDirty(7)
        let token = try documents.beginWrite()
        for start in stride(from: 0, to: bytes.count, by: PluginDocuments.chunkSize) {
            try documents.append(token, base64: bytes[start..<min(bytes.count,start+PluginDocuments.chunkSize)].base64EncodedString())
        }
        let saved = try await documents.finish(token, draftOnly: true, version: 7, name: "draft.json")
        XCTAssertTrue(saved); XCTAssertFalse(documents.dirty)
        let info = try await documents.open(draftOnly: true) as! [String: Any]
        let readToken = info["id"] as! String
        var restored = Data()
        while true {
            let chunk = try documents.read(readToken)
            if chunk["done"] as? Bool == true { break }
            restored.append(Data(base64Encoded: chunk["data"] as! String)!)
        }
        XCTAssertEqual(restored, bytes)
        let cancelled = try documents.beginWrite()
        try documents.append(cancelled, base64: Data("incomplete".utf8).base64EncodedString()); documents.cancel(cancelled)
        XCTAssertThrowsError(try documents.read("../draft.json"))
        let newReader = PluginDocuments(directory: folder)
        defer { newReader.close() }
        let previous = try await newReader.open(draftOnly: true) as! [String: Any]
        XCTAssertEqual(previous["size"] as? Int, bytes.count)
        let older = try documents.beginWrite(), newer = try documents.beginWrite()
        try documents.append(older, base64: Data("old".utf8).base64EncodedString())
        try documents.append(newer, base64: Data("new".utf8).base64EncodedString())
        documents.markDirty(9)
        let accepted = try await documents.finish(newer, draftOnly: true, version: 9, name: "draft.json")
        let stale = try await documents.finish(older, draftOnly: true, version: 8, name: "draft.json")
        XCTAssertTrue(accepted); XCTAssertFalse(stale)
        let latest = try await documents.open(draftOnly: true) as! [String: Any]
        XCTAssertEqual(try documents.read(latest["id"] as! String)["data"] as? String, Data("new".utf8).base64EncodedString())
    }

    func testServiceValidationAndPersistence() throws {
        let folder = try temporary(), store = PluginServiceStore(directory: folder)
        func link(_ url: String) throws -> PluginLink {
            try JSONDecoder().decode(PluginLink.self, from: JSONSerialization.data(withJSONObject:
                ["id":"site","title":"搜索","keywords":["s"],"url":url]))
        }
        let good = try link("https://example.com/search?q={query}")
        try store.setLinks([good])
        XCTAssertEqual(try PluginServiceStore(directory: folder).links(), [good])
        XCTAssertEqual(try good.destination(argument: "a&b #中文").absoluteString, "https://example.com/search?q=a%26b%20%23%E4%B8%AD%E6%96%87")
        XCTAssertThrowsError(try store.setLinks([good,good]))
        XCTAssertThrowsError(try store.setLinks([link("file:///etc/passwd")]))
        XCTAssertThrowsError(try store.setLinks([link("https://user:pass@example.com")]))
        XCTAssertEqual(try store.links(), [good])
    }

    func testRealJSONEditorWorkerAndLargeDraft() async throws {
        let session = try await load("anywhere-json-tools")
        let result = try await js(session, """
          for(let i=0;i<200&&!window.jsonEditor;i++) await new Promise(r=>setTimeout(r,25));
          if(!window.jsonEditor) return {error:document.getElementById('message').textContent};
          const input='{"n":90071992547409931234,"s":"汉🙂"}';
          jsonEditor.dispatch({changes:{from:0,to:jsonEditor.state.doc.length,insert:input}});
          document.getElementById('format').click();
          for(let i=0;i<400;i++){await new Promise(r=>setTimeout(r,25));if(document.getElementById('message').textContent==='格式化完成')break;}
          for(let i=0;i<200&&document.getElementById('draft-status').textContent!=='草稿已保存';i++) await new Promise(r=>setTimeout(r,25));
          return {text:jsonEditor.state.doc.toString(), message:document.getElementById('message').textContent, draft:await anywhere.documents.draft()};
          """) as? [String: Any]
        XCTAssertEqual(result?["message"] as? String, "格式化完成", "\(String(describing: result))")
        XCTAssertTrue((result?["text"] as? String)?.contains("90071992547409931234") == true)
        XCTAssertEqual((result?["draft"] as? [String: Any])?["text"] as? String, result?["text"] as? String)
        try await capture(session, name: "json-editor")
        let metrics = try await js(session, """
          const measurements=[];
          for(const size of [10,50]) {
            const large='{"value":"'+'x'.repeat(size*1024*1024-12)+'"}';
            const start=performance.now();jsonEditor.dispatch({changes:{from:0,to:jsonEditor.state.doc.length,insert:large}});
            jsonEditor.dispatch({selection:{anchor:large.length-2},scrollIntoView:true});
            await Promise.race([new Promise(r=>requestAnimationFrame(r)),new Promise(r=>setTimeout(r,250))]);
            const editingMs=performance.now()-start;
            for(let i=0;i<1000&&document.getElementById('draft-status').textContent!=='草稿已保存';i++)await new Promise(r=>setTimeout(r,25));
            const recovered=await anywhere.documents.draft();
            measurements.push({size,length:jsonEditor.state.doc.length,recovered:recovered.text.length,editingMs,domLines:document.querySelectorAll('.cm-line').length});
          }
          document.getElementById('format').click();await new Promise(r=>setTimeout(r,10));document.getElementById('cancel').click();
          await new Promise(r=>setTimeout(r,50));
          measurements[1].cancelled=document.getElementById('message').textContent.includes('取消');
          return measurements;
          """) as? [[String: Any]]
        print("JSON real WebView metrics: \(String(describing: metrics))")
        for result in metrics ?? [] {
            let size = result["size"] as! Int
            XCTAssertEqual(result["length"] as? Int, size * 1024 * 1024)
            XCTAssertEqual(result["recovered"] as? Int, size * 1024 * 1024)
            XCTAssertLessThan(result["editingMs"] as? Double ?? .infinity, 5000)
            XCTAssertLessThan(result["domLines"] as? Int ?? Int.max, 200)
        }
        XCTAssertEqual(metrics?.count, 2); XCTAssertEqual(metrics?.last?["cancelled"] as? Bool, true)
    }

    func testQuicklinksActualFormPublishesIndexAndIsolation() async throws {
        let session = try await load("anywhere-quicklinks")
        let result = try await js(session, """
          await new Promise(r=>setTimeout(r,300));
          document.getElementById('new').click();
          document.getElementById('title').value='研发搜索';document.getElementById('url').value='https://example.com/?q={query}';
          document.getElementById('aliases').value='yf';document.getElementById('form').requestSubmit();
          for(let i=0;i<200&&!document.getElementById('message').textContent.includes('主搜索已更新');i++)await new Promise(r=>setTimeout(r,25));
          return {saved:await anywhere.storage.get('websites'),message:document.getElementById('message').textContent};
          """) as? [String: Any]
        XCTAssertEqual(result?["message"] as? String, "已保存，主搜索已更新")
        let links = try PluginServices.store(session.entry).links()
        XCTAssertEqual(links.first?.title, "研发搜索"); XCTAssertEqual(links.first?.keywords, ["yf"])
        let denied = try await js(session, "try {await anywhere.notifications.replace([])} catch(e){return e.code}")
        XCTAssertEqual(denied as? String, "denied")
        try await capture(session, name: "quicklinks")
    }

    func testTodoProductUpgradeAndTaskLifecycle() async throws {
        let session = try await load("anywhere-todo")
        session.webView.window?.appearance = NSAppearance(named: .aqua)
        let result = try await js(session, """
          let step='initial';
          const submits=[];document.addEventListener('submit',e=>submits.push({id:e.target.id,busy,ready,quick:document.getElementById('quick-title').value}),true);
          const wait = async predicate => { const end=Date.now()+5000;while(Date.now()<end){if(await predicate())return;await new Promise(r=>setTimeout(r,25));}throw new Error('UI did not settle: '+step+' / '+document.getElementById('message').textContent+' / '+JSON.stringify({disabled:document.getElementById('new').disabled,quickDisabled:document.getElementById('quick-title').disabled,submits,stored:await anywhere.storage.get('todos')})); };
          await wait(()=>!document.getElementById('new').disabled);
          const legacy={schemaVersion:1,items:[{id:'legacy-task',title:'整理本周的灵感',note:'保留旧版任务和备注',priority:1,done:false,due:null,recurrence:'none'}]};
          await window.webkit.messageHandlers.seedTodo.postMessage(legacy); step='reload legacy';
          document.getElementById('reload').click();
          await wait(()=>!document.getElementById('new').disabled);
          document.querySelector('[data-view="inbox"]').click();
          if(!document.getElementById('todo-legacy-task'))throw new Error('Legacy task disappeared');
          step='quick add'; document.getElementById('quick-title').value='准备明天的设计评审';document.getElementById('quick-form').requestSubmit();
          await wait(async()=> (await anywhere.storage.get('todos')).schemaVersion===2 && !document.getElementById('new').disabled);
          const migrated=await anywhere.storage.get('todos'),backup=await anywhere.storage.get('todos.v1Backup');
          step='create list'; document.getElementById('add-list').click();document.getElementById('list-name').value='工作';document.getElementById('list-form').requestSubmit();
          await wait(async()=> (await anywhere.storage.get('todos')).lists.length===1 && !document.getElementById('new').disabled);
          document.getElementById('quick-title').value='完成插件交互稿';document.getElementById('quick-form').requestSubmit();
          await wait(async()=> (await anywhere.storage.get('todos')).items.length===3 && !document.getElementById('new').disabled);
          const added=(await anywhere.storage.get('todos')).items.find(t=>t.title==='完成插件交互稿');
          document.querySelector('#todo-'+added.id+' .task-title').click();
          document.getElementById('deadline').value=Todo.dayKey();document.getElementById('note').value='检查空状态、深色模式与键盘操作';
          step='edit saved task'; document.getElementById('priority').value='2';document.getElementById('form').requestSubmit();
          await wait(()=>document.getElementById('form').hidden && !document.getElementById('new').disabled);
          document.querySelector('[data-view="today"]').click();
          document.querySelector('#todo-'+added.id+' input').click();
          await wait(()=>!document.getElementById('undo').hidden && !document.getElementById('new').disabled);
          const completed=(await anywhere.storage.get('todos')).items.find(t=>t.id===added.id);
          document.getElementById('undo').click();
          await wait(async()=>!(await anywhere.storage.get('todos')).items.find(t=>t.id===added.id).done && !document.getElementById('new').disabled);
          const state=await anywhere.storage.get('todos');
          // Prepare only isolated test data for a representative native screenshot.
          state.items.push({id:'review',title:'阅读两篇产品设计文章',note:'把值得尝试的想法留在备注里',priority:0,done:false,due:null,recurrence:'none',deadline:Todo.dayKey(),listId:null,createdAt:Date.now(),completedAt:null});
          await window.webkit.messageHandlers.seedTodo.postMessage(state);document.getElementById('reload').click();
          await wait(()=>!document.getElementById('new').disabled);
          return {migrated,backup,completed,state,overflow:document.documentElement.scrollWidth>window.innerWidth};
          """) as? [String: Any]
        XCTAssertEqual((result?["migrated"] as? [String: Any])?["schemaVersion"] as? Int, 2)
        XCTAssertEqual((result?["backup"] as? [String: Any])?["schemaVersion"] as? Int, 1)
        XCTAssertEqual((result?["completed"] as? [String: Any])?["done"] as? Bool, true)
        XCTAssertEqual(result?["overflow"] as? Bool, false)
        let state = result?["state"] as? [String: Any]
        XCTAssertEqual((state?["items"] as? [[String: Any]])?.first?["id"] as? String, "legacy-task")
        XCTAssertEqual((state?["items"] as? [[String: Any]])?.first?["note"] as? String, "保留旧版任务和备注")
        XCTAssertEqual(try PluginServices.store(session.entry).reminders().count, 0)
        try await capture(session, name: "todo-product")
        let protection = try await js(session, """
          const saved=await anywhere.storage.get('todos');
          await window.webkit.messageHandlers.seedTodo.postMessage({schemaVersion:99,items:[]});document.getElementById('reload').click();
          for(let i=0;i<100&&document.getElementById('load-error').hidden;i++)await new Promise(r=>setTimeout(r,25));
          const protectedRead=document.getElementById('new').disabled && (await anywhere.storage.get('todos')).schemaVersion===99;
          await window.webkit.messageHandlers.seedTodo.postMessage(saved);document.getElementById('reload').click();
          for(let i=0;i<100&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          const task=saved.items.find(t=>t.title==='完成插件交互稿');document.querySelector('#todo-'+task.id+' .task-title').click();
          const external={...saved,items:saved.items.map(t=>t.id===task.id?{...t,title:'另一个窗口的新标题'}:t)};
          await window.webkit.messageHandlers.seedTodo.postMessage(external);document.getElementById('title').value='过期的编辑';document.getElementById('form').requestSubmit();
          for(let i=0;i<100&&!document.getElementById('message').textContent.includes('其他操作');i++)await new Promise(r=>setTimeout(r,25));
          return {protectedRead,conflictTitle:(await anywhere.storage.get('todos')).items.find(t=>t.id===task.id).title};
          """) as? [String: Any]
        XCTAssertEqual(protection?["protectedRead"] as? Bool, true)
        XCTAssertEqual(protection?["conflictTitle"] as? String, "另一个窗口的新标题")
        if let window = session.webView.window {
            window.setContentSize(NSSize(width: 540, height: 760))
            window.appearance = NSAppearance(named: .darkAqua)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let overflow = try await js(session, "return document.documentElement.scrollWidth>window.innerWidth") as? Bool
        XCTAssertEqual(overflow, false)
        let modal = try await js(session, "return document.querySelector('main').inert && document.getElementById('editor').getAttribute('aria-modal')==='true'") as? Bool
        XCTAssertEqual(modal, true)
        try await capture(session, name: "todo-product-detail-dark")
        let deletion = try await js(session, """
          let step='reload';
          const wait=async predicate=>{const end=Date.now()+5000;while(Date.now()<end){if(await predicate())return;await new Promise(r=>setTimeout(r,25));}throw new Error('Delete/undo did not settle: '+step+' / '+document.getElementById('message').textContent+' / '+JSON.stringify({disabled:document.getElementById('new').disabled,stored:await anywhere.storage.get('todos')}));};
          window.confirm=()=>true; // Accept only this isolated test page's destructive-action prompts.
          document.getElementById('cancel').click();document.getElementById('reload').click();await wait(()=>!document.getElementById('new').disabled);
          const before=await anywhere.storage.get('todos'),task=before.items.find(t=>t.title==='另一个窗口的新标题');
          step='delete';document.querySelector('#todo-'+task.id+' .task-title').click();document.getElementById('delete').click();
          await wait(()=>!document.getElementById('undo').hidden&&!document.getElementById('new').disabled);
          const removed=!(await anywhere.storage.get('todos')).items.some(t=>t.id===task.id);
          step='undo';document.getElementById('undo').click();await wait(async()=> (await anywhere.storage.get('todos')).items.length===before.items.length&&!document.getElementById('new').disabled);
          step='delete list';document.querySelector('[data-view="list:'+task.listId+'"]').click();document.getElementById('manage-list').click();document.getElementById('list-delete').click();
          await wait(async()=> (await anywhere.storage.get('todos')).lists.length===0&&!document.getElementById('new').disabled);
          const after=await anywhere.storage.get('todos');return {removed,count:after.items.length,expected:before.items.length,moved:after.items.find(t=>t.id===task.id).listId===null};
          """) as? [String: Any]
        XCTAssertEqual(deletion?["removed"] as? Bool, true)
        XCTAssertEqual(deletion?["count"] as? Int, deletion?["expected"] as? Int)
        XCTAssertEqual(deletion?["moved"] as? Bool, true)
        // Check actual WebKit control geometry; native select styling previously
        // ignored padding and rendered at half the search field's height.
        for width in [380, 540, 960] {
            session.webView.window?.setContentSize(NSSize(width: CGFloat(width), height: 760))
            session.webView.window?.appearance = NSAppearance(named: width == 540 ? .darkAqua : .aqua)
            let layout = try await js(session, """
              await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
              const search=document.querySelector('.search-field').getBoundingClientRect(),sort=document.getElementById('sort').getBoundingClientRect();
              document.getElementById('new').click();
              const selects=[...document.querySelectorAll('#form select')].map(el=>el.getBoundingClientRect().height);
              const fields=[...document.querySelectorAll('#form input')].map(el=>el.getBoundingClientRect().height);
              const save=document.getElementById('save').getBoundingClientRect();
              return {aligned:Math.abs(search.height-sort.height)<1&&Math.abs(search.top-sort.top)<1,
                usable:[...selects,...fields].every(h=>h>=34&&Math.abs(h-sort.height)<1),saveVisible:save.top>=0&&save.bottom<=innerHeight,
                overflow:document.documentElement.scrollWidth>innerWidth};
              """) as? [String: Any]
            XCTAssertEqual(layout?["aligned"] as? Bool, true, "Search/sort at \(width)px")
            XCTAssertEqual(layout?["usable"] as? Bool, true, "Detail controls at \(width)px")
            XCTAssertEqual(layout?["saveVisible"] as? Bool, true, "Save button at \(width)px")
            XCTAssertEqual(layout?["overflow"] as? Bool, false, "Overflow at \(width)px")
            try await capture(session, name: "todo-controls-\(width)-detail")
            _ = try await js(session, "document.getElementById('cancel').click()")
            try await capture(session, name: "todo-controls-\(width)")
        }
    }

    func testTodoNotificationActionsAndPresentation() async throws {
        let session = try await load("anywhere-todo")
        let item = try await js(session, """
          const wait=async f=>{for(let i=0;i<200;i++){if(await f())return;await new Promise(r=>setTimeout(r,25));}throw Error('timeout');};
          await wait(()=>!document.getElementById('new').disabled);
          document.getElementById('new').click();document.getElementById('title').value='通知操作测试';
          if(document.getElementById('presentation'))throw Error('Todo should not ask for a notification style');
          document.getElementById('form').requestSubmit();
          await wait(async()=>!document.getElementById('new').disabled&&(await anywhere.storage.get('todos'))?.items.length===1);
          return (await anywhere.storage.get('todos')).items[0];
          """) as! [String: Any]
        let itemID = item["id"] as! String
        XCTAssertNil(item["presentation"])
        let event = PluginNotificationResponse(id: "snooze-five", itemID: itemID, actionID: "snooze")
        session.activate(PluginInvocation(actionID: session.entry.id, source: .launcher, argument: itemID, notification: event))
        let postponed = try await js(session, """
          for(let i=0;i<200&&!document.getElementById('snooze-dialog').open;i++)await new Promise(r=>setTimeout(r,25));
          if(!document.getElementById('snooze-dialog').open)throw Error('No snooze dialog');
          document.getElementById('snooze-delay').value='5';document.getElementById('snooze-form').requestSubmit();
          for(let i=0;i<200&&document.getElementById('snooze-dialog').open;i++)await new Promise(r=>setTimeout(r,25));
          return (await anywhere.storage.get('todos')).items[0];
          """) as! [String: Any]
        XCTAssertEqual(postponed["done"] as? Bool, false)
        XCTAssertEqual(postponed["due"] as! Double / 1000, Date().timeIntervalSince1970 + 300, accuracy: 8)
        let reminders = try PluginServices.store(session.entry).reminders()
        XCTAssertEqual(reminders.first?.actions?.map(\.id), ["snooze", "complete"])
        XCTAssertEqual(reminders.first?.presentation, .panel)
        let finish = PluginNotificationResponse(id: "finish", itemID: itemID, actionID: "complete")
        session.activate(PluginInvocation(actionID: session.entry.id, source: .launcher, argument: itemID, notification: finish))
        let done = try await js(session, """
          for(let i=0;i<200;i++){if((await anywhere.storage.get('todos')).items[0].done&&!document.getElementById('new').disabled)break;await new Promise(r=>setTimeout(r,25));}
          return (await anywhere.storage.get('todos')).items[0].done;
          """) as? Bool
        XCTAssertEqual(done, true); XCTAssertTrue(try PluginServices.store(session.entry).reminders().isEmpty)
        session.activate(PluginInvocation(actionID: session.entry.id, source: .launcher, argument: itemID, notification: finish))
        let replay = try await js(session, "await new Promise(r=>setTimeout(r,100));return (await anywhere.storage.get('todos')).items[0].done") as? Bool
        XCTAssertEqual(replay, true)
    }

    func testTodoSnoozeChoicesAndCancellation() async throws {
        let service = PluginServices(namespace: "anywhere.test." + UUID().uuidString + ".")
        defer { service.reconcile([]); PluginServices.shared.start() }
        let session = try await load("anywhere-todo", notificationServices: service)
        let app = AppState.shared, oldConfig = app.config, oldManager = app.packManager
        let launcher = PluginLauncherController.shared, oldSession = launcher.session
        let manifest = try PackManifest.decode(Data(contentsOf: session.entry.directory.appendingPathComponent("manifest.json")))
        let pack = InstalledPack(key: session.entry.action.packID!, manifest: manifest, repoURL: "", repo: "test/todo", commitSHA: "", enabledCount: 1, totalCount: 1)
        let prefs = PluginPreferencesStore(directory: try temporary())
        try prefs.setEnabled(true, actionID: session.entry.id)
        app.config = MenuConfig(schemaVersion: MenuConfig.currentSchemaVersion, actions: [session.entry.action])
        app.packManager = PackManager(packs: [pack], preferences: prefs)
        launcher.session = session
        defer { launcher.back(); launcher.hide(); launcher.session = oldSession; app.config = oldConfig; app.packManager = oldManager }
        let itemID = try await js(session, """
          for(let i=0;i<200&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          document.getElementById('new').click();document.getElementById('title').value='测试待办：整理通知使用说明';
          document.getElementById('note').value='仅用于隔离测试，不修改已有待办。';
          setDateTime('due',Math.floor((Date.now()+3600000)/60000)*60000);
          document.getElementById('form').requestSubmit();
          for(let i=0;i<200;i++){const s=await anywhere.storage.get('todos');if(s?.items.length&&!document.getElementById('new').disabled)return s.items[0].id;await new Promise(r=>setTimeout(r,25));}
          throw Error('Task not saved');
          """) as! String
        func openSnooze(_ id: String) async throws {
            session.activate(PluginInvocation(actionID: session.entry.id, source: .launcher, argument: itemID,
                notification: PluginNotificationResponse(id: id, itemID: itemID, actionID: "snooze")))
            _ = try await js(session, """
              for(let i=0;i<200&&!document.getElementById('snooze-dialog').open;i++)await new Promise(r=>setTimeout(r,25));
              if(!document.getElementById('snooze-dialog').open)throw Error('No snooze dialog');
              """)
        }
        let before = try PluginServices.store(session.entry).reminders()
        try await openSnooze("cancel")
        let choices = try await js(session, "return [...document.getElementById('snooze-delay').options].map(o=>o.value)") as? [String]
        XCTAssertEqual(choices, ["5", "15", "30", "60", "custom"])
        _ = try await js(session, "document.getElementById('snooze-cancel').click();await new Promise(r=>setTimeout(r,50));")
        XCTAssertEqual(try PluginServices.store(session.entry).reminders(), before)
        try await openSnooze("one-hour")
        _ = try await js(session, "document.getElementById('snooze-delay').value='60';")
        try await capture(session, name: "todo-notification-snooze")
        let hour = try await js(session, """
          document.getElementById('snooze-form').requestSubmit();
          for(let i=0;i<200&&document.getElementById('snooze-dialog').open;i++)await new Promise(r=>setTimeout(r,25));
          return (await anywhere.storage.get('todos')).items[0].due;
          """) as! Double
        XCTAssertEqual(hour / 1000, Date().timeIntervalSince1970 + 3600, accuracy: 8)
        try await openSnooze("custom-time")
        let invalid = try await js(session, """
          document.getElementById('snooze-delay').value='custom';document.getElementById('snooze-delay').dispatchEvent(new Event('change'));
          setDateTime('snooze-custom',new Date('2020-01-01T10:00').getTime());document.getElementById('snooze-form').requestSubmit();
          for(let i=0;i<200&&!document.getElementById('snooze-error').textContent;i++)await new Promise(r=>setTimeout(r,25));
          return {error:document.getElementById('snooze-error').textContent,due:(await anywhere.storage.get('todos')).items[0].due};
          """) as! [String: Any]
        XCTAssertTrue((invalid["error"] as? String)?.contains("晚于当前时间") == true)
        XCTAssertEqual(invalid["due"] as? Double, hour)
        let custom = try await js(session, """
          const expected=Math.floor((Date.now()+120000)/60000)*60000;
          setDateTime('snooze-custom',expected);document.getElementById('snooze-custom').click();
          if(!document.getElementById('date-popover').open)throw Error('No custom time picker');
          document.getElementById('date-form').requestSubmit();
          document.getElementById('snooze-form').requestSubmit();
          for(let i=0;i<200&&document.getElementById('snooze-dialog').open;i++)await new Promise(r=>setTimeout(r,25));
          return {expected,item:(await anywhere.storage.get('todos')).items[0]};
          """) as! [String: Any]
        let saved = custom["item"] as! [String: Any]
        XCTAssertEqual(saved["due"] as? Double, custom["expected"] as? Double)
        XCTAssertEqual(saved["done"] as? Bool, false)
        XCTAssertEqual(try PluginServices.store(session.entry).reminders().first?.date, (saved["due"] as! Double) / 1000)
        session.activate(PluginInvocation(actionID: session.entry.id, source: .launcher, argument: itemID))
        _ = try await js(session, "for(let i=0;i<200&&(document.getElementById('form').hidden||document.getElementById('new').disabled);i++)await new Promise(r=>setTimeout(r,25));if(document.getElementById('form').hidden)throw Error('Activation did not open the task');")
        try await capture(session, name: "todo-notification-presentation")
        _ = try await js(session, """
          document.getElementById('form').requestSubmit();
          for(let i=0;i<200;i++){if(document.getElementById('form').hidden&&!document.getElementById('new').disabled)break;await new Promise(r=>setTimeout(r,25));}
          if(!document.getElementById('form').hidden)throw Error('Presentation save still pending');
          """)
        XCTAssertEqual(try PluginServices.store(session.entry).reminders().first?.presentation, .panel)
        // Shorten only this fixture's deadline; exercise the real host timer and native button route.
        _ = try await js(session, """
          const data=await anywhere.storage.get('todos');data.items[0].due=Date.now()+2000;data.items[0].presentation='system';
          await window.webkit.messageHandlers.seedTodo.postMessage(data);document.getElementById('reload').click();
          for(let i=0;i<200&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          if(document.getElementById('notification-box').classList.contains('has-error'))throw Error(document.getElementById('notification-status').textContent);
          """)
        let timed = try XCTUnwrap(PluginServices.store(session.entry).reminders().first)
        XCTAssertEqual(timed.presentation, .panel, "Legacy system preferences must use the Todo panel policy")
        XCTAssertLessThan(timed.date, Date().timeIntervalSince1970 + 5, "Fixture reload must finish before waiting for delivery")
        var reminderWindow: NSWindow?
        for _ in 0..<100 {
            reminderWindow = NSApp.windows.first { $0.isVisible && $0.windowController is PluginReminderPanel }
            if reminderWindow != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let presented = try PluginServices.store(session.entry).lastPresented(itemID)
        let panel = try XCTUnwrap(reminderWindow, "Windows: \(NSApp.windows.map { ($0.title, $0.isVisible, String(describing: $0.windowController)) }); presented: \(String(describing: presented))")
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/anywhere-todo-notification-native-panel.png"))
        }
        let stack = try XCTUnwrap(panel.contentView?.subviews.first as? NSStackView)
        let buttons = try XCTUnwrap(stack.arrangedSubviews.last as? NSStackView)
        let complete = try XCTUnwrap(buttons.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "complete" })
        complete.performClick(nil)
        _ = try await js(session, """
          for(let i=0;i<200;i++){if((await anywhere.storage.get('todos')).items[0].done&&!document.getElementById('new').disabled)break;await new Promise(r=>setTimeout(r,25));}
          """)
        XCTAssertTrue(try PluginServices.store(session.entry).reminders().isEmpty)
        XCTAssertFalse(panel.isVisible)
        let completed = try await js(session, "return (await anywhere.storage.get('todos')).items[0].done") as? Bool
        XCTAssertEqual(completed, true)
    }

    func testReminderPanelAfterPageCloseAndCancellation() async throws {
        let session = try await load("anywhere-todo")
        let service = PluginServices(namespace: "anywhere.test." + UUID().uuidString + ".")
        defer { service.reconcile([]); PluginServices.shared.start() }
        service.reconcile([session.entry])
        try await Task.sleep(nanoseconds: 200_000_000)
        let title = "Panel-" + UUID().uuidString
        let data: [String: Any] = ["id": "panel-test", "title": title, "body": "Plugin-defined buttons", "date": Date().timeIntervalSince1970 + 60,
                                   "recurrence": "none", "presentation": "panel", "actions": [["id": "later", "title": "稍后"], ["id": "accept", "title": "接受"]]]
        let reminder = try JSONDecoder().decode(PluginReminder.self, from: JSONSerialization.data(withJSONObject: data))
        let result = try await service.replace([reminder], entry: session.entry, requestPermission: false)
        XCTAssertTrue((result["errors"] as? [String])?.isEmpty == true)
        session.close()
        service.presentDuePanels(now: Date(timeIntervalSince1970: reminder.date + 1))
        func matchingWindows() -> [NSWindow] {
            NSApp.windows.filter { window in
                guard window.isVisible, let stack = window.contentView?.subviews.first as? NSStackView else { return false }
                return stack.arrangedSubviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == title }
            }
        }
        XCTAssertEqual(matchingWindows().count, 1)
        _ = try await service.replace([reminder], entry: session.entry, requestPermission: false)
        service.presentDuePanels(now: Date(timeIntervalSince1970: reminder.date + 2))
        XCTAssertEqual(matchingWindows().count, 1)
        _ = try await service.replace([], entry: session.entry, requestPermission: false)
        XCTAssertTrue(matchingWindows().isEmpty)
        var selected: String?
        let panel = PluginReminderPanel(entry: session.entry, reminder: reminder) { selected = $0 }
        panel.showWindow(nil)
        let stack = panel.window!.contentView!.subviews.first as! NSStackView
        let buttons = stack.arrangedSubviews.last as! NSStackView
        XCTAssertEqual(buttons.arrangedSubviews.count, 2)
        (buttons.arrangedSubviews[1] as! NSButton).performClick(nil)
        XCTAssertEqual(selected, "accept"); XCTAssertFalse(panel.window!.isVisible)
    }

    func testInlineSnoozeUsesCardWithoutOpeningTodo() async throws {
        let service = PluginServices(namespace: "anywhere.inline.test." + UUID().uuidString + ".")
        let session = try await load("anywhere-todo", notificationServices: service)
        defer { service.reconcile([]) }
        let itemID = try await js(session, """
          for(let i=0;i<200&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          document.getElementById('new').click();document.getElementById('title').value='卡片内推迟测试';
          setDateTime('due',Date.now()+2000);document.getElementById('form').requestSubmit();
          for(let i=0;i<200&&busy;i++)await new Promise(r=>setTimeout(r,25));
          return (await anywhere.storage.get('todos')).items[0].id;
          """) as! String
        session.webView.window?.orderOut(nil); session.close()
        let launcherSession = PluginLauncherController.shared.session
        var card: PluginReminderPanel?
        for _ in 0..<100 {
            card = NSApp.windows.compactMap { $0.windowController as? PluginReminderPanel }.first { $0.entryID == session.entry.id && $0.window?.isVisible == true }
            if card != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let panel = try XCTUnwrap(card), window = try XCTUnwrap(panel.window)
        let screen = try XCTUnwrap(panel.display)
        XCTAssertEqual(window.frame.maxX, screen.visibleFrame.maxX - 16, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, screen.visibleFrame.maxY - 12, accuracy: 1)
        XCTAssertEqual(window.frame.width, 360, accuracy: 1); XCTAssertLessThan(window.frame.height, 220)
        XCTAssertFalse(window.styleMask.contains(.titled))
        let surface = try XCTUnwrap(window.contentView)
        XCTAssertEqual(surface.layer?.cornerRadius, 19)
        let content = try XCTUnwrap(surface.subviews.first as? NSStackView)
        let actions = try XCTUnwrap(content.arrangedSubviews.last as? NSStackView)
        let menu = try XCTUnwrap(actions.arrangedSubviews.first as? NSPopUpButton)
        XCTAssertTrue(menu.pullsDown)
        XCTAssertEqual(menu.itemTitles, ["推迟", "5 分钟后", "15 分钟后", "30 分钟后", "1 小时后"])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(nanoseconds: 50_000_000)
            surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
            XCTAssertTrue(actions.arrangedSubviews.allSatisfy { abs($0.frame.height - 33) < 1 })
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/anywhere-notification-\(appearance.rawValue).png"))
        }
        window.appearance = nil
        let before = Date().timeIntervalSince1970
        menu.menu?.performActionForItem(at: 1)
        var postponed: PluginReminder?
        for _ in 0..<200 {
            postponed = try PluginServices.store(session.entry).reminders().first
            if (postponed?.date ?? 0) > before + 290 && !window.isVisible { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(postponed).date, before + 300, accuracy: 8)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(PluginLauncherController.shared.session === launcherSession)
        let data = try PluginDataStore(directory: PackManager.dataDirectory(session.entry.action.packID!)).get("todos")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as! [String: Any]
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first { $0["id"] as? String == itemID })
        XCTAssertEqual(item["done"] as? Bool, false)
        XCTAssertEqual((item["due"] as! Double) / 1000, postponed?.date)
    }

    func testInlineFailureKeepsReminderAvailable() async throws {
        let original = try await load("anywhere-todo")
        original.webView.window?.orderOut(nil); original.close()
        let root = try temporary()
        try Data("<meta charset='utf-8'><script>anywhere.notifications.onAction(async () => {throw new Error('测试保存失败')})</script>".utf8).write(to: root.appendingPathComponent("index.html"))
        var definition = original.entry.definition
        definition.commands = nil; definition.mcp = nil
        let entry = PluginLauncherEntry(id: original.entry.id, action: original.entry.action, definition: definition, directory: root)
        let service = PluginServices(namespace: "anywhere.inline.failure." + UUID().uuidString + ".")
        service.reconcile([entry]); defer { service.reconcile([]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let reminder = try JSONDecoder().decode(PluginReminder.self, from: Data(#"{"id":"retry","title":"失败可重试","body":"","date":2000000000,"recurrence":"none","presentation":"panel","actions":[{"id":"accept","title":"确认","background":true}]}"#.utf8))
        _ = try await service.replace([reminder], entry: entry, requestPermission: false)
        service.presentDuePanels(now: Date(timeIntervalSince1970: reminder.date + 1))
        let card = try XCTUnwrap(NSApp.windows.compactMap { $0.windowController as? PluginReminderPanel }.first { $0.entryID == entry.id && $0.window?.isVisible == true })
        card.selectAction("accept")
        let stack = try XCTUnwrap(card.window?.contentView?.subviews.first as? NSStackView)
        for _ in 0..<200 {
            if stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("测试保存失败") }) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let labels = stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("测试保存失败") }, "Card feedback: \(labels)")
        XCTAssertEqual(card.window?.isVisible, true)
        XCTAssertEqual(try PluginServices.store(entry).reminders(), [reminder])
        XCTAssertTrue((stack.arrangedSubviews.last as! NSStackView).arrangedSubviews.compactMap { $0 as? NSButton }.allSatisfy(\.isEnabled))
    }

    func testTodoDatePopover() async throws {
        let session = try await load("anywhere-todo")
        let result = try await js(session, """
          for(let i=0;i<200&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          if(!ready)throw Error('Todo did not load');
          document.getElementById('new').click();document.getElementById('title').value='时间浮层隔离测试';
          setDateTime('due',new Date('2028-02-28T14:16').getTime());
          document.getElementById('due').click();
          const initiallyOpen=document.getElementById('date-popover').open;
          document.getElementById('calendar-next').click();const next=document.getElementById('calendar-month').textContent;
          document.getElementById('calendar-prev').click();
          document.querySelector('[data-day="2028-02-29"]').click();
          document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
          const march=document.activeElement.dataset.day;
          document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));
          document.getElementById('picker-hour').value='24';document.getElementById('picker-minute').value='7';
          document.getElementById('date-form').requestSubmit();
          const invalid=document.getElementById('picker-error').textContent;
          document.getElementById('picker-hour').value='09';
          document.getElementById('date-form').requestSubmit();
          const chosen=getDateTime('due');
          document.getElementById('form').requestSubmit();
          for(let i=0;i<200&&(!document.getElementById('form').hidden||busy);i++)await new Promise(r=>setTimeout(r,25));
          const saved=(await anywhere.storage.get('todos')).items[0];
          document.querySelector('.task-title').click();
          return {initiallyOpen,next,march,invalid,chosen,due:saved.due,restored:getDateTime('due'),expected:new Date('2028-02-29T09:07').getTime()};
          """) as! [String: Any]
        XCTAssertEqual(result["initiallyOpen"] as? Bool, true)
        XCTAssertEqual(result["next"] as? String, "2028年3月")
        XCTAssertEqual(result["march"] as? String, "2028-03-01")
        XCTAssertTrue((result["invalid"] as? String)?.contains("00–23") == true)
        for key in ["chosen", "due", "restored"] { XCTAssertEqual(result[key] as? Double, result["expected"] as? Double) }
        XCTAssertNil(session.webView.window?.attachedSheet)
        _ = try await js(session, "document.getElementById('due').click();")
        try await capture(session, name: "todo-date-popover")
        let cancelled = try await js(session, """
          document.getElementById('picker-minute').value='59';
          document.getElementById('picker-minute').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true}));
          const wrapped=document.getElementById('picker-minute').value;
          document.getElementById('picker-minute').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
          return {due:getDateTime('due'),dirty:formDirty,open:document.getElementById('date-popover').open,editor:!document.getElementById('form').hidden,wrapped};
          """) as! [String: Any]
        XCTAssertEqual(cancelled["due"] as? Double, result["expected"] as? Double)
        XCTAssertEqual(cancelled["dirty"] as? Bool, false)
        XCTAssertEqual(cancelled["open"] as? Bool, false)
        XCTAssertEqual(cancelled["editor"] as? Bool, true)
        XCTAssertEqual(cancelled["wrapped"] as? String, "00")
        _ = try await js(session, "document.getElementById('due').click();document.getElementById('picker-cancel').click();document.getElementById('clear-due').click();")
        let cleared = try await js(session, """
          document.getElementById('save').click();
          for(let i=0;i<200&&(!document.getElementById('form').hidden||busy);i++)await new Promise(r=>setTimeout(r,25));
          return (await anywhere.storage.get('todos')).items[0].due;
          """)
        XCTAssertTrue(cleared is NSNull)
    }

    func testTodoActualFormPersistsAndSchedulesIndependently() async throws {
        let session = try await load("anywhere-todo")
        let result = try await js(session, """
          for(let i=0;i<200&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          document.getElementById('new').click();document.getElementById('title').value='测试待办';
          document.getElementById('note').value='保留备注';document.getElementById('form').requestSubmit();
          for(let i=0;i<200&&!document.getElementById('message').textContent.includes('已保存');i++)await new Promise(r=>setTimeout(r,25));
          return await anywhere.storage.get('todos');
          """) as? [String: Any]
        XCTAssertEqual((result?["items"] as? [[String: Any]])?.first?["title"] as? String, "测试待办")
        XCTAssertEqual(try PluginServices.store(session.entry).reminders().count, 0)
        try await capture(session, name: "todo")
        let itemID = ((result?["items"] as? [[String: Any]])?.first?["id"] as? String)!
        session.activate(PluginInvocation(actionID: session.entry.id, source: .launcher, argument: itemID))
        let activation = try await js(session, "for(let i=0;i<200&&document.getElementById('form').hidden;i++)await new Promise(r=>setTimeout(r,25));return {argument:(await anywhere.getInvocation()).argument,title:document.getElementById('title').value,visible:!document.getElementById('form').hidden}") as? [String: Any]
        XCTAssertEqual(activation?["argument"] as? String, itemID); XCTAssertEqual(activation?["visible"] as? Bool, true)
        let authorized = await PluginServices.shared.status()
        print("System notification authorization: \(authorized)")
        guard authorized == "authorized" else { throw XCTSkip("System notification permission not granted; reminder UI/data verified.") }
        let service = PluginServices(namespace: "anywhere.test." + UUID().uuidString + ".")
        service.reconcile([session.entry])
        try await Task.sleep(nanoseconds: 200_000_000)
        let json = "{\"id\":\"delivery-test\",\"title\":\"AnyWhere 提醒自测\",\"body\":\"插件面板关闭后的系统通知验证\",\"date\":\(Date().timeIntervalSince1970 + 3),\"recurrence\":\"none\",\"actions\":[{\"id\":\"later\",\"title\":\"稍后\"},{\"id\":\"accept\",\"title\":\"接受\"}]}"
        let reminder = try JSONDecoder().decode(PluginReminder.self, from: Data(json.utf8))
        let synced = try await service.replace([reminder], entry: session.entry)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        print("Notification settings after scheduling: authorization=\(settings.authorizationStatus.rawValue), sound=\(settings.soundSetting.rawValue), alert=\(settings.alertSetting.rawValue)")
        XCTAssertTrue((synced["errors"] as? [String])?.isEmpty == true)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let request = try XCTUnwrap(pending.first { $0.content.userInfo["itemID"] as? String == "delivery-test" })
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        let category = try XCTUnwrap(categories.first { $0.identifier == request.content.categoryIdentifier })
        XCTAssertEqual(category.actions.map(\.identifier), ["later", "accept"])
        XCTAssertEqual(try JSONDecoder().decode(PluginReminder.self, from: request.content.userInfo["reminder"] as! Data), reminder)
        session.close()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        XCTAssertTrue(delivered.contains { $0.request.content.userInfo["itemID"] as? String == "delivery-test" })
        _ = try await service.replace([], entry: session.entry)
        service.reconcile([])
        PluginServices.shared.start()
    }
}
