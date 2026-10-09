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
    const elements = {}, requests = [], timers = [], intervals = [], windowEvents = {}, documentEvents = {}, storage = {}, probes = [];
    const get = id => elements[id] ||= new Element();
    class XHR {
        constructor() { requests.push(this); this.headers = {}; }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader(key, value) { this.headers[key] = value; }
        send(body) { this.body = body; }
        reply(body, status = 200) { this.status = status; this.responseText = typeof body === 'string' ? body : JSON.stringify(body); this.onload(); }
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
        sessionStorage: { getItem: key => storage[key] || null, setItem(key, value) { storage[key] = value; } },
        confirm: () => true, Event: class { constructor(type) { this.type = type; } },
        setTimeout(fn, delay) { const timer = { fn, delay }; timers.push(timer); return timer; },
        clearTimeout(timer) { if (timer) timer.cleared = true; },
        setInterval(fn, delay) { const timer = { fn, delay }; intervals.push(timer); return timer; },
        clearInterval(timer) { if (timer) timer.cleared = true; } });
    vm.runInContext(shared, context);
    context.PT = window.PT;
    return { get, window, context, requests, timers, intervals, windowEvents, documentEvents, storage, probes,
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

// F2: POST A -> edit B during restart -> success keeps B dirty, diff baseline A.
{
    const s = setup();
    let poll;
    s.window.PT.statusWatcher = () => ({ refresh() {}, poll(ok, fail) { poll = { ok, fail }; } });
    s.window.PT.editorPage({ urls: { read: '/read', save: '/save', status: '/status' },
        texts: { saving: 'Saving', restarting: 'Restarting', saved: 'Saved', unchanged: 'Unchanged', notStarted: 'Restart failed', notStartedDetail: 'detail' }, extractError: r => ({ msg: r.error }) });
    s.requests[0].reply('original');
    const editor = s.get('ps-config-editor');
    editor.value = 'sent A'; editor.dispatchEvent({ type: 'input' });
    s.get('ps-config-save').click();
    assert.equal(s.requests[1].body.parts[0].name, 'content_file');
    assert.equal(s.requests[1].body.parts[0].value.data, 'sent A');
    assert.equal(s.requests[1].body.parts[1].value, 'token');
    s.requests[1].reply({ success: true, restarting: true });
    assert.equal(editor.disabled, false);
    editor.value = 'new B'; editor.dispatchEvent({ type: 'input' });
    assert.equal(s.get('ps-config-save').disabled, true, 'second mutation is blocked during restart');
    poll.ok();
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

function diagnostics(s) {
    s.window.PT.checkStale = () => {};
    s.window.PT.getJson = (url, callback) => callback({ resolvers: [] });
    s.window.PT.urls = { chainInfo: '/chain', dnsObservationStart: '/observe/start', dnsObservationResults: '/observe/results', diagDns: '/dns', diagProxy: '/proxy', diagE2e: '/e2e' };
    const source = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/diagnostics.htm'), 'utf8');
    const scripts = [...source.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    vm.runInContext(scripts[scripts.length - 1][1], s.context);
}
{
    const s = setup(); diagnostics(s);
    s.get('ps-leak-run').click();
    assert.equal(s.requests[0].body, 'token=token');
    s.requests[0].reply({ success: true, id: '123', hosts: Array.from({ length: 6 }, (_, i) => `${i + 1}.123.bash.ws`) });
    assert.equal(s.probes.length, 6);
    for (const probe of s.probes) { assert.match(probe.url, /^https:\/\/[1-6]\.123\.bash\.ws\/$/); probe.onerror(); }
    s.timer(1000);
    assert.equal(s.requests[1].body, 'token=token&id=123');
    const response = { success: true, complete: true, provider: 'bash.ws', scope: 'current_browser', resolvers: [{ ip: '1.1.1.1', asn: '<script>plain</script>', country: 'X' }], control_request_ips: [{ ip: '203.0.113.1' }], conclusion: 'Observations only' };
    s.requests[1].reply(response);
    assert.equal(s.get('ps-leak-status').textContent, 'OBSERVATIONS COLLECTED');
    assert.doesNotMatch(s.get('ps-leak-status').textContent, /No leak/);
    assert.equal(s.get('ps-leak-upstream').children.length, 0, 'provider labels render as plain text');
    const entry = JSON.parse(s.storage['pt-diag-run-log'])[0];
    assert.equal(entry.data.probes_completed, 6);
    assert.deepEqual(entry.data.resolvers, response.resolvers);
    assert.equal(s.get('ps-leak-run').disabled, false);
    s.timer(6000);
    assert.equal(s.requests.length, 2, 'late probe timeout must not create a second run');
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
console.log('Frontend flows: PASS (saved snapshot/dirty state, native Podkop tab navigation, bounded browser DNS observation and exact run log)');
