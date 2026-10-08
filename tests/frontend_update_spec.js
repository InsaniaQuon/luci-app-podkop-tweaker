// frontend_update_spec.js | v1.0.0 | 08.10.2026 | Transport and diagnostic regressions
// Run with node tests/frontend_update_spec.js [archive-path]. No dependencies.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
    constructor(tag) {
        this.tagName = tag;
        this.style = {};
        this.children = [];
        this.listeners = {};
        this._text = '';
        this.attrs = {};
        this.classList = { add() {}, remove() {} };
    }
    set textContent(text) { this._text = String(text); this.children = []; }
    get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
    set innerHTML(text) { this._text = text; this.children = []; }
    appendChild(child) { this.children.push(child); }
    addEventListener(event, cb) { this.listeners[event] = cb; }
    getAttribute(name) { return this.attrs[name] || null; }
}

class Form {
    constructor() { this.parts = []; }
    append(name, value, filename) { this.parts.push({ name, value, filename }); }
}

const requests = [];
class XHR {
    constructor() { this.headers = {}; requests.push(this); }
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(name, value) { this.headers[name] = value; }
    send(body) { this.body = body; }
}

const elements = {};
const root = { attrs: {}, style: { setProperty(key, value) { this[key] = value; } }, getAttribute(name) { return this.attrs[name]; }, setAttribute(name, value) { this.attrs[name] = value; } };
const document = {
    documentElement: root,
    querySelectorAll() { return []; },
    getElementById(id) { return elements[id] || (elements[id] = new Element('span')); },
    createElement(tag) { return new Element(tag); }
};
const window = { PT: { csrf: 'test-token', urls: { upload: '/upload', apply: '/apply' } } };
const context = vm.createContext({ window, document, XMLHttpRequest: XHR, FormData: Form, setTimeout() {} });
const repo = path.resolve(__dirname, '..');
vm.runInContext(fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8'), context);
const PT = window.PT;
context.PT = PT;
PT.checkStale = function() {};

// String POSTs keep their wire contract; multipart retains raw file bytes + CSRF.
PT.xhrPost('/save', 'content=value', function() {});
assert.equal(requests[0].body, 'token=test-token&content=value');
assert.equal(requests[0].headers['Content-Type'], 'application/x-www-form-urlencoded');

// Full error output is expandable and remains plain text, including markup.
const full = 'ERROR: unable to select packages:\n' + '<script>not executable</script>\n'.repeat(150) + 'dependency-output-end';
const errorEl = new Element('span');
PT.setErr(errorEl, 'Theme package installation failed', full);
assert.equal(errorEl.children[0].tagName, 'details');
assert.equal(errorEl.children[0].children[1].textContent, full);
assert.equal(errorEl.children[0].children[1].children.length, 0);
assert.equal(errorEl.style.whiteSpace, 'normal');
PT.setErr(errorEl, 'Network error');
assert.equal(errorEl.textContent, 'Network error');
assert.equal(errorEl.children.length, 0);

// Exercise the real Local Update change-handler. FileReader is deliberately absent.
const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/update.htm'), 'utf8');
const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
vm.runInContext(scripts[scripts.length - 1][1], context);
const input = elements['ps-file-input'];
const file = { name: 'luci-app-podkop-tweaker-v4.5.1.tar.gz', size: 110000 };
input.files = [file];
input.listeners.change();
const upload = requests[1];
assert.equal(upload.url, '/upload');
assert.ok(upload.body instanceof Form);
assert.equal(upload.headers['Content-Type'], undefined, 'browser must supply the multipart boundary');
assert.equal(upload.body.parts[0].value, file, 'upload must use the file itself, not a base64 text field');
assert.equal(upload.body.parts[0].filename, file.name);
assert.equal(upload.body.parts[1].name, 'token');
assert.equal(upload.body.parts[1].value, 'test-token');
assert.equal(input.disabled, true);

upload.status = 400;
upload.responseText = JSON.stringify({ error: 'Cannot read update request', details: full });
upload.onload();
assert.equal(input.disabled, false);
const status = elements['ps-update-actions'].children[0];
assert.equal(status.children[0].children[1].textContent, full);

const requestCount = requests.length;
input.files = [{ name: file.name, size: 128001 }];
input.listeners.change();
assert.equal(requests.length, requestCount, 'oversized archive must be rejected before sending');
assert.match(elements['ps-update-actions'].textContent, /Archive too large/);

if (process.argv[2]) {
    const archive = fs.readFileSync(process.argv[2]);
    const b64 = archive.toString('base64');
    const body = 'token=' + 'c'.repeat(64) + '&file_data=' + encodeURIComponent(b64) + '&file_name=' + encodeURIComponent(path.basename(process.argv[2]));
    console.log(`Archive: ${archive.length} bytes; old encoded POST: ${body.length} bytes; LuCI text limit: 102400 bytes`);
}
console.log('Frontend update regressions: PASS (multipart/CSRF, complete error details, size guard)');
