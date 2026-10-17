// Real shared editor/navigation and Diagnostics scripts, dependency-free VM regression.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');
const shared = fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');

class Element {
    constructor(tag = 'span') {
        this.tagName = tag.toUpperCase(); this.value = ''; this.disabled = false;
        this.style = { setProperty(key, value) { this[key] = value; } };
        this.attrs = {}; this.listeners = {}; this.children = []; this._text = '';
        this.classList = { add() {}, remove() {} }; this.parentNode = { insertBefore() {} };
    }
    getAttribute(key) { return this.attrs[key] ?? null; }
    setAttribute(key, value) { this.attrs[key] = value; }
    addEventListener(event, callback) { (this.listeners[event] ||= []).push(callback); }
    dispatchEvent(event) { for (const callback of this.listeners[event.type] || []) callback.call(this, event); }
    click() { if (!this.disabled) this.dispatchEvent({ type: 'click', button: 0 }); }
    set textContent(text) { this._text = String(text); this.children = []; }
    get textContent() { return this._text; }
    set innerHTML(text) {
        this._text = text; this.children = [];
        if (text.includes('<input')) { this.firstChild = new Element('input'); this.firstChild.checked = true; }
    }
    get innerHTML() { return this._text; }
    appendChild(child) { this.children.push(child); }
    getElementsByTagName() { return []; }
}
function setup() {
    const elements = {}, requests = [], timers = [], intervals = [], windowEvents = {}, documentEvents = {}, storage = {}, storageWrites = [], probes = [];
    const get = id => elements[id] ||= new Element();
    class XHR {
        constructor() { requests.push(this); this.headers = {}; }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader(key, value) { this.headers[key] = value; }
        getResponseHeader(key) { return key.toLowerCase() === 'content-type' ? this.contentType || null : null; }
        send(body) { this.body = body; }
        reply(body, status = 200, contentType = 'text/plain') { this.status = status; this.responseText = typeof body === 'string' ? body : JSON.stringify(body); this.contentType = contentType; this.onload(); }
        abort() { if (this.onabort) this.onabort(); }
    }
    class Image {
        constructor() { probes.push(this); }
        set src(value) { this.url = value; }
    }
    class Observer { constructor(fn) { this.fn = fn; } observe() {} disconnect() { this.disconnected = true; } }
    class FormData { constructor() { this.parts = []; } append(name, value, filename) { this.parts.push({ name, value, filename }); } }
    class Blob { constructor(parts) { this.data = parts.join(''); } }
    const document = { documentElement: get('root'), body: get('body'), head: get('head'),
        getElementById: get, querySelectorAll: selector => selector === '.ps-modal' ? Object.values(elements).filter(el => el.__ptModalHide) : [], querySelector: () => null,
        createElement: tag => new Element(tag), addEventListener(event, fn) { (documentEvents[event] ||= []).push(fn); } };
    const window = { PT: { csrf: 'token', urls: {} },
        location: { href: 'http://router.test/admin/services/podkop-tweaker/diagnostics', origin: 'http://router.test' },
        MutationObserver: Observer,
        addEventListener(event, fn) { windowEvents[event] = fn; }, removeEventListener(event) { delete windowEvents[event]; },
        open() { return null; } };
    const context = vm.createContext({ window, document, URL, Image, MutationObserver: Observer, XMLHttpRequest: XHR, FormData, Blob,
        sessionStorage: { getItem: key => storage[key] || null, setItem(key, value) { storage[key] = value; storageWrites.push({ key, value }); } },
        confirm: () => true, Event: class { constructor(type) { this.type = type; } },
        setTimeout(fn, delay) { const timer = { fn, delay }; timers.push(timer); return timer; },
        clearTimeout(timer) { if (timer) timer.cleared = true; },
        setInterval(fn, delay) { const timer = { fn, delay }; intervals.push(timer); return timer; },
        clearInterval(timer) { if (timer) timer.cleared = true; } });
    vm.runInContext(shared, context);
    context.PT = window.PT;
    return { get, window, context, requests, timers, intervals, windowEvents, documentEvents, storage, storageWrites, probes,
        key(key, overrides = {}) { const event = { key, preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; }, ...overrides }; for (const fn of documentEvents.keydown || []) fn(event); return event; },
        timer(delay) { const timer = timers.find(t => !t.cleared && !t.ran && t.delay === delay); assert.ok(timer, `missing ${delay}ms timer`); timer.ran = true; timer.fn(); } };
}

// Modal keyboard handling closes only the top visible overlay, with one cleanup.
{
    const s = setup(), a = s.get('modal-a'), b = s.get('modal-b'), close = s.get('close-a');
    let cleaned = 0;
    const hide = s.window.PT.bindModal(a, close, () => cleaned++);
    assert.equal(s.window.PT.bindModal(a, close), hide, 'rebinding is idempotent');
    s.window.PT.bindModal(b, s.get('close-b'));
    assert.equal(s.documentEvents.keydown.length, 1);
    a.style.display = b.style.display = 'flex';
    s.key('Enter'); s.key('Escape', { isComposing: true }); s.key('Escape', { defaultPrevented: true });
    assert.equal(b.style.display, 'flex');
    const event = s.key('Escape');
    assert.equal(event.prevented, true); assert.equal(event.stopped, true);
    assert.equal(b.style.display, 'none'); assert.equal(a.style.display, 'flex');
    assert.equal(cleaned, 0, 'Esc must not close every overlay');
    s.key('Escape'); assert.equal(a.style.display, 'none'); assert.equal(cleaned, 1);
    assert.equal(s.key('Escape').prevented, undefined, 'hidden modals do not consume Esc');
    a.style.display = 'flex'; a.dispatchEvent({ type: 'click', target: s.get('inside') });
    assert.equal(a.style.display, 'flex');
    a.dispatchEvent({ type: 'click', target: a }); assert.equal(cleaned, 2);
    a.style.display = 'flex'; close.click(); assert.equal(cleaned, 3);
    assert.equal(s.requests.length, 0, 'closing modals never submits a mutation');
}

function editorSetup() {
    const s = setup();
    s.window.PT.statusWatcher = () => ({ refresh() {}, poll(ok, fail, metadata) { s.poll = { ok, fail, metadata }; } });
    s.get('ps-error-modal').style.display = s.get('ps-diff-modal').style.display = 'none';
    s.ctx = s.window.PT.editorPage({ urls: { read: '/read', save: '/save', status: '/status', rollback: '/rollback' },
        texts: { saving: 'Saving', restarting: 'Restarting', saved: 'Saved', unchanged: 'Unchanged', notStarted: 'Restart failed', notStartedDetail: 'detail' }, extractError: r => ({ msg: r.error }) });
    s.editor = s.get('ps-config-editor');
    return s;
}

const restartAck = { success: true, restarting: true, verification_required: true,
    previous_running: true, previous_identity_known: true, previous_instance: '42:100' };
const runningInstance = (identity = '42:100') => ({ running: true, pid: identity.split(':')[0], instance: identity });
function watcherSetup() {
    const s = setup();
    s.watcher = s.window.PT.statusWatcher('/status', s.get('dot'), s.get('service-text'), s.get('toggle'));
    return s;
}
const badStatuses = [
    r => r.onerror(), r => r.ontimeout(), r => r.abort(),
    ...[null, [], {}, { error: 'pidof query failed', running: false }, { success: false, running: false },
        { running: 'false' }, { running: 0 }, { running: false, unknown: true }, { running: false, success: 'true' }, { running: true, pid: {} },
        { running: true, pid: '42', instance: 'not-an-identity' },
        { running: true, pid: '42', instance: '43:100' }, { running: false, instance: '42:100' },
        '<html>LuCI login</html>'].map(data => r => r.reply(data)),
    r => r.reply({ running: false }, 403)
];

