// frontend_update_spec.js | v1.0.1 | 09.10.2026 | Transport and copyable diagnostic regressions
// Run with node tests/frontend_update_spec.js [archive-path]. No dependencies.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
    constructor(tag) {
        this.tagName = tag.toUpperCase();
        this.style = {};
        this.children = [];
        this.listeners = {};
        this._text = '';
        this.attrs = {};
        this.classList = { add() {}, remove() {}, contains() { return false; } };
    }
    set textContent(text) { this._text = String(text); this.children = []; }
    get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
    set innerHTML(text) { this._text = text; this.children = []; }
    appendChild(child) { if (child.parentNode) child.parentNode.removeChild(child); this.children.push(child); child.parentNode = this; }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
    insertBefore(child, before) { if (child.parentNode) child.parentNode.removeChild(child); const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentNode = this; }
    get firstChild() { return this.children[0]; }
    addEventListener(event, cb) { this.listeners[event] = cb; }
    getAttribute(name) { return this.attrs[name] || null; }
    setAttribute(name, value) { this.attrs[name] = value; }
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
function errorPre(el) { return el.children[0].children[1].children[1]; }
assert.equal(errorEl.children[0].tagName, 'DETAILS');
assert.equal(errorPre(errorEl).textContent, full);
assert.equal(errorPre(errorEl).children.length, 0);
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
assert.equal(errorPre(status).textContent, full);

const requestCount = requests.length;
input.files = [{ name: file.name, size: 128001 }];
input.listeners.change();
assert.equal(requests.length, requestCount, 'oversized archive must be rejected before sending');
assert.match(elements['ps-update-actions'].textContent, /Archive too large/);

// Equal-version upload exposes the action and explicitly opts into reinstall.
function uploadPreview(data) {
    input.files = [file];
    input.listeners.change();
    const request = requests[requests.length - 1];
    request.status = 200;
    request.responseText = JSON.stringify({ success: true, ...data });
    request.onload();
}
uploadPreview({ current_version: '4.7.0', archive_version: '4.7.0', same_version: true, can_update: false });
assert.match(elements['ps-update-actions'].textContent, /Reinstall/);
elements['ps-apply-btn'].listeners.click();
const reinstall = requests[requests.length - 1];
assert.match(reinstall.body, /^token=test-token&reinstall=1&restart_id=[a-f0-9]{32}$/);
assert.equal(elements['ps-apply-btn'].disabled, true);
assert.equal(input.disabled, true);
const whileApplying = requests.length;
input.listeners.change();
assert.equal(requests.length, whileApplying, 'new upload is blocked while application is pending');
reinstall.status = 200;
reinstall.responseText = JSON.stringify({ success: false, error: 'Update application failed', details: full });
reinstall.onload();
assert.equal(elements['ps-apply-btn'].disabled, false);
assert.equal(input.disabled, false);
assert.equal(errorPre(elements['ps-apply-status']).textContent, full);

uploadPreview({ current_version: '4.7.0', archive_version: '4.6.0', same_version: false, can_update: false });
assert.match(elements['ps-update-actions'].textContent, /older than installed/);
assert.doesNotMatch(elements['ps-update-actions'].textContent, /id="ps-apply-btn"/);
uploadPreview({ current_version: '4.7.0', archive_version: '4.7.1', same_version: false, can_update: true });
assert.match(elements['ps-update-actions'].textContent, /Update/);
assert.doesNotMatch(elements['ps-update-actions'].textContent, /Reinstall/);
elements['ps-apply-btn'].listeners.click();
assert.match(requests[requests.length - 1].body, /^token=test-token&restart_id=[a-f0-9]{32}$/, 'ordinary upgrade does not opt into reinstall');

if (process.argv[2]) {
    const archive = fs.readFileSync(process.argv[2]);
    const b64 = archive.toString('base64');
    const body = 'token=' + 'c'.repeat(64) + '&file_data=' + encodeURIComponent(b64) + '&file_name=' + encodeURIComponent(path.basename(process.argv[2]));
    console.log(`Archive: ${archive.length} bytes; old encoded POST: ${body.length} bytes; LuCI text limit: 102400 bytes`);
}
console.log('Frontend update regressions: PASS (multipart/CSRF, same-version reinstall, downgrade UI, apply lock, complete error details, size guard)');
