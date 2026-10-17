// Real Stubby page + shared transport/editor/restart scripts; no dependencies or router IO.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');
const shared = fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');
const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/stubby.htm'), 'utf8');
const script = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].at(-1)[1];
const urls = { read: '/read', save: '/save', status: '/status', toggle: '/toggle', rollback: '/rollback',
    autostart: '/autostart', autostartToggle: '/autostart/toggle', applyTemplate: '/template', initCheck: '/init/check', initFix: '/init/fix' };
const forms = {
    template: { open: 'ps-params-btn', modal: 'ps-params-modal', close: 'ps-params-close', apply: 'ps-apply-template-btn', status: 'ps-apply-template-status', url: '/template' },
    init: { open: 'ps-initfix-btn', modal: 'ps-initfix-modal', close: 'ps-initfix-close', apply: 'ps-initfix-apply', status: 'ps-initfix-apply-status', url: '/init/fix' }
};
const original = "config stubby 'global'\n\toption marker 'original-disk'\n";
const template = "config stubby 'global'\n\toption marker 'checked-template-disk'\n";
const sentDraft = "config stubby 'global'\n\toption marker 'sent-editor-draft'\n";
const laterDraft = "config stubby 'global'\n\toption marker 'later-editor-draft'\n";
const restartAck = { success: true, applied: true, restarting: true, verification_required: true,
    previous_running: true, previous_identity_known: true, previous_instance: '42:100' };
const running = (instance = '42:100') => ({ running: true, pid: instance.split(':')[0], instance });
const longDetails = '<script>literal command output</script>\n' + 'complete native diagnostic <&>\n'.repeat(600) + 'END OF COMPLETE OUTPUT';

function freeze(value) {
    if (value && typeof value === 'object' && !Object.isFrozen(value)) {
        Object.values(value).forEach(freeze);
        Object.freeze(value);
    }
    return value;
}

