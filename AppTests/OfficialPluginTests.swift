import XCTest
import WebKit
import UserNotifications
import AnyWhereCore
@testable import AnyWhere

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
    private func load(_ repo: String, argument: String = "") async throws -> PluginSession {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(repo)
        let manifest = try PackManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let id = UUID(), packKey = "test-official-" + UUID().uuidString
        let action = MenuAction(id: id, title: manifest.name, icon: .symbol("bolt"), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: packKey, isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: id, action: action, definition: manifest.actions[0], directory: root)
        let session = PluginSession(entry: entry, invocation: PluginInvocation(actionID: id, source: .launcher, argument: argument))
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
          const wait = async predicate => { const end=Date.now()+5000;while(Date.now()<end){if(await predicate())return;await new Promise(r=>setTimeout(r,25));}throw new Error('UI did not settle: '+step+' / '+document.getElementById('message').textContent); };
          await wait(()=>!document.getElementById('new').disabled);
          const legacy={schemaVersion:1,items:[{id:'legacy-task',title:'整理本周的灵感',note:'保留旧版任务和备注',priority:1,done:false,due:null,recurrence:'none'}]};
          await anywhere.storage.set('todos',legacy); step='reload legacy';
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
          await anywhere.storage.set('todos',state);document.getElementById('reload').click();
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
          await anywhere.storage.set('todos',{schemaVersion:99,items:[]});document.getElementById('reload').click();
          for(let i=0;i<100&&document.getElementById('load-error').hidden;i++)await new Promise(r=>setTimeout(r,25));
          const protectedRead=document.getElementById('new').disabled && (await anywhere.storage.get('todos')).schemaVersion===99;
          await anywhere.storage.set('todos',saved);document.getElementById('reload').click();
          for(let i=0;i<100&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          const task=saved.items.find(t=>t.title==='完成插件交互稿');document.querySelector('#todo-'+task.id+' .task-title').click();
          const external={...saved,items:saved.items.map(t=>t.id===task.id?{...t,title:'另一个窗口的新标题'}:t)};
          await anywhere.storage.set('todos',external);document.getElementById('title').value='过期的编辑';document.getElementById('form').requestSubmit();
          for(let i=0;i<100&&!document.getElementById('message').textContent.includes('另一窗口');i++)await new Promise(r=>setTimeout(r,25));
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
          const wait=async predicate=>{const end=Date.now()+5000;while(Date.now()<end){if(await predicate())return;await new Promise(r=>setTimeout(r,25));}throw new Error('Delete/undo did not settle');};
          window.confirm=()=>true; // Accept only this isolated test page's destructive-action prompts.
          document.getElementById('cancel').click();document.getElementById('reload').click();await wait(()=>!document.getElementById('new').disabled);
          const before=await anywhere.storage.get('todos'),task=before.items.find(t=>t.title==='另一个窗口的新标题');
          document.querySelector('#todo-'+task.id+' .task-title').click();document.getElementById('delete').click();
          await wait(()=>!document.getElementById('undo').hidden&&!document.getElementById('new').disabled);
          const removed=!(await anywhere.storage.get('todos')).items.some(t=>t.id===task.id);
          document.getElementById('undo').click();await wait(async()=> (await anywhere.storage.get('todos')).items.length===before.items.length&&!document.getElementById('new').disabled);
          document.querySelector('[data-view="list:'+task.listId+'"]').click();document.getElementById('manage-list').click();document.getElementById('list-delete').click();
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

    func testTodoActualFormPersistsAndSchedulesIndependently() async throws {
        let session = try await load("anywhere-todo")
        let result = try await js(session, """
          await new Promise(r=>setTimeout(r,400));
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
        let activation = try await js(session, "await new Promise(r=>setTimeout(r,50));return {argument:(await anywhere.getInvocation()).argument,title:document.getElementById('title').value,visible:!document.getElementById('form').hidden}") as? [String: Any]
        XCTAssertEqual(activation?["argument"] as? String, itemID); XCTAssertEqual(activation?["visible"] as? Bool, true)
        let authorized = await PluginServices.shared.status()
        print("System notification authorization: \(authorized)")
        guard authorized == "authorized" else { throw XCTSkip("System notification permission not granted; reminder UI/data verified.") }
        let service = PluginServices(namespace: "anywhere.test." + UUID().uuidString + ".")
        service.reconcile([session.entry])
        try await Task.sleep(nanoseconds: 200_000_000)
        let json = "{\"id\":\"delivery-test\",\"title\":\"AnyWhere 提醒自测\",\"body\":\"插件面板关闭后的系统通知验证\",\"date\":\(Date().timeIntervalSince1970 + 3),\"recurrence\":\"none\"}"
        let reminder = try JSONDecoder().decode(PluginReminder.self, from: Data(json.utf8))
        let synced = try await service.replace([reminder], entry: session.entry)
        XCTAssertTrue((synced["errors"] as? [String])?.isEmpty == true)
        session.close()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        XCTAssertTrue(delivered.contains { $0.request.content.userInfo["itemID"] as? String == "delivery-test" })
        _ = try await service.replace([], entry: session.entry)
        service.reconcile([])
        PluginServices.shared.start()
    }
}
