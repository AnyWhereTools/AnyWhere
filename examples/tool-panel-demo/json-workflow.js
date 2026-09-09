// macOS 自带 JXA；stdout 仅返回下一步的数据，抛错通过 stderr/非零退出码停止工作流。
ObjC.import('AppKit');
ObjC.import('Foundation');

function run(argv) {
    // 自测使用命名剪贴板，正常运行使用系统剪贴板。
    const testBoard = $.NSProcessInfo.processInfo.environment.objectForKey('ANYWHERE_DEMO_PASTEBOARD');
    const board = testBoard.isNil() ? $.NSPasteboard.generalPasteboard : $.NSPasteboard.pasteboardWithName(testBoard);
    const operation = argv[0];
    if (operation === 'read') {
        const changeCount = Number(board.changeCount);
        const value = board.stringForType($.NSPasteboardTypeString);
        if (value.isNil() || !ObjC.unwrap(value).trim()) throw new Error('请先复制需要整理的 JSON 文本。');
        return JSON.stringify({text: ObjC.unwrap(value), changeCount: changeCount});
    }

    const file = $.NSString.stringWithContentsOfFileEncodingError(argv[1], $.NSUTF8StringEncoding, null);
    if (file.isNil()) throw new Error('无法读取工作流输入。请从扩展包的工作流入口运行。');
    const input = JSON.parse(ObjC.unwrap(file)).input;
    if (!input || typeof input.text !== 'string' || !Number.isInteger(input.changeCount)) {
        throw new Error('缺少上一步的文本或剪贴板版本，请运行完整工作流。');
    }

    if (operation === 'format' || operation === 'compact') {
        let value;
        try {
            value = JSON.parse(input.text, function (key, item) {
                if (typeof item === 'number' && (!Number.isFinite(item) || (Number.isInteger(item) && !Number.isSafeInteger(item)))) {
                    throw new Error('数值超出 JavaScript 安全范围，请将大整数 ID 写成字符串');
                }
                return item;
            });
        } catch (error) {
            throw new Error('无法整理 JSON，原剪贴板未修改：' + error.message);
        }
        return JSON.stringify({text: JSON.stringify(value, null, operation === 'format' ? 2 : 0), changeCount: input.changeCount});
    }

    if (operation === 'write') {
        if (Number(board.changeCount) !== input.changeCount) {
            throw new Error('运行期间剪贴板已变化，未覆盖新内容。请重新运行。');
        }
        board.clearContents;
        if (!board.setStringForType(input.text, $.NSPasteboardTypeString)) throw new Error('写入剪贴板失败，请重试。');
        // 返回 JSON 字符串，宿主会按原样显示格式化文本，而不会再次重新排版压缩结果。
        return JSON.stringify(input.text);
    }
    throw new Error('未知工作流步骤：' + operation);
}