// Service query failures are unknown observations, never factual absence or a
// Start/Stop decision. A later typed explicit GET can recover the controls.
for (const fail of badStatuses) {
    const s = watcherSetup();
    s.watcher.refresh(); fail(s.requests[0]);
    assert.equal(s.get('service-text').textContent, 'Unknown');
    assert.equal(s.get('dot').className, 'ps-status-dot checking');
    assert.equal(s.get('toggle').disabled, true);
    assert.equal(s.watcher.action(), null);
    s.watcher.refresh(); s.requests[1].reply({ running: false });
    assert.equal(s.get('service-text').textContent, 'Stopped');
    assert.equal(s.watcher.action(), 'start');
    assert.equal(s.get('toggle').disabled, false);
    s.watcher.refresh(); s.requests[2].reply(runningInstance());
    assert.equal(s.watcher.action(), 'stop');
}
{
    const s = watcherSetup(); let confirmed, failed;
    s.watcher.poll(r => { confirmed = r; }, r => { failed = r; }, restartAck);
    s.timer(2000); assert.equal(s.requests[0].timeout, 4000);
    s.requests[0].reply(runningInstance());
    assert.equal(confirmed, undefined, 'a still-alive old instance is not a restart');
    assert.equal(s.get('toggle').disabled, true, 'no concurrent toggle during verification');
    s.timer(2000); s.requests[1].reply(runningInstance('42:101'));
    assert.equal(confirmed.confirmed, true, 'PID reuse with a new start time is a new instance');
    assert.equal(confirmed.instance, '42:101');
    assert.equal(failed, undefined);
    assert.equal(s.get('toggle').disabled, false);
    assert.equal(s.requests.every(r => r.method === 'GET'), true);
}
{
    const s = watcherSetup(); let confirmed;
    s.watcher.poll(r => { confirmed = r; }, () => assert.fail('known absence can become a new running instance'),
        { verification_required: true, previous_running: false, previous_identity_known: true });
    s.timer(2000); s.requests[0].reply({ running: false });
    assert.equal(confirmed, undefined);
    s.timer(2000); s.requests[1].reply(runningInstance('73:900'));
    assert.equal(confirmed.confirmed, true);
}
for (const metadata of [undefined, {}, { ...restartAck, verification_required: false },
    { ...restartAck, unknown: true }, { ...restartAck, success: false }, { ...restartAck, error: 'Restart command failed' },
    { ...restartAck, previous_identity_known: false }, { ...restartAck, previous_instance: undefined },
    { verification_required: true, previous_running: false, previous_identity_known: false },
    { verification_required: true, previous_identity_known: true }]) {
    const s = watcherSetup(); let confirmed = 0, failure;
    s.watcher.poll(() => confirmed++, r => { failure = r; }, metadata);
    for (let i = 0; i < 8; i++) { s.timer(2000); s.requests[i].reply(runningInstance('73:900')); }
    assert.equal(confirmed, 0, 'missing/unknown previous identity cannot confirm a restart');
    assert.equal(failure.confirmed, false);
    assert.equal(failure.running, true);
    assert.equal(failure.reason, 'previous_unknown');
    assert.match(failure.message, /running, but restart is unconfirmed/);
}
for (const observation of [runningInstance(), { running: true, pid: '73', identity_error: 'Cannot read /proc identity' },
    { error: 'Service query failed', running: false }, { running: false }]) {
    const s = watcherSetup(); let failure;
    s.watcher.poll(() => assert.fail('unproven transition'), r => { failure = r; }, restartAck);
    for (let i = 0; i < 8; i++) { s.timer(2000); s.requests[i].reply(observation); }
    assert.equal(failure.confirmed, false);
    assert.equal(failure.known, !observation.error);
    if (observation.error) assert.match(failure.message, /unknown/);
    else if (!observation.running) assert.equal(failure.reason, 'not_running');
    else assert.match(failure.message, /running, but restart is unconfirmed/);
}
{
    const s = watcherSetup(); let confirmed = 0, failed;
    s.watcher.refresh();
    const stale = s.requests[0];
    s.watcher.poll(() => confirmed++, r => { failed = r; }, restartAck);
    stale.reply(runningInstance('73:900'));
    assert.equal(s.get('service-text').textContent, 'Unknown', 'pre-command responses cannot establish a post-command observation');
    s.timer(2000); const hanging = s.requests[1];
    s.timer(30000);
    assert.equal(failed.reason, 'status_unknown', 'the total deadline is bounded even if a request never completes');
    hanging.reply(runningInstance('73:900'));
    assert.equal(confirmed, 0, 'late readiness after timeout is ignored');
}
{
    const s = watcherSetup(); let old = 0, confirmed = 0;
    s.watcher.poll(() => old++, () => old++, restartAck);
    s.timer(2000); const stale = s.requests[0];
    s.watcher.poll(() => confirmed++, () => assert.fail('latest poll should confirm'), restartAck);
    stale.reply(runningInstance('73:900'));
    assert.equal(old, 0, 'a superseded poll cannot invoke either callback');
    s.timer(2000); s.requests[1].reply(runningInstance('73:900'));
    assert.equal(confirmed, 1);
}
function edit(s, text) {
    s.editor.value = text;
    s.editor.dispatchEvent({ type: 'input' });
}
function hasUnsavedChanges(s) {
    let prevented = false;
    s.windowEvents.beforeunload({ preventDefault() { prevented = true; } });
    return prevented;
}
function assertReadLocked(s) {
    for (const action of ['save', 'diff', 'undo']) assert.equal(s.get('ps-config-' + action).disabled, true, action + ' needs a successful current read');
}
function errorDetails(s) {
    s.get('ps-error-btn').click();
    assert.equal(s.get('ps-error-modal').style.display, 'flex');
    const details = s.get('ps-error-details');
    assert.equal(details.children.length, 0, 'complete diagnostics use plain text in the existing modal');
    const text = details.textContent;
    s.key('Escape');
    assert.equal(s.get('ps-error-modal').style.display, 'none');
    return text;
}
function assertUnsafeActionsBlocked(s) {
    const count = s.requests.length, text = s.editor.value, status = s.get('ps-config-status').textContent;
    s.get('ps-config-save').click();
    // Exercise the handlers themselves, even if a caller bypasses the disabled UI.
    s.get('ps-config-save').dispatchEvent({ type: 'click' });
    s.get('ps-config-save').disabled = false;
    for (const modifier of ['ctrlKey', 'metaKey']) assert.equal(s.key('s', { [modifier]: true }).prevented, true);
    for (const action of ['diff', 'undo']) s.get('ps-config-' + action).dispatchEvent({ type: 'click' });
    s.editor.dispatchEvent({ type: 'input' });
    assertReadLocked(s);
    assert.equal(s.requests.length, count, 'failed/pending reads cannot submit Save');
    assert.equal(s.get('ps-diff-modal').style.display, 'none', 'no diff against an unread or failed baseline');
    assert.equal(s.editor.value, text, 'blocked Undo retains the draft');
    assert.equal(s.get('ps-config-status').textContent, status, 'input cannot report Loaded after a failed/pending read');
}

const validConfigs = [
    "\nconfig section 'main'\n\toption user_domains_text 'example.test\n<html>literal UCI value</html>'\n",
    "config stubby 'global'\n\toption log_level '3'\n",
    '\n{\n  "inbounds": [],\n  "outbounds": [{"type":"direct","tag":"direct"}]\n}\n'
];
const htmlLogin = '\ufeff \n<!DOCTYPE HTML><html><body><form>LuCI login<script>literal()</script></form></body></html>';
const readFailures = [
    { name: 'empty HTTP 200', message: 'empty or whitespace-only', run: r => r.reply('') },
    { name: 'whitespace HTTP 200', message: 'empty or whitespace-only', run: r => r.reply(' \t\r\n\ufeff') },
    ...[
        [404, 'Sing-box config file not found'], [409, 'Sing-box config file is empty'],
        [500, 'Failed to read sing-box config'], [413, 'Sing-box config exceeds the size limit']
    ].map(([status, message]) => {
        const details = '<img src=x onerror=literal()> complete IO details\n' + 'diagnostic line\n'.repeat(100) + 'end of diagnostics';
        return { name: 'JSON HTTP ' + status, message, details, status,
            run: r => r.reply({ error: message, details }, status, 'application/json') };
    }),
    { name: 'plain HTTP error', message: 'HTTP error: 503', details: 'upstream unavailable\ncomplete diagnostic output', status: 503,
        run: r => r.reply('upstream unavailable\ncomplete diagnostic output', 503) },
    { name: 'invalid JSON error', message: 'HTTP error: 500', details: '{broken JSON', status: 500,
        run: r => r.reply('{broken JSON', 500, 'application/json') },
    { name: 'HTML HTTP 200 without HTML header', message: 'HTML login/error page', details: htmlLogin, run: r => r.reply(htmlLogin) },
    { name: 'HTML fragment header', message: 'HTML login/error page', details: '<div>LuCI login</div>',
        run: r => r.reply('<div>LuCI login</div>', 200, 'text/html; charset=utf-8') },
    { name: 'XHTML session header', message: 'HTML login/error page', details: '<?xml version="1.0"?><html>LuCI login</html>',
        run: r => r.reply('<?xml version="1.0"?><html>LuCI login</html>', 200, 'application/xhtml+xml') },
    { name: 'HTML HTTP 403', message: 'HTML login/error page', details: htmlLogin, status: 403, run: r => r.reply(htmlLogin, 403, 'text/html') },
    { name: 'HTTP 401 session', message: 'session expired or access denied', status: 401, run: r => r.reply('', 401) },
    { name: 'network', message: 'Network error', run: r => r.onerror() },
    { name: 'timeout', message: 'Request timed out', run: r => r.ontimeout() },
    { name: 'abort', message: 'Request aborted', run: r => r.abort() }
];

