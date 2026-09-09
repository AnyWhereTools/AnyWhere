// 三个独立工具的纯转换逻辑。没有宿主、页面、剪贴板或工作流依赖。
var ToolChain = (() => {
    function checkText(text) {
        if (typeof text !== 'string' || encodeURIComponent(text).replace(/%[A-F0-9]{2}/g, 'x').length > 131072) {
            throw new Error('请输入不超过 128 KiB 的文本。');
        }
    }
    function checkValue(value, depth = 0, budget = {left: 2000}) {
        if (depth > 64 || --budget.left < 0) throw new Error('数据过于复杂：最多 64 层、2000 个节点。');
        if (typeof value === 'number' && (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) {
            throw new Error('数值超出安全范围，请将大整数 ID 写成字符串。');
        }
        if (value && typeof value === 'object') Object.values(value).forEach(v => checkValue(v, depth + 1, budget));
        return value;
    }
    function parse(text) { checkText(text); return checkValue(JSON.parse(text)); }
    function extract(text) {
        checkText(text);
        const found = [];
        let attempts = 0;
        for (let start = 0; start < text.length; start++) {
            if (text[start] !== '{' && text[start] !== '[') continue;
            if (++attempts > 256) throw new Error('候选片段过多，请先缩小输入范围。');
            const stack = [];
            let quoted = false, escaped = false;
            for (let end = start; end < text.length; end++) {
                const c = text[end];
                if (quoted) {
                    if (escaped) escaped = false;
                    else if (c === '\\') escaped = true;
                    else if (c === '"') quoted = false;
                    continue;
                }
                if (c === '"') quoted = true;
                else if (c === '{' || c === '[') {
                    stack.push(c);
                    if (stack.length > 64) throw new Error('JSON 嵌套超过 64 层。');
                } else if (c === '}' || c === ']') {
                    if (stack.pop() !== (c === '}' ? '{' : '[')) break;
                    if (!stack.length) {
                        let value;
                        try { value = JSON.parse(text.slice(start, end + 1)); }
                        catch (_) { break; }
                        found.push(checkValue(value));
                        start = end;
                        break;
                    }
                }
            }
        }
        if (!found.length) throw new Error('没有找到有效的 JSON 对象或数组，请检查输入。');
        return found;
    }
    function nodes(value) {
        checkValue(value);
        const result = [];
        function visit(item, path) {
            const pointer = '$' + path.map(key => '/' + String(key).replace(/~/g, '~0').replace(/\//g, '~1')).join('');
            const kind = item === null ? 'null' : Array.isArray(item) ? `数组 · ${item.length} 项` : typeof item === 'object' ? '对象' : typeof item;
            result.push({path, label: `${pointer} — ${kind}`});
            if (item && typeof item === 'object') Object.keys(item).forEach(key => visit(item[key], path.concat(key)));
        }
        visit(value, []);
        return result;
    }
    function select(value, path) {
        return path.reduce((item, key) => {
            if (!item || !Object.prototype.hasOwnProperty.call(item, key)) throw new Error('节点已不存在，请重新选择。');
            return item[key];
        }, value);
    }
    function types(value, name = 'Response') {
        checkValue(value);
        if (!/^[A-Z][A-Za-z0-9_]*$/.test(name)) throw new Error('类型名需以大写字母开头，只含字母、数字和下划线。');
        function infer(values, depth) {
            if (!values.length) return 'unknown';
            const variants = [];
            for (const kind of ['string', 'number', 'boolean']) if (values.some(v => typeof v === kind)) variants.push(kind);
            if (values.some(v => v === null)) variants.push('null');
            const arrays = values.filter(Array.isArray);
            if (arrays.length) variants.push(`Array<${infer(arrays.flat(), depth)}>`);
            const objects = values.filter(v => v !== null && typeof v === 'object' && !Array.isArray(v));
            if (objects.length) {
                const keys = [...new Set(objects.flatMap(Object.keys))].sort();
                const lines = keys.map(key => {
                    const present = objects.filter(o => Object.prototype.hasOwnProperty.call(o, key));
                    const prop = /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key) ? key : JSON.stringify(key);
                    return '  '.repeat(depth + 1) + prop + (present.length < objects.length ? '?' : '') + ': ' + infer(present.map(o => o[key]), depth + 1) + ';';
                });
                variants.push(lines.length ? '{\n' + lines.join('\n') + '\n' + '  '.repeat(depth) + '}' : 'Record<string, never>');
            }
            return variants.join(' | ');
        }
        return `export type ${name} = ${infer([value], 0)};`;
    }
    return {parse, extract, nodes, select, types};
})();
