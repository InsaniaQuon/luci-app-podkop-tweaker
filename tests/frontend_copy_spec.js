// frontend_copy_spec.js | v1.1.0 | 09.10.2026 | Clipboard transport, icon states and editor preservation
// Run: node tests/frontend_copy_spec.js. No dependencies or OS clipboard writes.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const shared = fs.readFileSync(path.join(__dirname, '../www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');

function setup(clipboard, exec = () => true) {
    const timers = [], writes = [];
    const root = { style: { setProperty() {} }, getAttribute() {}, setAttribute() {} };
    const document = { documentElement: root, querySelectorAll: () => [], getElementById: () => null };
    class Element {
        constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.events = {}; this.style = {}; this.classList = { add() {}, contains: () => false }; }
        appendChild(child) { if (child.parentNode) child.parentNode.removeChild(child); this.children.push(child); child.parentNode = this; }
        insertBefore(child, before) { if (child.parentNode) child.parentNode.removeChild(child); const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentNode = this; }
        get firstChild() { return this.children[0]; }
        removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
        setAttribute(key, value) { this.attrs[key] = value; }
        addEventListener(type, fn) { this.events[type] = fn; }
        focus() { document.activeElement = this; }
        select() { this.selectionStart = 0; this.selectionEnd = this.value.length; }
    }
    document.createElement = tag => new Element(tag);
    document.body = new Element('body');
    const editor = new Element('textarea');
    Object.assign(editor, { value: 'original config', selectionStart: 3, selectionEnd: 8, selectionDirection: 'backward', scrollTop: 210, scrollLeft: 90 });
    editor.setSelectionRange = (start, end, direction) => Object.assign(editor, { selectionStart: start, selectionEnd: end, selectionDirection: direction });
    document.activeElement = editor;
    const originalRange = { cloneRange() { return this; } };
    const selection = { ranges: [originalRange], get rangeCount() { return this.ranges.length; }, getRangeAt(i) { return this.ranges[i]; }, removeAllRanges() { this.ranges = []; }, addRange(range) {
        this.ranges.push(range);
        // Match the native Chromium regression: DOM-range restoration resets
        // the input selection unless its text selection is restored afterwards.
        editor.setSelectionRange(0, 0, 'forward');
    } };
    document.execCommand = command => { assert.equal(command, 'copy'); writes.push(document.activeElement.value); return exec(); };
    const window = { PT: {}, navigator: { clipboard }, scrollX: 12, scrollY: 230, getSelection: () => selection, scrollTo(x, y) { this.scrollX = x; this.scrollY = y; } };
    vm.runInNewContext(shared, { window, document, Promise, setTimeout(fn) { timers.push(fn); return timers.length; }, clearTimeout() {} });
    return { PT: window.PT, window, document, editor, selection, originalRange, writes, timers, Element };
}

async function main() {
    const text = '\tconfig settings\n' + '<script>literal HTML, not executed</script>\n'.repeat(3000) + 'last line\n';
    const modern = [];
    let s = setup({ writeText(value) { modern.push(value); return Promise.resolve(); } });
    assert.equal(await s.PT.copyText(text), true);
    assert.equal(modern[0], text, 'modern copy must not truncate or trim');
    assert.equal(s.writes.length, 0, 'secure clipboard success needs no selection fallback');

    for (const clipboard of [undefined, { writeText() { return Promise.reject(new Error('permission denied')); } }, { writeText() { throw new Error('insecure context'); } }]) {
        s = setup(clipboard);
        assert.equal(await s.PT.copyText(text), true);
        assert.equal(s.writes[0], text);
        assert.equal(s.document.body.children.length, 0, 'temporary textarea must be removed');
        assert.equal(s.document.activeElement, s.editor);
        assert.equal(s.editor.value, 'original config');
        assert.deepEqual([s.editor.selectionStart, s.editor.selectionEnd, s.editor.selectionDirection, s.editor.scrollTop, s.editor.scrollLeft], [3, 8, 'backward', 210, 90]);
        assert.equal(s.selection.ranges[0], s.originalRange);
        assert.deepEqual([s.window.scrollX, s.window.scrollY], [12, 230]);
    }
    for (const exec of [() => false, () => { throw new Error('copy unavailable'); }]) {
        s = setup(undefined, exec);
        assert.equal(await s.PT.copyText(text), false, 'failed fallback must not claim success');
        assert.equal(s.document.body.children.length, 0);
        assert.equal(s.document.activeElement, s.editor);
    }

    s = setup({ writeText(value) { modern.push(value); return Promise.resolve(); } });
    const source = new s.Element('pre'), anchor = new s.Element('summary');
    source.textContent = text;
    const button = s.PT.addCopyButton(source, { anchor });
    assert.equal(s.PT.addCopyButton(source, { anchor }), button);
    assert.equal(anchor.children.length, 1, 'repeated initialization must not stack buttons');
    let prevented = 0, stopped = 0;
    button.events.click({ preventDefault() { prevented++; }, stopPropagation() { stopped++; } });
    source.textContent = 'new output during pending copy';
    assert.equal(button.disabled, true);
    await Promise.resolve(); await Promise.resolve();
    assert.equal(modern[modern.length - 1], text, 'copy the complete click-time snapshot');
    assert.equal(button.attrs['data-pt-copy-state'], 'done');
    assert.equal(button.title, 'Copied');
    assert.equal(button.disabled, false);
    assert.equal(prevented, 1); assert.equal(stopped, 1, 'copy must not toggle the error disclosure');
    s.timers[0](); assert.equal(button.attrs['data-pt-copy-state'], 'copy');
    assert.match(button.innerHTML, /<svg[^>]*aria-hidden="true"/);
    assert.equal(s.PT.copyContent(s.editor), 'original config');
    assert.equal(s.PT.copyContent({ tagName: 'DIV', innerText: 'summary\ndetail\nlast row', textContent: 'summarydetaillast row' }), 'summary\ndetail\nlast row');

    s = setup(undefined, () => false);
    const failed = s.PT.addCopyButton(new s.Element('pre'), { anchor: new s.Element('summary') });
    failed.events.click({ preventDefault() {}, stopPropagation() {} });
    await Promise.resolve();
    assert.equal(failed.attrs['data-pt-copy-state'], 'error');
    assert.equal(failed.disabled, false, 'failed copy remains retryable');

    // Expanded error icons move into the framed source, then back to the
    // collapsed summary. One button keeps the same source binding throughout.
    s = setup({ writeText() { return Promise.resolve(); } });
    const error = new s.Element('span');
    s.PT.setErr(error, 'HTTP error: 403', text);
    const disclosure = error.children[0], summary = disclosure.children[0];
    const panel = disclosure.children[1], tools = panel.children[0], pre = panel.children[1];
    const icon = pre.__ptCopyButton;
    assert.equal(pre.textContent, text);
    assert.equal(icon.parentNode, summary);
    disclosure.open = true; disclosure.events.toggle();
    assert.equal(icon.parentNode, tools);
    assert.equal(summary.children.length, 0);
    assert.equal(pre.children.length, 0, 'controls must not pollute the plaintext source');
    disclosure.open = false; disclosure.events.toggle();
    assert.equal(icon.parentNode, summary);
    assert.equal(tools.children.length, 0);
    console.log('Frontend clipboard: PASS (exact full text, secure/HTTP/denied paths, selection+scroll preservation, cleanup, snapshots and truthful feedback)');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