// A failed first read is never a baseline, even after input or forged Save/Ctrl+S.
for (const failure of readFailures) {
    const s = editorSetup(), request = s.requests[0];
    assert.equal(request.method, 'GET');
    assert.ok(Number.isFinite(request.timeout) && request.timeout > 0 && request.timeout <= 30000, 'config GET has a finite deadline');
    assertReadLocked(s);
    failure.run(request);
    assert.equal(s.editor.disabled, false, 'retained text stays accessible after failure');
    assert.equal(s.editor.value, '', failure.name);
    assert.equal(hasUnsavedChanges(s), false, 'failure itself does not dirty the editor');
    assertReadLocked(s);
    const status = s.get('ps-config-status').textContent;
    assert.ok(status.includes(failure.message), failure.name + ': specific read error is visible');
    const details = errorDetails(s);
    assert.ok(details.includes('Failed to load config: '), failure.name);
    assert.ok(details.includes(failure.message), failure.name);
    if (failure.details) assert.ok(details.endsWith(failure.details), failure.name + ': details are complete and literal');
    if (failure.status) assert.ok(details.includes('HTTP ' + failure.status), failure.name);

    edit(s, 'draft after failed read');
    assert.equal(hasUnsavedChanges(s), true);
    assertUnsafeActionsBlocked(s);
    const reported = s.timers.filter(timer => timer.delay === 600000).length;
    request.onerror(); request.ontimeout(); request.abort(); request.reply('late response must not become a baseline');
    assert.equal(s.timers.filter(timer => timer.delay === 600000).length, reported, 'read completion is handled once: ' + failure.name);
    assert.equal(s.editor.value, 'draft after failed read');
    assert.equal(s.get('ps-config-status').textContent, status);
    assertReadLocked(s);
    assert.equal(s.requests.length, 1, 'no automatic read retry or mutation');

    s.ctx.loadConfig();
    assert.equal(s.requests.length, 2, 'explicit ctx.loadConfig retries the GET');
    assert.equal(s.requests[1].method, 'GET');
    assert.equal(s.editor.value, 'draft after failed read', 'retry does not clear text while waiting');
    assert.equal(hasUnsavedChanges(s), true);
    assertUnsafeActionsBlocked(s);
    s.requests[1].reply(validConfigs[2]);
    assert.equal(s.editor.value, validConfigs[2]);
    assert.equal(s.get('ps-config-status').textContent, 'Loaded');
    assert.equal(hasUnsavedChanges(s), false);
    edit(s, validConfigs[2] + ' ');
    assert.equal(s.get('ps-config-save').disabled, false, 'successful retry unlocks editing');
    assert.equal(s.get('ps-config-diff').disabled, false);
    s.get('ps-config-undo').click();
    assert.equal(s.editor.value, validConfigs[2]);
    assert.equal(s.requests.every(r => r.method === 'GET'), true);
}

// Failed reloads retain both the draft and its previous successful baseline/dirty state.
for (const failure of readFailures) {
    const s = editorSetup(), original = validConfigs[0], draft = original + '# unsaved local edit\n';
    s.requests[0].reply(original);
    edit(s, draft);
    s.ctx.loadConfig();
    assertReadLocked(s);
    assert.equal(s.editor.value, draft);
    assert.equal(hasUnsavedChanges(s), true);
    failure.run(s.requests[1]);
    assert.equal(s.editor.value, draft, failure.name);
    assert.equal(hasUnsavedChanges(s), true, 'failed reload preserves dirty state: ' + failure.name);
    assertUnsafeActionsBlocked(s);
    const status = s.get('ps-config-status').textContent;
    edit(s, original);
    assert.equal(hasUnsavedChanges(s), false, 'failed reload retains the previous baseline: ' + failure.name);
    assertReadLocked(s);
    assert.equal(s.get('ps-config-status').textContent, status, 'matching the old baseline does not claim a successful read');
    edit(s, draft);
    assert.equal(hasUnsavedChanges(s), true);
    assert.equal(s.requests.every(r => r.method === 'GET'), true);
}

// Only the newest overlapping load can change text, readiness, controls or errors.
for (const stale of [r => r.reply('obsolete config'), ...readFailures.map(failure => failure.run)]) {
    const s = editorSetup(), old = s.requests[0];
    s.ctx.loadConfig();
    stale(old);
    assert.equal(s.editor.disabled, true, 'a stale terminal event cannot unlock a newer load');
    assert.equal(s.editor.value, '');
    assert.equal(s.get('ps-config-status').textContent, 'Loading...');
    assert.equal(s.timers.filter(timer => timer.delay === 600000).length, 0, 'no error from an obsolete request');
    assertReadLocked(s);
    s.requests[1].reply(validConfigs[1]);
    assert.equal(s.editor.value, validConfigs[1]);
    assert.equal(s.get('ps-config-status').textContent, 'Loaded');
    edit(s, validConfigs[1] + '# draft');
    assert.equal(s.get('ps-config-save').disabled, false);
}
{
    const s = editorSetup();
    s.requests[0].reply(validConfigs[2]);
    const draft = validConfigs[2] + ' ';
    edit(s, draft);
    s.ctx.loadConfig(); s.ctx.loadConfig();
    s.requests[2].reply({ error: 'Current file is empty', details: '0 bytes on disk' }, 409, 'application/json');
    const status = s.get('ps-config-status').textContent;
    s.requests[1].reply('older successful read');
    assert.equal(s.editor.value, draft, 'an older success cannot overwrite a newer failure or the draft');
    assert.equal(s.get('ps-config-status').textContent, status);
    assert.equal(hasUnsavedChanges(s), true);
    assertUnsafeActionsBlocked(s);
    s.ctx.loadConfig();
    s.requests[3].reply(validConfigs[2]);
    assert.equal(s.get('ps-config-status').textContent, 'Loaded');
    assert.equal(s.editor.value, validConfigs[2]);
}

// Valid UCI/JSON reads preserve exact bytes and the ordinary diff/save/undo flow.
for (const original of validConfigs) {
    const s = editorSetup();
    s.requests[0].reply(original);
    assert.equal(s.editor.value, original);
    assert.equal(s.get('ps-config-status').textContent, 'Loaded');
    edit(s, original + ' ');
    s.get('ps-config-diff').click();
    assert.equal(s.get('ps-diff-modal').style.display, 'flex');
    s.key('Escape');
    assert.equal(s.key('s', { ctrlKey: true }).prevented, true);
    assert.equal(s.requests[1].url, '/save');
    assert.equal(s.requests[1].body.parts[0].value.data, original + ' ');
    s.ctx.loadConfig();
    assert.equal(s.requests.length, 2, 'a pending save retains its sent-snapshot ownership');
    s.requests[1].reply({ success: true, unchanged: true });
    assert.equal(s.get('ps-config-status').textContent, 'Unchanged');
    assert.equal(hasUnsavedChanges(s), false);
    edit(s, original + ' another edit');
    s.get('ps-config-undo').click();
    assert.equal(s.editor.value, original + ' ', 'Undo uses the saved snapshot');
}

// Stubby's explicit Template recovery remains available after an editor read failure.
{
    const s = setup();
    s.window.PT.checkStale = () => {};
    s.window.PT.statusWatcher = () => ({ refresh() {}, poll() {} });
    s.window.PT.urls = { read: '/read', save: '/save', status: '/status', applyTemplate: '/template', initCheck: '/init/check' };
    const source = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/stubby.htm'), 'utf8');
    const scripts = [...source.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    vm.runInContext(scripts.at(-1)[1], s.context);
    s.requests.find(r => r.url === '/read').reply('');
    assertReadLocked(s);
    s.get('ps-params-btn').click();
    assert.equal(s.get('ps-params-modal').style.display, 'flex');
    assert.equal(s.get('ps-apply-template-btn').disabled, false);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0);
    s.get('ps-apply-template-btn').click();
    const request = s.requests.find(r => r.url === '/template');
    assert.equal(request.body, 'token=token');
    request.reply({ success: true });
    s.timer(2000);
    const retry = s.requests.filter(r => r.url === '/read').at(-1);
    assert.notEqual(retry, s.requests[0]);
    retry.reply(validConfigs[1]);
    assert.equal(s.get('ps-config-editor').value, validConfigs[1]);
    assert.equal(s.get('ps-config-status').textContent, 'Loaded');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'only the explicit Template action mutates');
}