function setup(options = {}) {
    const elements = {}, requests = [], timers = [], events = {}, documentEvents = {}, replies = [], polls = [], readbacks = [], confirmations = [];
    let now = 0, confirmed = true;
    class Element {
        constructor(tag = 'span') {
            this.tagName = tag.toUpperCase(); this.attrs = {}; this.children = []; this.listeners = {};
            this.value = ''; this.disabled = false; this.className = ''; this._text = ''; this._html = '';
            this.style = { setProperty(key, value) { this[key] = value; } };
            this.classList = {
                contains: name => this.className.split(/\s+/).includes(name),
                add: name => { if (!this.classList.contains(name)) this.className += ' ' + name; },
                remove: name => { this.className = this.className.split(/\s+/).filter(value => value !== name).join(' '); }
            };
        }
        getAttribute(key) { return this.attrs[key] ?? null; }
        setAttribute(key, value) { this.attrs[key] = String(value); }
        addEventListener(event, callback) { (this.listeners[event] ||= []).push(callback); }
        dispatch(event, overrides = {}) {
            const e = { type: event, target: this, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...overrides };
            for (const callback of this.listeners[event] || []) callback.call(this, e);
            return e;
        }
        click() { if (!this.disabled) this.dispatch('click'); }
        get firstChild() { return this.children[0] || null; }
        get nextSibling() { return this.parentNode ? this.parentNode.children[this.parentNode.children.indexOf(this) + 1] || null : null; }
        appendChild(child) {
            if (child.parentNode) child.parentNode.removeChild(child);
            this.children.push(child); child.parentNode = this; return child;
        }
        removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
        insertBefore(child, before) {
            if (child.parentNode) child.parentNode.removeChild(child);
            const i = this.children.indexOf(before);
            this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentNode = this;
        }
        set textContent(value) {
            for (const child of this.children) child.parentNode = null;
            this.children = []; this._text = String(value); this._html = '';
        }
        get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
        set innerHTML(value) {
            this.textContent = ''; this._html = value;
            if (/^<input type="checkbox" checked>/.test(value)) {
                const input = new Element('input'); input.type = 'checkbox'; input.checked = true; this.appendChild(input);
            }
        }
        get innerHTML() { return this._html; }
        querySelectorAll(selector) {
            const all = this.children.flatMap(child => [child, ...child.querySelectorAll('*')]);
            if (selector.startsWith('.')) return all.filter(child => child.classList.contains(selector.slice(1)));
            return selector === '*' ? all : all.filter(child => child.tagName === selector.toUpperCase());
        }
        closest(selector) {
            for (let el = this; el; el = el.parentNode) if (selector.startsWith('.') && el.classList.contains(selector.slice(1))) return el;
            return null;
        }
    }
    const make = (id, tag = 'span') => { const el = new Element(tag); el.id = id; elements[id] = el; return el; };
    const root = make('root', 'html'), body = make('body', 'body'), head = make('head', 'head');
    root.appendChild(head); root.appendChild(body);
    for (const [, tag, attrs, id] of view.matchAll(/<([a-z][\w-]*)\b([^>]*\bid="([^"]+)"[^>]*)>/gi)) {
        const el = make(id, tag), display = attrs.match(/\bdisplay:([^;"\s]+)/), cls = attrs.match(/\bclass="([^"]*)"/);
        el.disabled = /\bdisabled\b/.test(attrs);
        if (display) el.style.display = display[1];
        if (cls) el.className = cls[1];
        body.appendChild(el);
    }
    const get = id => { assert.ok(elements[id], 'fixture needs actual element ' + id); return elements[id]; };
    class XHR {
        constructor() { this.headers = {}; requests.push(this); }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader(key, value) { this.headers[key] = value; }
        getResponseHeader(key) { return key.toLowerCase() === 'content-type' ? this.contentType || null : null; }
        send(data) { this.body = data; }
        reply(data, status = 200, contentType = 'application/json') {
            this.settled = true; this.status = status; this.contentType = contentType;
            this.responseText = typeof data === 'string' ? data : JSON.stringify(data); this.onload();
        }
        fail(event = 'error') { this.settled = true; this['on' + event](); }
        abort() { this.fail('abort'); }
    }
    class FormData { constructor() { this.parts = []; } append(name, value, filename) { this.parts.push({ name, value, filename }); } }
    class Blob { constructor(parts) { this.data = parts.join(''); } }
    class Clock extends Date { constructor(...args) { super(...(args.length ? args : [now])); } static now() { return now; } }
    const document = { documentElement: root, body, head, readyState: 'loading',
        getElementById: id => elements[id] || null, createElement: tag => new Element(tag), querySelector: () => null,
        querySelectorAll: selector => selector === '.ps-modal' ? Object.values(elements).filter(el => el.classList.contains('ps-modal')) : [],
        addEventListener(event, callback) { (documentEvents[event] ||= []).push(callback); } };
    const window = { PT: { csrf: 'token', version: '4.10.3', urls: { ...urls } },
        location: { href: 'http://router.test/admin/services/podkop-tweaker/stubby', origin: 'http://router.test' },
        addEventListener(event, callback) { (events[event] ||= []).push(callback); },
        removeEventListener(event, callback) { events[event] = (events[event] || []).filter(fn => fn !== callback); } };
    const context = vm.createContext({ window, document, XMLHttpRequest: XHR, FormData, Blob, URL, Date: Clock,
        Event: class { constructor(type) { this.type = type; } },
        confirm(message) { confirmations.push(message); return confirmed; },
        setTimeout(fn, delay) { const timer = { fn, delay, at: now + delay }; timers.push(timer); return timer; },
        clearTimeout(timer) { if (timer) timer.cancelled = true; }, setInterval() {}, clearInterval() {} });
    vm.runInContext(shared, context, { filename: 'common.js' });
    const PT = window.PT;
    context.PT = PT; PT.checkStale = () => {};
    // Instrument, but never replace, the real adapters, editor or process watcher.
    const postJson = PT.postJson;
    PT.postJson = function(url, params, callback, timeout) {
        return postJson(url, params, function(data, error, xhr) {
            replies.push({ url, data, error, xhr }); freeze(data); freeze(error);
            // Page handlers consume error.data. A second parse/read of the XHR
            // would bypass the once-only object transport and lose native facts.
            const text = xhr && xhr.responseText;
            if (xhr) Object.defineProperty(xhr, 'responseText', { configurable: true, get() { throw new Error('Page reparsed the transport response'); } });
            try { callback(data, error, xhr); }
            finally { if (xhr) Object.defineProperty(xhr, 'responseText', { configurable: true, writable: true, value: text }); }
        }, timeout);
    };
    const statusWatcher = PT.statusWatcher;
    PT.statusWatcher = function(...args) {
        const watcher = statusWatcher(...args), poll = watcher.poll;
        watcher.poll = function(ok, fail, metadata) { polls.push({ metadata }); return poll(ok, fail, metadata); };
        return watcher;
    };
    const editorPage = PT.editorPage;
    PT.editorPage = function(cfg) {
        const ctx = editorPage(cfg), load = ctx.loadConfig;
        delete ctx.setStatus; delete ctx.pushError;
        ctx.loadConfig = function(opts) { readbacks.push(opts); return load(opts); };
        return ctx;
    };
    vm.runInContext(script, context, { filename: 'stubby.htm' });
    const s = { get, requests, timers, replies, polls, readbacks, confirmations, window,
        count(url) { return requests.filter(r => r.url === url).length; },
        posts() { return requests.filter(r => r.method === 'POST'); },
        last(url) { const request = requests.filter(r => r.url === url).at(-1); assert.ok(request, 'missing ' + url); return request; },
        pending(url) { const request = requests.find(r => r.url === url && !r.settled); assert.ok(request, 'missing pending ' + url); return request; },
        confirm(value) { confirmed = value; },
        open(kind) { get(forms[kind].open).click(); },
        start(kind) { this.open(kind); get(forms[kind].apply).click(); return this.last(forms[kind].url); },
        edit(value) { get('ps-config-editor').value = value; get('ps-config-editor').dispatch('input'); },
        dirty() { const e = { preventDefault() { this.prevented = true; } }; for (const fn of events.beforeunload || []) fn(e); return e.prevented === true; },
        key(key, extra = {}) {
            const e = { key, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...extra };
            for (const fn of documentEvents.keydown || []) fn(e); return e;
        },
        pagehide() { for (const fn of events.pagehide || []) fn(); },
        activeTimers(delay) { return timers.filter(t => !t.cancelled && !t.ran && t.delay === delay); },
        tick(ms) {
            const target = now + ms;
            for (;;) {
                const timer = timers.filter(t => !t.cancelled && !t.ran && t.at <= target).sort((a, b) => a.at - b.at)[0];
                if (!timer) break;
                now = timer.at; timer.ran = true; timer.fn();
            }
            now = target;
        },
        read(text = template) { this.pending('/read').reply(text, 200, 'text/plain'); },
        observe(value = running('42:101')) { this.tick(2000); this.pending('/status').reply(value); },
        result() { return get('ps-stubby-action-status').textContent; }
    };
    if (options.read !== false) s.read(original);
    s.pending('/status').reply(running());
    s.pending('/autostart').reply({ enabled: true });
    if (options.initCheck !== false) s.pending('/init/check').reply({ status: 'needs_fix' });
    return s;
}

function assertReadLocked(s) {
    for (const name of ['save', 'diff', 'undo']) assert.equal(s.get('ps-config-' + name).disabled, true, name + ' needs a typed read');
}
function assertDetails(el, expected) {
    const pre = el.querySelectorAll('pre');
    assert.equal(pre.length, 1, 'one expandable complete diagnostic');
    assert.ok(pre[0].textContent.endsWith(expected), 'the complete raw diagnostic is retained without truncation');
    assert.equal(pre[0].children.length, 0, 'diagnostics stay literal text');
    assert.equal(el.querySelectorAll('script').length, 0);
    assert.equal(el.querySelectorAll('img').length, 0);
}
function assertOnePost(s, kind) {
    assert.equal(s.posts().length, 1, 'only the explicit operation mutates');
    assert.equal(s.posts()[0].url, forms[kind].url);
    assert.equal(s.posts()[0].body, 'token=token');
    assert.equal(s.posts()[0].timeout, 120000, 'native service command has a finite operation deadline');
}

// Only the three exact native init-check statuses establish a fact. In
// particular an error object, a missing reply or an HTTP 404 is not absence.
for (const [status, label, role] of [
    ['fixed', 'Running as root', 'success'], ['needs_fix', 'Needs fix', 'error'], ['not_installed', 'Not installed', 'dim']
]) for (const flags of [{}, { success: true, unknown: false }]) {
    const s = setup({ initCheck: false });
    assert.equal(s.get('ps-initfix-status').textContent, 'Checking...');
    const request = s.pending('/init/check');
    assert.equal(request.method, 'GET'); assert.equal(request.timeout, 30000);
    request.reply({ status, ...flags });
    assert.equal(s.get('ps-initfix-status').textContent, label);
    assert.equal(s.get('ps-initfix-status').style.color, s.window.PT.color(role));
    assert.equal(s.posts().length, 0); assert.equal(s.polls.length, 0);
}
const initReadFailures = [
    { name: 'network', message: /Network error/, run: r => r.fail() },
    { name: 'timeout', message: /Request timed out/, details: 'Init script status read did not complete within 30 seconds.', run: r => r.fail('timeout') },
    { name: 'abort', message: /Request aborted/, run: r => r.abort() },
    ...['', ' \t\n', '{broken JSON', '"fixed"', '<html><body>LuCI login</body></html>'].map(body => ({
        name: 'invalid body ' + JSON.stringify(body), details: body, run: r => r.reply(body)
    })),
    ...[null, [], [{ status: 'not_installed' }], false, 0, {}, { status: null }, { status: false }, { status: [] }, { status: {} },
        { status: 'unknown' }, { status: 'not_installed ' }, { status: 'FIXED' },
        { status: 'fixed', success: false }, { status: 'needs_fix', success: 'true' }, { status: 'not_installed', success: null },
        { status: 'fixed', unknown: true }, { status: 'needs_fix', unknown: 'false' }, { status: 'not_installed', unknown: null },
        { status: 'not_installed', error: '' }, { status: 'not_installed', error: null }, { status: 'not_installed', error: false },
        { error: { status: 'not_installed' } }].map(data => ({
        name: 'invalid typed result ' + JSON.stringify(data), details: JSON.stringify(data), run: r => r.reply(data)
    })),
    ...[undefined, 'fixed', 'needs_fix', 'not_installed'].map(status => ({
        name: 'native read failure with ' + status, message: /Cannot read init script/, details: longDetails,
        run: r => r.reply({ ...(status ? { status } : {}), error: 'Cannot read init script', details: longDetails })
    })),
    ...[401, 403, 404, 500].map(status => ({
        name: 'HTTP ' + status + ' cannot establish absence', message: new RegExp('HTTP error: ' + status), httpStatus: status, details: longDetails,
        run: r => r.reply({ status: 'not_installed', details: longDetails }, status)
    })),
    { name: 'HTTP error body', message: /Cannot read init script/, httpStatus: 500, details: longDetails,
        run: r => r.reply({ error: 'Cannot read init script', details: longDetails }, 500) },
    { name: 'HTML HTTP error', httpStatus: 403, details: '<html><script>literal login page</script></html>',
        run: r => r.reply('<html><script>literal login page</script></html>', 403, 'text/html') }
];
for (const afterKnownRead of [false, true]) for (const failure of initReadFailures) {
    const s = setup({ initCheck: false });
    if (afterKnownRead) {
        s.pending('/init/check').reply({ status: 'fixed' });
        assert.equal(s.get('ps-initfix-status').textContent, 'Running as root');
        s.start('init').reply({ success: true, message: 'Already fixed', details: longDetails });
        assert.equal(s.get('ps-initfix-status').textContent, 'Checking...', 'a reread does not keep an old factual label while pending');
    }
    const page = s.result(), modal = s.get(forms.init.status).textContent, request = s.pending('/init/check');
    failure.run(request);
    const label = s.get('ps-initfix-status');
    assert.match(label.textContent, /^Unknown/, failure.name);
    assert.equal(label.style.color, s.window.PT.color('warning'), failure.name);
    if (failure.message) assert.match(label.textContent, failure.message, failure.name);
    if (failure.details) assertDetails(label, failure.details);
    if (failure.httpStatus) assert.ok(label.querySelectorAll('pre')[0].textContent.includes('HTTP ' + failure.httpStatus), 'HTTP status is retained alongside the full native details');
    assert.equal(s.result(), page, 'readonly init facts cannot replace the operation result');
    assert.equal(s.get(forms.init.status).textContent, modal);
    const displayed = label.textContent, count = s.requests.length;
    request.fail(); request.fail('timeout'); request.abort(); request.reply({ status: 'not_installed' });
    assert.equal(label.textContent, displayed, 'late terminal events cannot turn Unknown into absence');
    assert.equal(s.requests.length, count, 'the failed read is not automatically retried');
    assert.equal(s.posts().length, afterKnownRead ? 1 : 0);
    assert.equal(s.polls.length, 0); assert.equal(s.readbacks.length, 0);
    assert.equal(s.get('ps-config-editor').value, original); assert.equal(s.dirty(), false);
}

// Native ACK -> old process -> same PID/new start-time. The actual shared
// watcher, rather than a mocked success callback, must establish the transition.
for (const kind of Object.keys(forms)) {
    const s = setup(); s.start(kind).reply(restartAck);
    assert.equal(s.polls.length, 1);
    const reply = s.replies.find(r => r.url === forms[kind].url);
    assert.equal(s.polls[0].metadata, reply.data, 'the entire untouched ACK reaches the native watcher');
    for (const [key, value] of Object.entries(restartAck)) assert.equal(s.polls[0].metadata[key], value);
    if (kind === 'template') s.read();
    else assert.equal(s.count('/read'), 1, 'init repair does not reload the config editor');
    s.observe(running());
    assert.match(s.result(), /Verifying Stubby restart/);
    assert.doesNotMatch(s.result(), /new Stubby instance|Stubby restarted/);
    assert.equal(s.get(forms[kind].apply).disabled, true);
    s.get(forms[kind].apply).dispatch('click');
    s.observe();
    assert.match(s.result(), /applied to disk.*new Stubby instance is running/);
    assert.equal(s.get(forms[kind].status).textContent, s.result());
    s.pending('/status').reply(running('42:101'));
    if (kind === 'template') {
        s.tick(2000);
        assert.equal(s.get(forms.template.modal).style.display, 'none');
        assert.equal(s.count('/read'), 2, 'closing is presentation only, not another config load');
    } else {
        s.pending('/init/check').reply({ status: 'fixed' });
        assert.equal(s.get('ps-initfix-status').textContent, 'Running as root');
        assert.equal(s.get(forms.init.modal).style.display, 'flex');
    }
    s.get(forms[kind].apply).dispatch('click');
    assertOnePost(s, kind);
}

// A checked known-absent -> running transition is sufficient; missing native
// evidence, an old instance, an unreadable identity and failed queries are not.
for (const kind of Object.keys(forms)) {
    const s = setup();
    s.start(kind).reply({ success: true, applied: true, restarting: true, verification_required: true,
        previous_running: false, previous_identity_known: true });
    if (kind === 'template') s.read();
    s.observe({ running: false });
    assert.match(s.result(), /Verifying/);
    s.observe(running('73:900'));
    assert.match(s.result(), /new Stubby instance/);
    assertOnePost(s, kind);
}
const unconfirmedCases = [
    { name: 'old instance', ack: restartAck, status: running() },
    { name: 'missing restart metadata', ack: { success: true, applied: true, restarting: true }, status: running('73:900') },
    { name: 'unknown previous identity', ack: { ...restartAck, previous_identity_known: false }, status: running('73:900') },
    { name: 'PID without identity', ack: restartAck, status: { running: true, pid: '73', identity_error: 'Cannot read /proc identity' } },
    { name: 'status IO failure', ack: restartAck, status: { error: 'Cannot query process', details: longDetails } },
    { name: 'still stopped', ack: restartAck, status: { running: false } }
];
for (const kind of Object.keys(forms)) for (const scenario of unconfirmedCases) {
    const s = setup(); s.start(kind).reply(scenario.ack);
    if (kind === 'template') s.read();
    for (let i = 0; i < 8; i++) s.observe(scenario.status);
    assert.match(s.result(), /restart is unconfirmed/, kind + ': ' + scenario.name);
    assert.doesNotMatch(s.result(), /new Stubby instance|Stubby restarted/);
    assert.ok(s.requests.filter(r => r.url === '/status').every(r => r.timeout === 4000));
    assertOnePost(s, kind);
}
{
    const s = setup(); s.start('init').reply(restartAck);
    s.tick(30000);
    const message = s.result();
    assert.match(message, /restart is unconfirmed/, 'the overall verification deadline also bounds a hung status request');
    s.pending('/status').reply(running('73:900'));
    assert.equal(s.result(), message, 'late process readiness cannot change the finished result');
    assertOnePost(s, 'init');
}

// The native no-op has no publication/restart evidence and must not invent it.
{
    const s = setup(); s.edit(sentDraft);
    s.start('init').reply({ success: true, message: 'Already fixed' });
    assert.match(s.result(), /^Already fixed\. No restart was requested\./);
    assert.equal(s.polls.length, 0);
    assert.equal(s.readbacks.length, 0);
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assert.equal(s.dirty(), true);
    s.pending('/status').reply(running());
    s.pending('/init/check').reply({ status: 'fixed' });
    assert.doesNotMatch(s.result(), /new Stubby instance|Stubby restarted|applied to disk/);
    s.get('ps-config-undo').click();
    assert.equal(s.get('ps-config-editor').value, original, 'init no-op retains the typed config baseline');
    assertOnePost(s, 'init');
}

for (const kind of Object.keys(forms)) for (const applied of [false, true]) {
    const s = setup(); s.edit(sentDraft);
    s.start(kind).reply({ success: true, ...(applied ? { applied: true } : {}) });
    assert.match(s.result(), /Restart is unconfirmed/, 'a success flag without a restart ACK is not process evidence');
    if (applied) assert.match(s.result(), /applied to disk/);
    else assert.doesNotMatch(s.result(), /applied to disk/);
    assert.equal(s.polls.length, 0);
    if (kind === 'template') s.read();
    else assert.equal(s.readbacks.length, 0);
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assert.equal(s.dirty(), true);
    assertOnePost(s, kind);
}

// success=false without error text is a real failure, not silent success. The
// full error.data diagnostics survive both application and HTTP failures.
for (const kind of Object.keys(forms)) for (const status of [200, 500]) {
    const s = setup(); s.start(kind).reply({ success: false }, status);
    assert.ok(s.result(), 'quiet failure is presented');
    assert.doesNotMatch(s.result(), /applied to disk|new Stubby instance|Stubby restarted/);
    assert.equal(s.get(forms[kind].apply).disabled, false, 'an explicit checked non-applied failure may be retried by the user');
    assert.equal(s.polls.length, 0); assert.equal(s.readbacks.length, 0);
    assertOnePost(s, kind);
}
for (const kind of Object.keys(forms)) for (const status of [200, 500]) {
    const s = setup();
    s.start(kind).reply({ success: false, error: 'Native validation failed', details: longDetails,
        restart: { success: false, details: 'nested outcome retained' } }, status);
    const reply = s.replies.find(r => r.url === forms[kind].url);
    assert.equal(reply.data, null);
    assert.equal(reply.error.data.restart.details, 'nested outcome retained');
    assertDetails(s.get('ps-stubby-action-status'), longDetails);
    assertDetails(s.get(forms[kind].status), longDetails);
    assert.equal(s.polls.length, 0); assert.equal(s.readbacks.length, 0);
    assertOnePost(s, kind);
}

// Applied disk bytes are not a successful service restart. Template needs an
// exact readback for its new baseline; init repair must leave that baseline alone.
for (const kind of Object.keys(forms)) for (const dirtyAtSend of [false, true]) {
    const s = setup(); if (dirtyAtSend) s.edit(sentDraft);
    const request = s.start(kind); s.edit(laterDraft);
    request.reply({ success: false, applied: true, verification_required: true, previous_running: true,
        previous_identity_known: true, previous_instance: '42:100', error: 'Service restart command failed', details: longDetails });
    assert.match(s.result(), /applied to disk.*Restart failed or is unverified/);
    assert.equal(s.polls.length, 0, 'a failed native restart command cannot enter a success poll');
    assertDetails(s.get('ps-stubby-action-status'), longDetails);
    if (kind === 'template') { assert.equal(s.readbacks[0].preserveDraft, true); s.read(); }
    else assert.equal(s.readbacks.length, 0);
    assert.equal(s.get('ps-config-editor').value, laterDraft);
    assert.equal(s.dirty(), true);
    s.pending('/status').reply(running());
    assert.match(s.result(), /Restart failed or is unverified/, 'a running old PID cannot erase the command failure');
    s.get(forms[kind].close).click();
    s.get('ps-config-diff').click();
    assert.match(s.get('ps-diff-body').innerHTML, /later-editor-draft/);
    assert.match(s.get('ps-diff-body').innerHTML, kind === 'template' ? /checked-template-disk/ : /original-disk/);
    s.key('Escape'); s.get('ps-config-undo').click();
    assert.equal(s.get('ps-config-editor').value, kind === 'template' ? template : original);
    assert.equal(s.dirty(), false);
    assertOnePost(s, kind);
}

// Lost/malformed replies and explicit native lock uncertainty never establish
// publication. Even applied=true proves only disk application, not finishing.
for (const kind of Object.keys(forms)) for (const applied of [false, true]) {
    const s = setup(); s.edit(sentDraft);
    s.start(kind).reply({ success: false, unknown: true, ...(applied ? { applied: true } : {}),
        error: 'Cannot release Stubby lock', details: longDetails });
    assert.match(s.result(), /result unknown/);
    if (applied) assert.match(s.result(), /applied to disk/);
    else assert.doesNotMatch(s.result(), /applied to disk/);
    if (kind === 'template' && applied) s.read();
    else assert.equal(s.readbacks.length, 0, 'no publication is inferred from unknown alone');
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assert.equal(s.dirty(), true);
    assert.equal(s.polls.length, 0);
    assertDetails(s.get('ps-stubby-action-status'), longDetails);
    s.get(forms[kind].close).click(); s.open(kind);
    assert.equal(s.get(forms[kind].apply).disabled, true);
    for (const other of Object.keys(forms)) { s.open(other); s.get(forms[other].apply).dispatch('click'); }
    assertOnePost(s, kind);
}
const failures = [
    { name: 'network', unknown: true, run: r => r.fail() },
    { name: 'timeout', unknown: true, run: r => r.fail('timeout') },
    { name: 'abort', unknown: true, run: r => r.abort() },
    { name: 'HTTP session failure', unknown: false, run: r => r.reply('<html>LuCI login</html>', 403, 'text/html') },
    { name: 'HTTP 500 without an outcome', unknown: true, run: r => r.reply({ error: 'Internal IO failure', details: longDetails }, 500) },
    ...['<html>LuCI login</html>', 'not JSON', null, [], false, 1, {}, { success: 'true' },
        { success: true, applied: 'true' }, { success: true, unknown: 'false' }, { success: true, restarting: 'true' },
        { success: true, unknown: true }].map(data => ({ name: JSON.stringify(data), unknown: true, run: r => r.reply(data) }))
];
for (const kind of Object.keys(forms)) for (const failure of failures) {
    const s = setup(); s.edit(sentDraft);
    const request = s.start(kind); failure.run(request);
    assert.ok(s.result(), kind + ': ' + failure.name);
    if (failure.unknown) assert.match(s.result(), /result unknown/, failure.name);
    assert.doesNotMatch(s.result(), /applied to disk|new Stubby instance|Stubby restarted/, failure.name);
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assert.equal(s.dirty(), true);
    assert.equal(s.polls.length, 0); assert.equal(s.readbacks.length, 0);
    assert.equal(s.get(forms[kind].apply).disabled, failure.unknown);
    const result = s.result(), count = s.requests.length;
    request.fail(); request.fail('timeout'); request.abort(); request.reply(restartAck);
    assert.equal(s.result(), result, 'a terminal transport event completes the operation only once');
    assert.equal(s.requests.length, count, 'late events cannot trigger readback or another mutation');
    assertOnePost(s, kind);
}

// Each opening owns its status/button/timer. Completion of an old POST still
// updates the page, config baseline/init facts, and frees its operation gate.
for (const kind of Object.keys(forms)) for (const completion of ['success', 'failed', 'applied-failed', 'unknown']) {
    const s = setup(); s.edit(sentDraft);
    const request = s.start(kind);
    s.get(forms[kind].close).click(); s.open(kind);
    const reopened = s.get(forms[kind].status).textContent;
    assert.equal(s.get(forms[kind].apply).disabled, true);
    s.get(forms[kind].apply).dispatch('click');
    if (completion === 'success') request.reply(restartAck);
    else request.reply({ success: false, error: 'Native operation failed', details: longDetails,
        ...(completion === 'applied-failed' ? { applied: true } : {}), ...(completion === 'unknown' ? { unknown: true } : {}) });
    if (kind === 'template' && (completion === 'success' || completion === 'applied-failed')) s.read();
    if (completion === 'success') s.observe();
    assert.equal(s.get(forms[kind].status).textContent, reopened, 'an old completion cannot repaint a reopened modal');
    assert.equal(s.get(forms[kind].apply).disabled, true, 'stale presentation does not gain a mutation capability');
    assert.ok(s.result(), 'the page-level result still completes');
    if (kind === 'init') assert.equal(s.count('/init/check'), 2, 'the sent init operation still refreshes external init facts');
    s.tick(5000);
    assert.equal(s.get(forms[kind].modal).style.display, 'flex', 'a stale operation cannot schedule a close for the new opening');
    s.get(forms[kind].close).click(); s.open(kind);
    assert.equal(s.get(forms[kind].apply).disabled, completion === 'unknown', 'a fresh explicit opening sees the released operation gate');
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assertOnePost(s, kind);
}

// Exercise Close, backdrop, Esc, repeated Open and pagehide through the real
// modal binding. Even an already queued/cancelled timer must prove ownership.
for (const close of ['button', 'backdrop', 'escape', 'open', 'pagehide']) {
    const s = setup(); s.start('template').reply(restartAck); s.read(); s.observe();
    const timer = s.activeTimers(2000)[0]; assert.ok(timer, 'a completed current Template opening owns one delayed close');
    if (close === 'button') s.get(forms.template.close).click();
    if (close === 'backdrop') s.get(forms.template.modal).dispatch('click');
    if (close === 'escape') s.key('Escape');
    if (close === 'pagehide') s.pagehide();
    s.open('template');
    const message = s.get(forms.template.status).textContent, count = s.requests.length;
    assert.equal(timer.cancelled, true, close + ' clears the owned delayed-close timer');
    timer.fn(); s.tick(3000);
    assert.equal(s.get(forms.template.modal).style.display, 'flex');
    assert.equal(s.get(forms.template.status).textContent, message);
    assert.equal(s.requests.length, count, 'closing never reloads or replays the mutation');
    assertOnePost(s, 'template');
}
{
    const s = setup(); s.start('template').reply(restartAck); s.read(); s.observe();
    const firstTimer = s.activeTimers(2000)[0];
    s.get(forms.template.close).click();
    s.start('template').reply({ ...restartAck, previous_instance: '42:101' }); s.read();
    // Complete the page refresh left by the first operation before the second
    // poll GET. It is not itself restart evidence for the second operation.
    s.pending('/status').reply(running('42:101'));
    s.observe(running('42:102'));
    const secondTimer = s.activeTimers(2000)[0]; assert.ok(secondTimer); assert.notEqual(firstTimer, secondTimer);
    firstTimer.fn();
    assert.equal(s.get(forms.template.modal).style.display, 'flex');
    assert.equal(secondTimer.cancelled, undefined, 'an obsolete timer cannot steal the current timer handle');
    s.tick(2000);
    assert.equal(s.get(forms.template.modal).style.display, 'none');
    assert.equal(s.posts().length, 2, 'exactly two explicit Template actions were requested');
    assert.equal(s.readbacks.length, 2);
}
{
    const s = setup(); s.edit(sentDraft); s.start('template').reply(restartAck);
    s.observe(); // The operation can finish while its exact config read is still pending.
    s.get(forms.template.close).click(); s.open('template');
    const reopened = s.get(forms.template.status).textContent;
    s.pending('/read').reply({ error: 'Cannot read applied config', details: 'complete config IO failure' }, 500);
    assert.equal(s.get(forms.template.status).textContent, reopened, 'an old readback callback cannot repaint a later opening either');
    assert.match(s.result(), /Config read failed/);
    assertReadLocked(s);
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assert.equal(s.dirty(), true);
    assertOnePost(s, 'template');
}

// Template reads update the baseline from exact typed disk bytes, never from
// the editor snapshot. Drafts made before or after POST remain dirty and Undo
// returns to that readback even when restart verification finishes later.
for (const dirtyAtSend of [false, true]) for (const editAfterSend of [false, true]) {
    const s = setup(); if (dirtyAtSend) s.edit(sentDraft);
    const request = s.start('template'); if (editAfterSend) s.edit(laterDraft);
    const retained = editAfterSend ? laterDraft : sentDraft, preserve = dirtyAtSend || editAfterSend;
    request.reply(restartAck);
    assert.equal(s.readbacks[0].preserveDraft, preserve);
    assertReadLocked(s);
    s.read();
    assert.equal(s.get('ps-config-editor').value, preserve ? retained : template);
    assert.equal(s.dirty(), preserve);
    s.observe();
    if (preserve) {
        s.get(forms.template.close).click();
        s.get('ps-config-diff').click();
        assert.match(s.get('ps-diff-body').innerHTML, /checked-template-disk/);
        assert.match(s.get('ps-diff-body').innerHTML, editAfterSend ? /later-editor-draft/ : /sent-editor-draft/);
        assert.doesNotMatch(s.get('ps-diff-body').innerHTML, /original-disk/);
        s.key('Escape');
    }
    s.get('ps-config-undo').click();
    assert.equal(s.get('ps-config-editor').value, template);
    assert.equal(s.dirty(), false);
    assertOnePost(s, 'template');
}
{
    const s = setup(); s.start('template').reply(restartAck); s.read();
    s.edit(laterDraft); s.observe();
    assert.equal(s.get('ps-config-editor').value, laterDraft, 'edits during restart survive completion too');
    assert.equal(s.dirty(), true);
    s.tick(2000);
    assert.equal(s.get('ps-config-editor').value, laterDraft, 'the delayed close has no editor ownership');
    s.get('ps-config-undo').click(); assert.equal(s.get('ps-config-editor').value, template);
}
for (const failRead of [r => r.reply('', 200, 'text/plain'), r => r.reply('<html>LuCI login</html>', 200, 'text/html'),
    r => r.reply({ error: 'Config is empty', details: 'zero bytes on disk' }, 409)]) {
    const s = setup(); s.edit(sentDraft);
    s.start('template').reply({ success: false, applied: true, error: 'Service restart command failed', details: longDetails });
    failRead(s.pending('/read'));
    assertReadLocked(s);
    assert.equal(s.get('ps-config-editor').value, sentDraft);
    assert.equal(s.dirty(), true);
    s.edit(original);
    assert.equal(s.dirty(), false, 'failed read retains the previous typed baseline');
    s.edit(laterDraft); s.get('ps-config-save').dispatch('click'); s.key('s', { ctrlKey: true });
    assertReadLocked(s);
    const page = s.get('ps-stubby-action-status');
    assert.match(page.querySelectorAll('summary')[0].textContent, /applied to disk.*Restart failed/);
    assert.match(page.querySelectorAll('pre')[0].textContent, /Config read failed/, 'the full outcome remains available beyond the collapsed summary');
    assertDetails(page, longDetails);
    assertOnePost(s, 'template');
}

// Explicit Template recovery still works after a failed initial read, including
// a nonempty/whitespace draft. A legacy success ACK does not invent applied or
// restart evidence; only the successful read establishes a usable new baseline.
for (const draft of ['', sentDraft, ' \t\n']) {
    const s = setup({ read: false }); s.pending('/read').reply('', 200, 'text/plain');
    if (draft) s.edit(draft);
    assertReadLocked(s);
    s.start('template').reply({ success: true });
    assert.match(s.result(), /request completed.*Restart is unconfirmed/);
    assert.doesNotMatch(s.result(), /applied to disk|new Stubby instance|Stubby restarted/);
    assert.equal(s.polls.length, 0);
    s.read(); s.tick(2000);
    assert.equal(s.get('ps-config-editor').value, draft || template);
    assert.equal(s.dirty(), Boolean(draft));
    s.get('ps-config-undo').click(); assert.equal(s.get('ps-config-editor').value, template);
    assertOnePost(s, 'template');
}

// Init callbacks cannot take ownership of an editor Save's sent snapshot or
// newer draft. The original shared poll continues to prove that Save's restart.
{
    const s = setup(); s.edit(sentDraft); s.get('ps-config-save').click();
    s.last('/save').reply(restartAck); s.edit(laterDraft);
    s.start('init').reply({ success: true, message: 'Already fixed' });
    s.observe();
    assert.equal(s.get('ps-config-editor').value, laterDraft);
    assert.equal(s.dirty(), true);
    s.get('ps-config-undo').click();
    assert.equal(s.get('ps-config-editor').value, sentDraft, 'the shared editor still owns its sent Save baseline');
    assert.equal(s.posts().length, 2, 'one explicit Save and one explicit Init Fix, no replay');
}

// Readonly init/process refreshes may update their own facts, but cannot erase
// native operation diagnostics/metadata, promote an uncertain result, or repaint
// a reopened Init Fix modal. Older initial checks remain stale in every branch.
for (const outcome of ['already-fixed', 'success', 'applied-failed', 'unknown']) for (const checkFails of [false, true]) {
    const s = setup({ initCheck: false }), stale = s.pending('/init/check');
    s.edit(sentDraft);
    const facts = { verification_required: true, previous_running: true, previous_identity_known: true, previous_instance: '42:100' };
    const nested = { ...facts, success: outcome === 'success', details: 'complete nested restart evidence' };
    const response = outcome === 'already-fixed' ? { success: true, message: 'Already fixed', details: longDetails } :
        outcome === 'success' ? { ...restartAck, details: longDetails, restart: nested } :
        { ...facts, success: false, applied: true, ...(outcome === 'unknown' ? { restarting: true, unknown: true } : {}),
            error: outcome === 'unknown' ? 'Cannot release Stubby lock' : 'Service restart command failed', details: longDetails, restart: nested };
    s.start('init').reply(response);
    if (outcome === 'success') s.observe();
    const current = s.last('/init/check'); assert.notEqual(current, stale);
    const result = s.result(), pollCount = s.polls.length;
    assertDetails(s.get('ps-stubby-action-status'), longDetails);
    assertDetails(s.get(forms.init.status), longDetails);
    if (outcome === 'already-fixed') assert.match(result, /Already fixed\. No restart was requested/);
    if (outcome === 'applied-failed') assert.match(result, /applied to disk.*Restart failed or is unverified/);
    if (outcome === 'unknown') assert.match(result, /applied to disk.*Finishing result unknown/);
    s.get(forms.init.close).click(); s.open('init');
    const reopened = s.get(forms.init.status).textContent, disabled = s.get(forms.init.apply).disabled;
    s.pending('/status').reply(running('42:101'));
    current.reply(checkFails ? { status: 'not_installed', error: 'Cannot reread init script', details: longDetails } : { status: 'fixed' });
    const label = s.get('ps-initfix-status').textContent;
    if (checkFails) { assert.match(label, /^Unknown/); assertDetails(s.get('ps-initfix-status'), longDetails); }
    else assert.equal(label, 'Running as root');
    stale.reply({ status: 'not_installed' });
    assert.equal(s.get('ps-initfix-status').textContent, label, 'a pre-command read cannot replace a newer valid or unknown status');
    assert.equal(s.result(), result, 'readonly facts cannot replace the native operation outcome');
    assert.equal(s.get(forms.init.status).textContent, reopened, 'readonly refresh cannot repaint a reopened modal');
    assert.equal(s.get(forms.init.apply).disabled, disabled, 'readonly refresh cannot grant a new mutation capability');
    assert.equal(s.get(forms.init.modal).style.display, 'flex');
    assert.equal(s.polls.length, pollCount); assert.equal(pollCount, outcome === 'success' ? 1 : 0);
    const reply = s.replies.find(r => r.url === '/init/fix'), retained = reply.data || reply.error.data;
    assert.equal(JSON.stringify(retained), JSON.stringify(response), 'all prior-instance/nested/error facts remain complete and unmodified');
    if (outcome === 'success') assert.equal(s.polls[0].metadata, retained);
    assert.equal(s.get('ps-config-editor').value, sentDraft); assert.equal(s.dirty(), true);
    assert.equal(s.readbacks.length, 0);
    assertOnePost(s, 'init');
}
{
    const s = setup({ initCheck: false }), stale = s.pending('/init/check');
    s.start('init').reply({ success: true, message: 'Already fixed' });
    const current = s.requests.filter(r => r.url === '/init/check').at(-1);
    current.reply({ status: 'fixed' }); stale.reply({ status: 'needs_fix' });
    assert.equal(s.get('ps-initfix-status').textContent, 'Running as root', 'an initial pre-command check cannot replace current init facts');
}
{
    const s = setup(); s.confirm(false); s.open('template'); s.get(forms.template.apply).click();
    assert.equal(s.posts().length, 0, 'cancelled Template confirmation has no operation or delayed close');
    assert.equal(s.activeTimers(2000).length, 0);
    assert.equal(s.get(forms.template.apply).disabled, false);
    for (const kind of Object.keys(forms)) {
        s.get(forms[kind].close).click(); s.get(forms[kind].apply).dispatch('click');
    }
    assert.equal(s.posts().length, 0, 'hidden forms cannot dispatch an operation');
}

console.log('frontend_stubby_spec: native outcomes, transport details, modal ownership and editor baselines passed');
