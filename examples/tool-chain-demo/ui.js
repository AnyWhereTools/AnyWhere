const $id = id => document.getElementById(id);
const kind = document.body.dataset.tool;
const sample = {status: 200, data: {items: [{id: 1, name: 'Alice', email: 'alice@example.com'}, {id: 2, name: 'Bob', active: true}]}};
let active = false, output, source, choices = [];
function status(text = '') { $id('status').textContent = text; }
function ready(value) {
    output = value;
    if ($id('preview')) $id('preview').textContent = JSON.stringify(value, null, 2);
    $id('copy').disabled = false; $id('next').disabled = false;
}
function invalidate() {
    output = undefined; $id('copy').disabled = true; $id('next').disabled = true;
    if ($id('choice')) $id('choice').disabled = true;
}
function choose() {
    const index = Number($id('choice').value);
    ready(kind === 'extract' ? choices[index] : ToolChain.select(source, choices[index].path));
}
function load(value) {
    source = value;
    choices = ToolChain.nodes(value);
    $id('choice').replaceChildren(...choices.map((item, index) => new Option(item.label, String(index))));
    $id('choice').disabled = false;
    choose();
}
function processInput() {
    status(); invalidate();
    if (kind === 'extract') {
        choices = ToolChain.extract($id('input').value);
        $id('choice').replaceChildren(...choices.map((item, index) => new Option(`候选 ${index + 1} · ${Array.isArray(item) ? '数组' : '对象'}`, String(index))));
        $id('choice').disabled = false; choose();
    } else if (kind === 'select') load(ToolChain.parse($id('input').value));
    else {
        const value = active ? source : ToolChain.parse($id('input').value);
        $id('code').value = ToolChain.types(value, $id('name').value.trim());
        ready($id('code').value);
    }
}
$id('process').onclick = () => { try { processInput(); } catch (error) { status(error.message); } };
$id('sample').onclick = () => {
    $id('input').value = kind === 'extract' ? '[INFO] 请求 GET /users\n响应如下：\n' + JSON.stringify(sample) + '\n[INFO] 请求结束'
        : JSON.stringify(kind === 'types' ? sample.data.items : sample, null, 2);
    invalidate(); status();
};
$id('input').oninput = invalidate;
if ($id('choice')) $id('choice').onchange = () => { try { choose(); status(); } catch (error) { invalidate(); status(error.message); } };
if ($id('code')) $id('code').oninput = () => ready($id('code').value);
$id('copy').onclick = async () => {
    try { await anywhere.clipboard.writeText(kind === 'types' ? $id('code').value : JSON.stringify(output, null, 2)); status('已复制。'); }
    catch (error) { status(error.message); }
};
$id('next').onclick = async () => {
    $id('next').disabled = true;
    try { await anywhere.workflow.complete(kind === 'types' ? $id('code').value : output); }
    catch (error) { $id('next').disabled = false; status(error.message); }
};
(async () => {
    const context = await anywhere.workflow.context();
    active = context.active;
    $id('mode').textContent = active ? '工作流步骤 · ' + ({extract: 'A', select: 'B', types: 'C'})[kind] : '独立工具';
    $id('next').hidden = !active;
    if (!active) return;
    if (kind === 'extract') $id('input').value = typeof context.input === 'string' ? context.input : JSON.stringify(context.input, null, 2);
    else {
        $id('standalone').hidden = true;
        source = context.input;
        if (kind === 'select') load(source);
        else processInput();
    }
})().catch(error => status(error.message));