// F2: POST A -> edit B during restart -> success keeps B dirty, diff baseline A.
{
    const s = setup();
    let poll;
    s.window.PT.statusWatcher = () => ({ refresh() {}, poll(ok, fail, metadata) { poll = { ok, fail, metadata }; } });
    s.window.PT.editorPage({ urls: { read: '/read', save: '/save', status: '/status' },
        texts: { saving: 'Saving', restarting: 'Restarting', saved: 'Saved', unchanged: 'Unchanged', notStarted: 'Restart failed', notStartedDetail: 'detail' }, extractError: r => ({ msg: r.error }) });
    s.requests[0].reply('original');
    const editor = s.get('ps-config-editor');
    editor.value = 'sent A'; editor.dispatchEvent({ type: 'input' });
    s.get('ps-config-save').click();
    assert.equal(s.requests[1].body.parts[0].name, 'content_file');
    assert.equal(s.requests[1].body.parts[0].value.data, 'sent A');
    assert.equal(s.requests[1].body.parts[1].value, 'token');
    s.requests[1].reply(restartAck);
    assert.equal(poll.metadata.previous_instance, '42:100');
    assert.equal(editor.disabled, false);
    editor.value = 'new B'; editor.dispatchEvent({ type: 'input' });
    assert.equal(s.get('ps-config-save').disabled, true, 'second mutation is blocked during restart');
    poll.ok({ confirmed: true, known: true, running: true, instance: '73:900' });
    assert.equal(s.get('ps-config-save').disabled, false);
    assert.match(s.get('ps-config-status').textContent, /unsaved changes remain/);
    let prevented = false;
    s.windowEvents.beforeunload({ preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
    s.get('ps-config-diff').click();
    assert.match(s.get('ps-diff-body').innerHTML, /sent A/);
    assert.match(s.get('ps-diff-body').innerHTML, /new B/);
    assert.doesNotMatch(s.get('ps-diff-body').innerHTML, /original/);
    s.key('Escape');
    assert.equal(s.get('ps-diff-modal').style.display, 'none');
    assert.equal(editor.value, 'new B', 'Esc retains the current unsaved editor text');
    assert.equal(s.get('ps-config-save').disabled, false);
    s.window.PT.errorReporter(s.get('other-error-btn'), s.get('other-error-modal'), s.get('other-error-details'), s.get('other-error-close')).push('failure', 'complete details');
    s.get('other-error-btn').click(); s.key('Escape');
    assert.equal(s.get('other-error-modal').style.display, 'none');
    s.get('ps-config-undo').click();
    assert.equal(editor.value, 'sent A');
    prevented = false;
    s.windowEvents.beforeunload({ preventDefault() { prevented = true; } });
    assert.equal(prevented, false);
}

// Disk publication and service restart are separate outcomes. Both the plain
// draft and Undo/Diff use the SENT snapshot after an applied restart failure.
for (const laterEdit of [false, true]) {
    const s = editorSetup(), details = '<script>literal restart output</script>\n' + 'restart diagnostic\n'.repeat(100);
    s.requests[0].reply('original');
    edit(s, 'sent A'); s.get('ps-config-save').click();
    if (laterEdit) edit(s, 'later B');
    s.requests[1].reply({ success: false, applied: true, error: 'Restart command failed', details });
    assert.equal(s.editor.value, laterEdit ? 'later B' : 'sent A');
    assert.equal(hasUnsavedChanges(s), laterEdit);
    assert.equal(s.get('ps-config-save').disabled, !laterEdit);
    assert.match(s.get('ps-config-status').textContent, /saved to disk, but restart failed or is unverified/);
    assert.ok(errorDetails(s).endsWith(details), 'complete backend diagnostics are literal and untruncated');
    assert.equal(s.poll, undefined, 'a failed command is not converted into a verified restart');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'no automatic POST retry');
    if (laterEdit) {
        s.get('ps-config-diff').click();
        assert.match(s.get('ps-diff-body').innerHTML, /sent A/);
        assert.doesNotMatch(s.get('ps-diff-body').innerHTML, /original/);
        s.key('Escape');
        s.get('ps-config-undo').click();
        assert.equal(s.editor.value, 'sent A');
        assert.equal(hasUnsavedChanges(s), false);
        assert.match(s.get('ps-config-status').textContent, /restart failed or is unverified/, 'Undo does not erase the service failure');
    }
}
// Lock-release uncertainty is independent of actual publication. Only an
// explicit applied=true may establish the SENT baseline; all unknown outcomes
// require a fresh successful config GET before another mutation.
for (const applied of [false, true]) {
    const s = editorSetup();
    s.requests[0].reply('original'); edit(s, 'sent A'); s.get('ps-config-save').click(); edit(s, 'later B');
    s.requests[1].reply({ success: false, unknown: true, ...(applied ? { applied: true } : {}), error: 'Cannot release owned lock' });
    assert.equal(s.editor.value, 'later B');
    assert.equal(hasUnsavedChanges(s), true);
    assertReadLocked(s);
    assert.match(s.get('ps-config-status').textContent, applied ? /saved to disk; finishing result unknown/ : /Save result unknown/);
    assert.equal(s.poll, undefined);
    const requests = s.requests.length;
    s.get('ps-config-save').dispatchEvent({ type: 'click' }); s.key('s', { ctrlKey: true }); s.get('ps-rollback-btn').dispatchEvent({ type: 'click' });
    assert.equal(s.requests.length, requests, 'unknown lock release cannot dispatch Save or Rollback');
    edit(s, applied ? 'sent A' : 'original');
    assert.equal(hasUnsavedChanges(s), false, 'baseline follows actual outcome, never inferred publication');
    edit(s, applied ? 'original' : 'sent A');
    assert.equal(hasUnsavedChanges(s), true);
    s.ctx.loadConfig(); s.requests[2].reply(applied ? 'sent A' : 'original');
    assert.equal(hasUnsavedChanges(s), false);
    edit(s, 'explicit later edit');
    assert.equal(s.get('ps-config-save').disabled, false, 'a successful current GET releases the editor mutation gate');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
{
    const s = editorSetup(), details = 'sing-box validation failed at line 7\n<script>literal diagnostic</script>';
    s.requests[0].reply('original'); edit(s, 'invalid candidate'); s.get('ps-config-save').click();
    s.requests[1].reply({ success: false, error: 'sing-box check failed', details });
    assert.equal(hasUnsavedChanges(s), true, 'a rejected candidate does not replace the disk baseline');
    assert.match(s.get('ps-config-status').textContent, /Save failed: sing-box check failed/);
    assert.ok(errorDetails(s).endsWith(details));
    s.get('ps-config-undo').click(); assert.equal(s.editor.value, 'original');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
for (const result of [undefined, { confirmed: false, known: false }, { confirmed: false, known: true, running: true, instance: '42:100' },
    { confirmed: false, known: true, running: false }]) {
    const s = editorSetup();
    s.requests[0].reply('original'); edit(s, 'sent A'); s.get('ps-config-save').click();
    s.requests[1].reply(restartAck);
    if (result === undefined) s.poll.ok(); else s.poll.fail(result);
    assert.equal(hasUnsavedChanges(s), false, 'disk baseline is saved even without a confirmed process transition');
    const message = s.get('ps-config-status').textContent;
    assert.match(message, /restart is unconfirmed/);
    if (result && result.known && result.running === false) assert.match(message, /not running/);
    else assert.doesNotMatch(message, /not running|did not start|restarted|Restart failed/);
    edit(s, 'later B');
    assert.match(s.get('ps-config-status').textContent, /restart is unconfirmed.*unsaved changes remain/);
    s.get('ps-config-undo').click(); assert.equal(s.editor.value, 'sent A');
}
for (const failure of [r => r.onerror(), r => r.ontimeout(), r => r.reply('<html>LuCI login</html>'), r => r.reply({})]) {
    const s = editorSetup();
    s.requests[0].reply('original'); edit(s, 'sent A'); s.get('ps-config-save').click();
    failure(s.requests[1]);
    assert.match(s.get('ps-config-status').textContent, /Save result unknown/);
    assert.equal(hasUnsavedChanges(s), true, 'a lost/malformed response does not invent a saved baseline');
    assertReadLocked(s);
    s.get('ps-config-save').dispatchEvent({ type: 'click' }); s.key('s', { ctrlKey: true });
    assert.equal(s.requests.length, 2, 'only an explicit GET can resolve an uncertain save');
    s.ctx.loadConfig(); s.requests[2].reply('sent A');
    assert.equal(hasUnsavedChanges(s), false);
}
for (const outcome of ['confirmed', 'running-unconfirmed', 'applied-failed']) {
    const s = editorSetup();
    s.requests[0].reply('original'); edit(s, 'sent A'); s.get('ps-config-save').click();
    s.requests[1].reply({ success: false, applied: true, error: 'Restart failed' });
    edit(s, 'draft B'); s.get('ps-rollback-btn').click();
    const rollback = s.requests[2]; assert.equal(rollback.url, '/rollback');
    assertReadLocked(s);
    if (outcome === 'applied-failed') rollback.reply({ success: false, applied: true, error: 'Rollback restart failed', details: 'complete failure' });
    else {
        rollback.reply(restartAck);
        assert.equal(s.poll.metadata.previous_instance, '42:100');
        if (outcome === 'confirmed') s.poll.ok({ confirmed: true });
        else s.poll.fail({ known: true, running: true, instance: '42:100' });
    }
    const read = s.requests[3]; assert.equal(read.method, 'GET');
    assert.equal(s.editor.value, 'draft B', 'rollback read keeps the unsaved draft while waiting');
    read.reply('backup restored');
    assert.equal(s.editor.value, 'draft B', 'rollback updates the disk baseline without discarding the draft');
    assert.equal(hasUnsavedChanges(s), true);
    assert.match(s.get('ps-config-status').textContent,
        outcome === 'confirmed' ? /new service instance.*unsaved changes remain/ : /restart.*unconfirmed|restart failed or is unverified/,
        'readback reports the observed process outcome while retaining the dirty draft');
    s.get('ps-config-diff').click();
    assert.match(s.get('ps-diff-body').innerHTML, /backup restored/);
    assert.doesNotMatch(s.get('ps-diff-body').innerHTML, /sent A/);
    s.key('Escape'); s.get('ps-config-undo').click();
    assert.equal(s.editor.value, 'backup restored');
    assert.equal(hasUnsavedChanges(s), false, 'Undo returns to the restored disk baseline');
    const message = s.get('ps-config-status').textContent;
    if (outcome === 'confirmed') assert.equal(message, 'Loaded', 'Undo may replace a completed success notice with the clean-baseline status');
    else assert.match(message, /restart.*unconfirmed|restart failed or is unverified/, 'Undo must retain unresolved service failure/uncertainty');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 2, 'Save and explicit Rollback only');
}
for (const applied of [false, true]) {
    const s = editorSetup();
    s.requests[0].reply('original'); edit(s, 'draft B'); s.get('ps-rollback-btn').dispatchEvent({ type: 'click' });
    s.requests[1].reply({ success: false, unknown: true, ...(applied ? { applied: true } : {}), error: 'Cannot release restore lock' });
    assert.equal(s.editor.value, 'draft B');
    assertReadLocked(s);
    assert.match(s.get('ps-config-status').textContent, applied ? /restored to disk; finishing result unknown/ : /Rollback result unknown/);
    assert.equal(s.requests.length, 2, 'unknown Rollback does not auto-read or replay a mutation');
    s.get('ps-rollback-btn').dispatchEvent({ type: 'click' });
    assert.equal(s.requests.length, 2);
    s.ctx.loadConfig(); s.requests[2].reply(applied ? 'backup restored' : 'original');
    assert.equal(s.editor.value, applied ? 'backup restored' : 'original');
}
{
    const s = editorSetup();
    s.requests[0].reply('original'); edit(s, 'draft B');
    s.get('ps-rollback-btn').dispatchEvent({ type: 'click' });
    s.requests[1].reply({ success: false, applied: true, error: 'Rollback restart failed' });
    s.requests[2].reply({ error: 'Cannot read restored config' }, 500, 'application/json');
    assert.equal(s.editor.value, 'draft B');
    assert.equal(hasUnsavedChanges(s), true);
    assertReadLocked(s);
    assert.match(s.get('ps-config-status').textContent, /restored to disk, but restart failed or is unverified.*Config read failed/);
    s.get('ps-config-save').dispatchEvent({ type: 'click' });
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'failed rollback readback cannot submit the draft');
}

// Navigation uses native tab click after initialization and bounded cleanup.
{
    const s = setup();
    let clicked = 0;
    const pane = new Element(); pane.setAttribute('data-tab-active', 'false');
    const group = new Element(); group.querySelector = () => pane;
    const tab = new Element(); tab.parentElement = { nextElementSibling: group };
    tab.querySelector = () => ({ click() { clicked++; pane.setAttribute('data-tab-active', 'true'); } });
    const child = { closed: false, location: { href: 'http://router.test/admin/services/podkop' },
        document: { documentElement: new Element(), querySelector: () => tab }, opener: s.window };
    s.window.open = () => child;
    assert.equal(s.window.PT.openPodkopDiagnostics('https://evil.test/admin/services/podkop'), false);
    assert.equal(s.window.PT.openPodkopDiagnostics('/admin/services/podkop'), true);
    assert.equal(child.opener, null);
    assert.equal(clicked, 0);
    group.setAttribute('data-initialized', 'true'); s.intervals[0].fn();
    assert.equal(clicked, 1);
    assert.equal(s.intervals[0].cleared, true);
    assert.equal(s.timers[0].cleared, true);
    assert.equal(s.windowEvents.pagehide, undefined);
}

function diagnostics(s, chain = { resolvers: [] }) {
    s.window.PT.checkStale = () => {};
    s.window.PT.version = 'test-version';
    s.window.PT.getJson = (url, callback) => { s.chainCallback = callback; if (chain !== null) callback(chain); };
    s.exports = [];
    s.window.PT.downloadJson = (filename, data) => s.exports.push({ filename, data: JSON.parse(JSON.stringify(data)) });
    s.window.PT.urls = { chainInfo: '/chain', dnsObservationStart: '/observe/start', dnsObservationResults: '/observe/results', diagDns: '/dns', diagProxy: '/proxy', diagE2e: '/e2e' };
    const source = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/diagnostics.htm'), 'utf8');
    const scripts = [...source.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    vm.runInContext(scripts[scripts.length - 1][1], s.context);
}
const runLogKey = 'pt-diag-run-log';
const diagnosticButtons = ['ps-dns-run', 'ps-proxy-run', 'ps-e2e-run', 'ps-leak-run', 'ps-run-all'];
const dnsResponse = { results: [
    { source: 'dot.example', target: '192.0.2.1', ip: '142.250.1.1', status: 'OK' },
    { source: 'Via Stubby', target: '127.0.0.53', ip: '142.250.1.1', status: 'OK' },
    { source: 'Via dnsmasq', target: '127.0.0.1', ip: '198.18.0.1', status: 'OK' }
] };
const proxyResponse = { results: [
    { source: 'sing-box mixed (:7890)', http_code: 200, time_ms: 11, status: 'OK', extra: { route: 'test' } },
    { source: 'second result', http_code: 204, time_ms: 0, status: 'OK' }
] };
const e2eResponse = { external_ip: '203.0.113.7', http_code: 200, time_ms: 34, status: 'OK' };
const localDiagnostics = [
    { button: 'ps-dns-run', url: '/dns', kind: 'dns', name: 'DNS Resolution Test', response: dnsResponse },
    { button: 'ps-proxy-run', url: '/proxy', kind: 'proxy', name: 'Proxy Connectivity Test', response: proxyResponse },
    { button: 'ps-e2e-run', url: '/e2e', kind: 'e2e', name: 'End-to-End Test', response: e2eResponse }
];
function logs(s) { return JSON.parse(s.storage[runLogKey] || '[]'); }
function logWrites(s) { return s.storageWrites.filter(write => write.key === runLogKey).map(write => JSON.parse(write.value)); }
function busy(s, expected) { for (const id of diagnosticButtons) assert.equal(s.get(id).disabled, expected, id); }
function activeTimers(s) { return s.timers.filter(timer => !timer.cleared && !timer.ran); }
function exportedLog(s) {
    assert.equal(s.get('ps-diaglog-download').disabled, false, 'a partial current log remains exportable');
    s.get('ps-diaglog-download').click();
    const exported = s.exports.at(-1);
    assert.match(exported.filename, /^\d{2}\.\d{2}\.\d{4}_\d{2}\.\d{2}-diagnostics-log\.json$/);
    assert.equal(exported.data.format, 'pt-diag-run');
    assert.equal(exported.data.tweaker_version, s.window.PT.version);
    assert.deepEqual(exported.data.entries, logs(s), 'export equals the exact current sessionStorage entries');
    return exported.data.entries;
}
function displayedFailure(s, kind) {
    if (kind === 'dns') return s.get('ps-dns-body').children[0].children[0].textContent;
    return s.get(kind === 'proxy' ? 'ps-proxy-error' : 'ps-e2e-ip').textContent;
}
function observationStart(id = '123') {
    return { success: true, provider: 'bash.ws', scope: 'current_browser', id,
        hosts: Array.from({ length: 6 }, (_, i) => `${i + 1}.${id}.bash.ws`) };
}
function observationResponse(changes = {}) {
    return { success: true, id: '123', complete: true, provider: 'bash.ws', scope: 'current_browser', control_request_scope: 'router',
        resolvers: [{ ip: '1.1.1.1', asn: '<script>plain</script>', country: 'X' }], control_request_ips: [{ ip: '203.0.113.1' }],
        conclusion: 'Resolver observations collected; compare with your intended DNS/routing policy', ...changes };
}
function startObservation(s, completeProbes = true) {
    s.get('ps-leak-run').click(); s.requests.at(-1).reply(observationStart());
    if (completeProbes) for (const probe of s.probes.slice(-6)) probe.onerror();
    else s.timer(6000);
    s.timer(1000);
    return s.requests.at(-1);
}

// The generated normal route remains the only navigation target; ordinary click
// uses the shared bounded native-tab helper and modified clicks stay native.
{
    const s = setup(); diagnostics(s); let target;
    s.window.PT.openPodkopDiagnostics = href => { target = href; return true; };
    const link = s.get('ps-podkop-diagnostics'); link.href = '/admin/services/podkop';
    const event = { type: 'click', button: 0, preventDefault() { this.prevented = true; } };
    link.dispatchEvent(event); assert.equal(target, link.href); assert.equal(event.prevented, true);
    target = null; link.dispatchEvent({ ...event, ctrlKey: true }); assert.equal(target, null);
    assert.equal(s.requests.length, 0);
}

// Full queue: one reset, ordered 500ms gaps, one progressive entry per step,
// continue after measured FAIL, application failure, schema and transport ERROR.
const failedDns = { results: dnsResponse.results.map((row, i) => i === 1 ? { ...row, ip: '', status: 'FAIL' } : row) };
const failedProxy = { results: proxyResponse.results.map((row, i) => i === 0 ? { ...row, http_code: 503, status: 'FAIL' } : row) };
const failedE2e = { ...e2eResponse, external_ip: 'unknown', http_code: 0, time_ms: 0, status: 'FAIL' };
for (const scenario of [
    { replies: [r => r.reply(proxyResponse), r => r.reply(dnsResponse), r => r.reply(e2eResponse)], statuses: ['OK', 'OK', 'OK'] },
    { replies: [r => r.reply(failedProxy), r => r.reply(failedDns), r => r.reply(failedE2e)], statuses: ['FAIL', 'FAIL', 'FAIL'] },
    { replies: [r => r.reply({ results: {}, error: 'sing-box is not running' }), r => r.reply({ error: 'DNS backend failed', details: 'original DNS details' }), r => r.reply({})], statuses: ['FAIL', 'ERROR', 'ERROR'] },
    { replies: [r => r.onerror(), r => r.reply(dnsResponse), r => r.ontimeout()], statuses: ['ERROR', 'OK', 'ERROR'] },
    { replies: [r => r.reply({ results: [] }), r => r.reply({ results: {} }), r => r.reply(e2eResponse)], statuses: ['ERROR', 'ERROR', 'OK'] }
]) {
    const s = setup(), old = { ts: '10:00:00', test: 'old run', status: 'OK', took_ms: 0, error: '', data: null };
    s.storage[runLogKey] = JSON.stringify([old]); diagnostics(s);
    assert.deepEqual(exportedLog(s), [old], 'refresh restores the prior exact log');
    s.get('ps-run-all').click(); busy(s, true);
    assert.deepEqual(logs(s), []); assert.equal(s.get('ps-diaglog-download').disabled, true);
    assert.equal(s.get('ps-run-all').textContent, 'Running...');
    const partials = [];
    for (let i = 0; i < 3; i++) {
        assert.equal(s.requests.length, i + 1);
        assert.equal(s.requests[i].url, ['/proxy', '/dns', '/e2e'][i]);
        assert.equal(s.requests[i].body, 'token=token');
        for (const id of diagnosticButtons) s.get(id).dispatchEvent({ type: 'click' });
        assert.equal(s.requests.length, i + 1, 'busy protection also covers programmatic clicks');
        const watchdog = activeTimers(s).find(timer => timer.delay === s.requests[i].timeout);
        assert.ok(watchdog);
        scenario.replies[i](s.requests[i]);
        assert.deepEqual(logs(s).map(entry => entry.status), scenario.statuses.slice(0, i + 1));
        assert.deepEqual(logs(s).map(entry => entry.test), ['Proxy Connectivity Test', 'DNS Resolution Test', 'End-to-End Test'].slice(0, i + 1));
        partials.push(exportedLog(s));
        const snapshot = s.storage[runLogKey], writes = logWrites(s).length;
        s.requests[i].onerror(); s.requests[i].ontimeout(); s.requests[i].abort(); s.requests[i].reply({ error: 'late duplicate' }); watchdog.fn();
        assert.equal(s.storage[runLogKey], snapshot); assert.equal(logWrites(s).length, writes, 'each step completes/logs once');
        if (i < 2) {
            busy(s, true); assert.equal(s.requests.length, i + 1, 'the queue waits for its 500ms gap');
            s.timer(500);
        }
    }
    assert.equal(partials[0].length, 1, 'a prior partial export is a snapshot');
    assert.deepEqual(logWrites(s).map(entries => entries.length), [0, 1, 2, 3], 'only the coordinator resets the queue log');
    busy(s, false); assert.equal(s.get('ps-run-all').textContent, 'Run All Diagnostics');
    assert.equal(s.probes.length, 0, 'Run All never starts external observation');
    assert.equal(activeTimers(s).length, 0, 'operation watchdogs are cleaned after completion');
    if (scenario.statuses.every(status => status === 'OK')) {
        const entries = logs(s);
        assert.deepEqual(entries[0].data, { http_code: 200, time_ms: 11, source: proxyResponse.results[0].source, results: proxyResponse.results });
        assert.deepEqual(entries[1].data, { rows: dnsResponse.results });
        assert.deepEqual(entries[2].data, { external_ip: e2eResponse.external_ip, http_code: 200, time_ms: 34 });
        const html = s.get('ps-diaglog-wrap').innerHTML;
        assert.ok(html.includes(s.window.PT.escapeHtml('results[0]: ' + JSON.stringify(proxyResponse.results[0]))));
        assert.ok(html.includes('rows[1]: ')); assert.ok(html.includes('external_ip: 203.0.113.7'));
        assert.ok(entries.every(entry => typeof entry.took_ms === 'number' && !('http_status' in entry)));
    }
    const restored = setup(); restored.storage[runLogKey] = s.storage[runLogKey]; diagnostics(restored);
    assert.deepEqual(exportedLog(restored), logs(s), 'refresh preserves the completed log exactly');
    assert.equal(restored.requests.length, 0, 'restoring the log does not replay tests');
    s.get('ps-dns-run').click(); assert.deepEqual(logs(s), [], 'the next single run resets once');
    s.requests[3].reply(dnsResponse); assert.equal(logs(s).length, 1); busy(s, false);
}

// Proxy's legacy summary is FIRST-result-authoritative, even when later valid
// rows disagree. Keep every row/extra field in the table, storage and export.
for (const firstStatus of ['OK', 'FAIL']) {
    const s = setup(); diagnostics(s);
    const results = proxyResponse.results.map((row, i) => {
        const status = i === 0 ? firstStatus : firstStatus === 'OK' ? 'FAIL' : 'OK';
        return { ...row, status, http_code: status === 'OK' ? 200 : 503 };
    });
    s.get('ps-proxy-run').click(); s.requests[0].reply({ results });
    const entry = logs(s)[0];
    assert.equal(entry.status, firstStatus);
    assert.deepEqual(entry.data, { http_code: results[0].http_code, time_ms: results[0].time_ms, source: results[0].source, results });
    assert.equal(s.get('ps-proxy-body').children.length, results.length);
    for (let i = 0; i < results.length; i++) assert.ok(s.get('ps-proxy-body').children[i].innerHTML.includes('>' + results[i].status + '</span>'));
    assert.equal(s.get('chain-singbox').className, 'ps-chain-line ' + (firstStatus === 'OK' ? 'ps-chain-ok' : 'ps-chain-fail'));
    assert.deepEqual(exportedLog(s)[0].data.results, results);
    assert.ok(s.get('ps-diaglog-wrap').innerHTML.includes(s.window.PT.escapeHtml('results[1]: ' + JSON.stringify(results[1]))));
    busy(s, false);
}

// Transport/schema errors never turn empty/default-filled aggregate objects into
// successful tests. Measured endpoint FAILs were exercised separately above.
const invalidLocal = {
    dns: [{ results: [] }, { results: {} }, { results: [null] }, { results: [{ ...dnsResponse.results[0], status: true }] },
        { results: [{ ...dnsResponse.results[0], ip: 1 }] }, { results: [{ ...dnsResponse.results[0], ip: '' }] },
        { results: [{ ...dnsResponse.results[0], target: {} }] }],
    proxy: [{ results: [] }, { results: {} }, { results: [null] }, { results: [{ ...proxyResponse.results[0], http_code: '200' }] },
        { results: [{ ...proxyResponse.results[0], time_ms: -1 }] }, { results: [{ ...proxyResponse.results[0], status: 'PASS' }] },
        { results: [{ ...proxyResponse.results[0], http_code: 503 }] },
        { results: [proxyResponse.results[0], { ...proxyResponse.results[1], status: 'PASS' }] }],
    e2e: [{ status: 'OK' }, { ...e2eResponse, external_ip: {} }, { ...e2eResponse, http_code: '200' },
        { ...e2eResponse, time_ms: null }, { ...e2eResponse, status: true }, { ...e2eResponse, status: 'FAIL' }]
};
for (const endpoint of localDiagnostics) {
    for (const reply of [
        ...[null, [], {}, true, 1, '"scalar"', '<html>LuCI login</html>', '{broken JSON', { success: false }, { error: true }, { error: { invalid: 'error shape' } },
            { ...endpoint.response, success: 'true' }, { ...endpoint.response, unknown: true }, ...invalidLocal[endpoint.kind]].map(body => r => r.reply(body)),
        r => r.reply(endpoint.response, 403), r => r.reply('unavailable\nfull HTTP details', 503),
        r => r.onerror(), r => r.ontimeout(), r => r.abort()
    ]) {
        const s = setup(); diagnostics(s); s.get(endpoint.button).click(); reply(s.requests[0]);
        const entry = logs(s)[0];
        assert.equal(entry.test, endpoint.name); assert.equal(entry.status, 'ERROR', endpoint.kind);
        assert.equal(typeof entry.http_status, 'number'); assert.ok(entry.error);
        assert.equal(logs(s).length, 1); busy(s, false);
        assert.equal(s.requests.length, 1, 'a failed diagnostic is not replayed');
        assert.ok(displayedFailure(s, endpoint.kind).includes(entry.error));
    }
}

// New error.data carries the COMPLETE parsed body, including nested facts, and
// neither the page renderer nor generic log/export drops/truncates diagnostics.
for (const endpoint of localDiagnostics) for (const httpStatus of [200, 500]) {
    const s = setup(); diagnostics(s);
    const details = '<img src=x onerror=literal()>\n' + 'full diagnostic line\n'.repeat(120) + 'diagnostic end';
    const body = { success: false, error: 'Original <error> & summary', details, applied: true, unknown: true, partial: true,
        phase: 'probe', resume_available: false, items: [{ error: 'nested error', restart: { previous_instance: '42:100', previous_identity_known: true } }], results: {} };
    s.get(endpoint.button).click(); s.requests[0].reply(body, httpStatus, 'application/json');
    const entry = logs(s)[0];
    assert.equal(entry.status, endpoint.kind === 'proxy' && httpStatus === 200 ? 'FAIL' : 'ERROR');
    assert.equal(entry.error, body.error); assert.deepEqual(entry.data, body);
    if (entry.status === 'ERROR') assert.equal(entry.http_status, httpStatus);
    assert.equal(displayedFailure(s, endpoint.kind), body.error + '\n' + details, 'UI keeps complete literal error/details');
    assert.ok(s.get('ps-diaglog-wrap').innerHTML.includes(s.window.PT.escapeHtml('details: ' + details)));
    assert.ok(s.get('ps-diaglog-wrap').innerHTML.includes(s.window.PT.escapeHtml('items[0]: ' + JSON.stringify(body.items[0]))));
    assert.deepEqual(exportedLog(s)[0].data, body); busy(s, false);
}

// DNS budget scales with all upstream queries, not the grouped chain labels;
// unknown chain facts retain a conservative fallback instead of a short cap.
for (const [chain, count] of [
    [{ resolvers: Array.from({ length: 24 }, (_, i) => ({ address: '192.0.2.' + (i + 1), tls_auth_name: 'same provider' })) }, 24],
    [{ resolvers: Array(6).fill({ address: '192.0.2.53', tls_auth_name: 'same provider' }) }, 6],
    [{ resolvers: {} }, 6], [null, 16], [{ error: 'Cannot read chain' }, 16],
    [{ success: false, resolvers: [] }, 16], [{ unknown: true, resolvers: [] }, 16],
    [{ resolvers: [null] }, 16], [{ resolvers: [{ address: 1 }] }, 16],
    [{ resolvers: [{ address: '192.0.2.53', tls_auth_name: {} }] }, 16],
    ...[NaN, Infinity, -Infinity, -1, 1.5, '6', 4294967295].map(length => [{ resolvers: { length } }, 16]),
    [{ resolvers: new Array(4294967295) }, 16]
]) {
    const s = setup(); diagnostics(s, chain); s.get('ps-dns-run').click();
    assert.equal(s.requests[0].timeout, (count + 2) * 60000 + 10000);
    assert.ok(Number.isInteger(s.requests[0].timeout) && s.requests[0].timeout > 0 && s.requests[0].timeout <= 2147483647);
    assert.equal(activeTimers(s)[0].delay, s.requests[0].timeout, 'watchdog and XHR share the same safe client budget');
    s.requests[0].reply(dnsResponse); assert.equal(logs(s)[0].status, 'OK');
}

// Exercise both sides of the actual signed-32-bit timer boundary through the
// real page/chain response. Reuse one provider label to avoid a giant DOM fixture.
for (const [count, expected] of [[35789, 2147470000], [35790, 2147483647], [40000, 2147483647]]) {
    const s = setup(); diagnostics(s, { resolvers: Array(count).fill({ address: '192.0.2.53', tls_auth_name: 'one provider' }) });
    s.get('ps-dns-run').click();
    assert.equal(s.requests[0].timeout, expected, 'large counts saturate safely instead of wrapping to an immediate timeout');
    assert.ok(Number.isInteger(s.requests[0].timeout) && s.requests[0].timeout >= 490000 && s.requests[0].timeout <= 2147483647);
    assert.equal(activeTimers(s)[0].delay, expected);
    s.requests[0].reply(dnsResponse); assert.equal(logs(s)[0].status, 'OK'); busy(s, false);
    assert.equal(activeTimers(s).length, 0);
}
for (const endpoint of localDiagnostics) {
    const s = setup(); diagnostics(s); s.get(endpoint.button).click(); const old = s.requests[0];
    if (endpoint.kind === 'proxy') assert.equal(old.timeout, 15000, 'one backend 10s curl + delivery margin');
    if (endpoint.kind === 'e2e') assert.equal(old.timeout, 25000, 'two serial 10s curls + delivery margin');
    s.timer(old.timeout);
    assert.equal(logs(s)[0].status, 'ERROR'); assert.equal(logs(s)[0].error, 'Request timed out'); busy(s, false);
    s.get(endpoint.button).click(); const snapshot = s.storage[runLogKey]; busy(s, true);
    old.reply(endpoint.response); old.onerror(); old.ontimeout();
    assert.equal(s.storage[runLogKey], snapshot); busy(s, true);
    assert.equal(s.get('ps-' + endpoint.kind + '-loading').style.display, 'block', 'late completion cannot hide the newer spinner');
    s.requests[1].reply(endpoint.response); assert.equal(logs(s).length, 1); busy(s, false);
}

// An E2E error cannot retain any preceding IP/HTTP/time/status measurement, even
// while a new Run All is still executing the earlier queue entries.
for (const reply of [r => r.onerror(), r => r.reply({}), r => r.reply({ error: 'original E2E error', details: 'details' }), r => r.reply(failedE2e)]) {
    const s = setup(); diagnostics(s); s.get('ps-e2e-run').click(); s.requests[0].reply(e2eResponse);
    s.get('ps-run-all').click();
    for (const field of ['ip', 'http', 'time', 'status']) assert.equal(s.get('ps-e2e-' + field).textContent, '\u2014');
    s.requests[1].reply(proxyResponse); s.timer(500); s.requests[2].reply(dnsResponse); s.timer(500);
    reply(s.requests[3]);
    assert.notEqual(s.get('ps-e2e-ip').textContent, e2eResponse.external_ip);
    assert.equal(s.get('ps-e2e-http').textContent, '\u2014'); assert.equal(s.get('ps-e2e-time').textContent, '\u2014');
    assert.doesNotMatch(s.get('ps-e2e-status').innerHTML, />OK</); busy(s, false);
}

// pagehide cancels an in-flight operation or an inter-step gap, preserves the
// partial log, and BFCache pageshow permits only a fresh explicit run.
for (const duringGap of [false, true]) {
    const s = setup(); diagnostics(s); s.get('ps-run-all').click();
    if (duringGap) s.requests[0].reply(proxyResponse);
    const snapshot = s.storage[runLogKey], pending = activeTimers(s).slice(), old = s.requests[0];
    s.windowEvents.pagehide(); assert.equal(activeTimers(s).length, 0);
    for (const timer of pending) timer.fn(); old.reply(proxyResponse);
    assert.equal(s.requests.length, 1); assert.equal(s.storage[runLogKey], snapshot);
    s.get('ps-dns-run').dispatchEvent({ type: 'click' }); assert.equal(s.requests.length, 1, 'hidden page cannot restart work');
    s.windowEvents.pageshow(); assert.equal(s.requests.length, 1, 'restoring the page never replays the queue');
    s.get('ps-e2e-run').click(); old.onerror(); busy(s, true);
    s.requests[1].reply(e2eResponse); busy(s, false); assert.equal(logs(s).length, 1);
}

{
    const s = setup(); diagnostics(s);
    s.get('ps-leak-run').click();
    assert.equal(s.requests[0].body, 'token=token');
    s.requests[0].reply(observationStart());
    assert.equal(s.probes.length, 6);
    for (const probe of s.probes) { assert.match(probe.url, /^https:\/\/[1-6]\.123\.bash\.ws\/$/); probe.onerror(); }
    s.timer(1000);
    assert.equal(s.requests[1].body, 'token=token&id=123');
    const response = observationResponse();
    s.requests[1].reply(response);
    assert.equal(s.get('ps-leak-status').textContent, 'OBSERVATIONS COLLECTED');
    assert.doesNotMatch(s.get('ps-leak-status').textContent, /No leak/);
    assert.equal(s.get('ps-leak-upstream').children.length, 0, 'provider labels render as plain text');
    const entry = JSON.parse(s.storage['pt-diag-run-log'])[0];
    assert.equal(entry.data.probes_completed, 6);
    assert.deepEqual(entry.data.resolvers, response.resolvers);
    assert.equal(s.get('ps-leak-run').disabled, false);
    const timeout = s.timers.find(timer => timer.delay === 6000);
    assert.equal(timeout.cleared, true); timeout.fn();
    assert.equal(s.requests.length, 2, 'late probe timeout must not create a second run');
    assert.equal(activeTimers(s).length, 0);
    assert.deepEqual(exportedLog(s)[0].data, { ...response, probes_completed: 6 });
}
{
    const s = setup(); diagnostics(s); s.get('ps-leak-run').click();
    s.requests[0].reply({ id: '123', hosts: ['evil.test'] });
    assert.equal(s.probes.length, 0);
    assert.equal(JSON.parse(s.storage['pt-diag-run-log'])[0].status, 'ERROR');
    assert.equal(s.get('ps-leak-run').disabled, false);
}
{
    const s = setup(); diagnostics(s); s.get('ps-run-all').click();
    assert.equal(s.requests[0].url, '/proxy', 'Run All does not implicitly start the external browser observation');
    assert.equal(s.probes.length, 0);
}

// A malformed start cannot initiate probes, even if the untrusted response
// includes a truthy success value, numeric ID, or six attacker-selected hosts.
for (const response of [
    null, [], {}, true, '"scalar"', '<html>login</html>', '{broken JSON',
    observationStart('id-'), observationStart('-id'), observationStart('x'.repeat(64)),
    { ...observationStart(), id: 123 }, { ...observationStart(), success: 'true' },
    { ...observationStart(), provider: 'other.test' }, { ...observationStart(), scope: 'router' },
    { ...observationStart(), hosts: {} }, { ...observationStart(), hosts: ['evil.test'] },
    { ...observationStart(), hosts: Array(6).fill('1.123.bash.ws') },
    { ...observationStart(), hosts: Array.from({ length: 6 }, (_, i) => `${i + 1}.123.bash.ws.evil.test`) }
]) {
    const s = setup(); diagnostics(s); s.get('ps-leak-run').click(); s.requests[0].reply(response);
    assert.equal(s.probes.length, 0); assert.equal(s.requests.length, 1);
    assert.equal(logs(s).length, 1); assert.equal(logs(s)[0].status, 'ERROR');
    assert.equal(s.get('ps-leak-status').textContent, 'INCONCLUSIVE'); busy(s, false);
    assert.equal(activeTimers(s).length, 0);
}

// Collection validates the actual backend envelope, boolean completion and every
// resolver/control row. Array-like objects and inconsistent completion are not
// coerced into an observation or silently normalized to an empty successful list.
for (const response of [
    null, [], {}, true, '"scalar"', '<html>login</html>', '{broken JSON',
    ...[
        { success: false }, { success: 'true' }, { id: 'another-run' }, { provider: 'other.test' }, { scope: 'router' },
        { control_request_scope: 'browser' }, { complete: 'false' }, { complete: 1 }, { complete: false },
        { resolvers: [] }, { resolvers: {} }, { resolvers: null }, { resolvers: { length: 0 } }, { resolvers: [null] },
        { resolvers: [{ ip: '<script>not an IP</script>' }] }, { resolvers: [{ ip: '999.1.1.1' }] },
        { resolvers: [{ ip: '1.1.1.1', asn: {} }] }, { resolvers: [{ ip: '1.1.1.1', country: 1 }] },
        { resolvers: Array(129).fill({ ip: '1.1.1.1' }) }, { control_request_ips: { length: 0 } },
        { control_request_ips: [{ ip: '2001:::1' }] }, { conclusion: {} }
    ].map(changes => observationResponse(changes))
]) {
    const s = setup(); diagnostics(s); const request = startObservation(s); request.reply(response);
    assert.equal(logs(s).length, 1); assert.equal(logs(s)[0].status, 'ERROR');
    assert.equal(s.get('ps-leak-status').textContent, 'INCONCLUSIVE');
    assert.equal(s.get('ps-leak-upstream').textContent, 'No observations');
    assert.equal(s.get('ps-leak-dnsmasq').textContent, '\u2014'); busy(s, false);
    assert.equal(s.requests.length, 2, 'malformed provider results do not schedule another collection');
    assert.equal(activeTimers(s).length, 0);
}

// Provider HTTP/application/transport errors keep their original diagnostics and
// body while remaining inconclusive; completion, logging and cleanup happen once.
for (const phase of ['start', 'collection']) for (const fail of [
    r => r.onerror(), r => r.ontimeout(), r => r.abort(),
    r => r.reply({ error: 'Provider failed', details: 'original <details>\n' + 'full output\n'.repeat(100), nested: { reason: 'upstream' } }),
    r => r.reply({ error: 'Provider HTTP failure', details: 'complete HTTP details', unknown: true }, 503)
]) {
    const s = setup(); diagnostics(s); let request;
    if (phase === 'start') { s.get('ps-leak-run').click(); request = s.requests[0]; }
    else request = startObservation(s);
    fail(request);
    const entry = logs(s)[0], snapshot = s.storage[runLogKey];
    assert.equal(entry.status, 'ERROR'); assert.equal(logs(s).length, 1);
    assert.equal(s.get('ps-leak-status').textContent, 'INCONCLUSIVE');
    assert.ok(s.get('ps-leak-detail').textContent.includes(entry.error));
    if (entry.data.details) assert.ok(s.get('ps-leak-detail').textContent.endsWith(entry.data.details));
    if (request.responseText) {
        const body = JSON.parse(request.responseText);
        assert.deepEqual(entry.data, { ...body, probes_completed: phase === 'start' ? 0 : 6 });
    }
    request.onerror(); request.ontimeout(); request.abort(); request.reply(observationResponse());
    assert.equal(s.storage[runLogKey], snapshot); busy(s, false);
    assert.equal(activeTimers(s).length, 0);
    assert.equal(s.probes.every(probe => probe.onload === null && probe.onerror === null && probe.url === ''), true);
    exportedLog(s);
}

// Native Lua JSON can encode an empty table as {}. Accept that exact empty case,
// then stop after THREE bounded collections with a factual INCONCLUSIVE outcome.
for (const empty of [[], {}]) {
    const s = setup(); diagnostics(s); let request = startObservation(s, false);
    const response = observationResponse({ complete: false, resolvers: empty, control_request_ips: empty, conclusion: 'No leak / VPN provider verdict' });
    for (let attempt = 1; attempt <= 3; attempt++) {
        assert.equal(request.timeout, 15000);
        request.reply(response);
        if (attempt < 3) {
            assert.deepEqual(logs(s), []); busy(s, true); s.timer(1500); request = s.requests.at(-1);
        }
    }
    assert.equal(s.requests.length, 4); assert.equal(logs(s).length, 1);
    assert.equal(logs(s)[0].status, 'ERROR'); assert.equal(logs(s)[0].data.probes_completed, 0);
    assert.equal(s.get('ps-leak-status').textContent, 'INCONCLUSIVE');
    assert.match(s.get('ps-leak-detail').textContent, /no conclusion about DNS leaks is possible/);
    assert.doesNotMatch(s.get('ps-leak-detail').textContent, /No leak|VPN/);
    assert.deepEqual(exportedLog(s)[0].data, { ...response, probes_completed: 0 });
    busy(s, false); assert.equal(activeTimers(s).length, 0);
}
{
    const s = setup(); diagnostics(s); const request = startObservation(s);
    const response = observationResponse({ resolvers: [{ ip: '2001:db8::1' }], control_request_ips: {}, conclusion: 'No leak / VPN provider verdict' });
    request.reply(response);
    assert.equal(logs(s)[0].status, 'OK'); assert.equal(s.get('ps-leak-upstream').textContent, '2001:db8::1');
    assert.equal(s.get('ps-leak-dnsmasq').textContent, '\u2014');
    assert.doesNotMatch(s.get('ps-leak-detail').textContent, /No leak|VPN/);
    assert.deepEqual(exportedLog(s)[0].data, { ...response, probes_completed: 6 });
}

// Start/probe/collection waits have a total deadline. Late start/results/events
// cannot affect a later run, and event completion is counted once per image.
for (const phase of ['start', 'probes', 'collection']) {
    const s = setup(); diagnostics(s); s.get('ps-leak-run').click();
    assert.equal(s.requests[0].timeout, 15000);
    if (phase !== 'start') s.requests[0].reply(observationStart());
    const handlers = s.probes.map(probe => probe.onerror);
    if (phase === 'collection') {
        for (const fn of handlers) { fn(); fn(); }
        s.timer(1000);
    }
    const old = s.requests.at(-1); s.timer(75000);
    assert.equal(logs(s)[0].status, 'ERROR'); assert.match(logs(s)[0].error, /timed out/);
    assert.equal(logs(s)[0].data.probes_completed, phase === 'collection' ? 6 : 0);
    busy(s, false); assert.equal(activeTimers(s).length, 0);
    s.get('ps-dns-run').click(); const snapshot = s.storage[runLogKey];
    old.reply(phase === 'start' ? observationStart() : observationResponse());
    for (const fn of handlers) fn();
    assert.equal(s.storage[runLogKey], snapshot); busy(s, true);
    assert.equal(s.probes.length, phase === 'start' ? 0 : 6);
    s.requests.at(-1).reply(dnsResponse); assert.equal(logs(s).length, 1); busy(s, false);
}
for (const phase of ['probes', 'settle', 'collection', 'retry']) {
    const s = setup(); diagnostics(s); s.get('ps-leak-run').click(); s.requests[0].reply(observationStart());
    const handlers = s.probes.map(probe => probe.onerror);
    if (phase !== 'probes') for (const fn of handlers) fn();
    if (phase === 'collection' || phase === 'retry') s.timer(1000);
    if (phase === 'retry') s.requests[1].reply(observationResponse({ complete: false, resolvers: [], conclusion: 'No observations yet' }));
    const pending = activeTimers(s).slice(), old = s.requests.at(-1), count = s.requests.length, snapshot = s.storage[runLogKey];
    s.windowEvents.pagehide();
    assert.equal(activeTimers(s).length, 0);
    assert.equal(s.probes.every(probe => probe.onload === null && probe.onerror === null && probe.url === ''), true);
    s.windowEvents.pageshow(); s.get('ps-proxy-run').click();
    for (const timer of pending) timer.fn(); for (const fn of handlers) fn(); old.reply(observationResponse());
    assert.equal(s.requests.length, count + 1, 'old timers/images/results cannot restart collection after page restoration');
    assert.equal(s.storage[runLogKey], snapshot); busy(s, true);
    s.requests.at(-1).reply(proxyResponse); busy(s, false); assert.equal(logs(s).length, 1);
}

// Adding browser facts must not mutate a parsed success or error.data object that
// may also belong to the shared transport/caller. Freeze the REAL adapter result.
for (const failed of [false, true]) {
    const s = setup(); diagnostics(s); const postJson = s.window.PT.postJson; let original;
    s.window.PT.postJson = (url, params, callback, timeout) => postJson(url, params, (data, error, xhr) => {
        if (url === '/observe/results') original = Object.freeze(data || error.data);
        callback(data, error, xhr);
    }, timeout);
    const request = startObservation(s);
    const body = failed ? { error: 'Provider failure', details: 'original diagnostics', partial: true } : observationResponse();
    request.reply(body);
    assert.deepEqual(JSON.parse(JSON.stringify(original)), body);
    assert.equal(Object.hasOwn(original, 'probes_completed'), false);
    assert.deepEqual(logs(s)[0].data, { ...body, probes_completed: 6 });
    busy(s, false);
}

console.log('Frontend flows: PASS (bounded editor reads/baselines, checked service transitions, dirty snapshots/rollback, native Podkop navigation, Diagnostics queue and typed outcomes, exact progressive log/storage/export, deadlines and stale-resource cleanup, distinct typed browser DNS observation)');
