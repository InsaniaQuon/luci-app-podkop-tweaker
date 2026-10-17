// frontend_transport_spec.js | v1.0.0 | 17.10.2026 | Shared object transport and typed Autostart regressions
// Run with node tests/frontend_transport_spec.js. Uses the real common.js, no dependencies.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Blob, File } = require('node:buffer');
const shared = fs.readFileSync(path.resolve(__dirname, '../www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');
const fullDetails = '<script>literal complete diagnostic, not executable</script>\n'.repeat(3000) + 'END of full diagnostics';

class Element {
    constructor(tag = 'span') {
        this.tagName = tag.toUpperCase(); this.attrs = {}; this.listeners = {}; this.children = [];
        this.value = ''; this.disabled = false; this._text = ''; this.className = '';
        this.style = { setProperty(key, value) { this[key] = value; } };
        this.classList = {
            add: name => { if (!this.classList.contains(name)) this.className += ' ' + name; },
            remove: name => { this.className = this.className.split(/\s+/).filter(value => value !== name).join(' '); },
            contains: name => this.className.split(/\s+/).includes(name)
        };
    }
    getAttribute(key) { return this.attrs[key] ?? null; }
    setAttribute(key, value) { this.attrs[key] = String(value); }
    addEventListener(type, callback) { (this.listeners[type] ||= []).push(callback); }
    dispatch(type) { for (const callback of this.listeners[type] || []) callback.call(this, { type, target: this, preventDefault() {} }); }
    click() { if (!this.disabled) this.dispatch('click'); }
    get firstChild() { return this.children[0] || null; }
    get nextSibling() { return this.parentNode && this.parentNode.children[this.parentNode.children.indexOf(this) + 1] || null; }
    appendChild(child) {
        if (child.parentNode) child.parentNode.removeChild(child);
        this.children.push(child); child.parentNode = this; return child;
    }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; return child; }
    insertBefore(child, before) {
        if (child.parentNode) child.parentNode.removeChild(child);
        const index = this.children.indexOf(before);
        this.children.splice(index < 0 ? this.children.length : index, 0, child); child.parentNode = this;
    }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    set innerHTML(value) {
        this._text = String(value); this.children = [];
        if (value.startsWith('<input type="checkbox" checked>')) {
            const input = new Element('input'); input.type = 'checkbox'; input.checked = true; this.appendChild(input);
        }
    }
    get innerHTML() { return this._text; }
}

function freezeTree(value) {
    if (value && typeof value === 'object') {
        Object.values(value).forEach(freezeTree);
        Object.freeze(value);
    }
    return value;
}

function setup(options = {}) {
    const elements = {}, requests = [], timers = [], parsed = [], documentEvents = {}, windowEvents = {};
    let parseCount = 0, now = 0;
    const get = id => elements[id] ||= new Element();
    class XHR {
        constructor() { this.headers = {}; this.status = 0; this.responseText = ''; this.sendCount = 0; requests.push(this); }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader(key, value) { this.headers[key] = value; }
        getResponseHeader(key) { return key.toLowerCase() === 'content-type' ? this.contentType || null : null; }
        send(body) { this.body = body; this.sendCount++; }
        respond(text, status = 200, contentType = 'application/json') {
            this.responseText = text; this.status = status; this.contentType = contentType; this.onload();
        }
        reply(data, status = 200) { this.respond(JSON.stringify(data), status); }
        abort() { this.onabort(); }
    }
    class FormData {
        constructor() { this.parts = []; }
        append(name, value, filename) { this.parts.push({ name, value, filename }); }
        get(name) { return this.parts.find(part => part.name === name)?.value ?? null; }
        getAll(name) { return this.parts.filter(part => part.name === name).map(part => part.value); }
    }
    const document = {
        readyState: 'loading', documentElement: get('root'), body: get('body'), head: get('head'),
        getElementById: id => id === 'ps-theme-context' ? null : get(id),
        querySelector: () => null,
        querySelectorAll: selector => selector === '.ps-modal' ? Object.values(elements).filter(el => el.__ptModalHide) : [],
        createElement: tag => new Element(tag),
        addEventListener(type, callback) { (documentEvents[type] ||= []).push(callback); }
    };
    const window = {
        PT: { csrf: options.csrf ?? 'test-token', urls: {} },
        addEventListener(type, callback) { (windowEvents[type] ||= []).push(callback); },
        removeEventListener(type, callback) { windowEvents[type] = (windowEvents[type] || []).filter(fn => fn !== callback); }
    };
    const context = vm.createContext({ window, document, XMLHttpRequest: XHR, FormData, Blob, URL,
        JSON: {
            parse(text) {
                parseCount++;
                const value = JSON.parse(text); parsed.push(value);
                return options.freezeParsed ? freezeTree(value) : value;
            },
            stringify: JSON.stringify
        },
        setTimeout(fn, delay) { const timer = { fn, at: now + delay }; timers.push(timer); return timer; },
        clearTimeout(timer) { if (timer) timer.cancelled = true; },
        confirm: () => true
    });
    vm.runInContext(shared, context, { filename: 'common.js' });
    return { PT: window.PT, get, requests, parsed, FormData,
        parseCount: () => parseCount,
        last: url => requests.filter(request => request.url === url).at(-1),
        tick(ms) {
            now += ms;
            for (const timer of [...timers]) if (!timer.cancelled && !timer.ran && timer.at <= now) { timer.ran = true; timer.fn(); }
        }
    };
}

function post(s, params = '', timeout) {
    const calls = [];
    s.PT.postJson('/operation', params, (data, error, xhr) => calls.push({ data, error, xhr }), timeout);
    return { request: s.last('/operation'), calls };
}

function transportCases() {
    // Object replies may be aggregates without success=true. Preserve the parsed
    // object itself, including unknown fields, rather than rebuilding a subset.
    for (const payload of [{}, { success: true, enabled: false },
        { updated: 1, unchanged: 2, skipped: 3, results: [{ item: 'podkop', restarting: true }] },
        { partial: true, items: { stubby: { applied: true, restart: { requested: false } } } }]) {
        const s = setup({ freezeParsed: true }), { request, calls } = post(s, 'action=save');
        assert.equal(request.method, 'POST');
        assert.equal(request.timeout, 120000);
        assert.equal(s.parseCount(), 0);
        request.reply(payload);
        assert.equal(calls.length, 1);
        assert.equal(calls[0].data, s.parsed[0]);
        assert.deepEqual(calls[0].data, payload);
        assert.equal(calls[0].error, null);
        assert.equal(calls[0].xhr, request);
        assert.equal(s.parseCount(), 1);
    }

    const payload = {
        success: false, error: 'Finishing failed', details: fullDetails,
        applied: true, unknown: true, phase: 'rpcd', resume_available: true, partial: true,
        verification_required: true, previous_running: true, previous_identity_known: true, previous_instance: '42:100',
        restart_required: true, restart_id: 'a'.repeat(32),
        results: [{ name: 'stubby', success: false, applied: true, error: 'Restart failed', details: fullDetails,
            restart: { verification_required: true, previous_running: false, previous_identity_known: true } }],
        items: { tweaker: { committed: true, unknown: true, extra: ['keep', null, false] } },
        data: { not_the_entire_response: true }, future_metadata: { retained: 'verbatim' }
    };
    for (const status of [200, 400, 401, 403, 409, 413, 500, 503]) {
        const s = setup({ freezeParsed: true }), { request, calls } = post(s);
        request.reply(payload, status);
        const result = calls[0];
        assert.equal(result.data, null, 'an applied fact does not turn an error into success');
        assert.equal(result.xhr, request);
        assert.equal(result.error.kind, status === 200 ? 'application' : 'http');
        assert.equal(result.error.message, payload.error);
        assert.equal(result.error.details, fullDetails, 'no diagnostic truncation');
        assert.equal(result.error.data, s.parsed[0], 'error.data is the once-parsed original response');
        assert.deepEqual(result.error.data, payload);
        assert.equal(result.error.data.data.not_the_entire_response, true);
        assert.equal(Object.isFrozen(result.error.data.results[0].restart), true);
        assert.equal(result.error.applied, true, 'legacy selected field is retained');
        assert.equal(result.error.unknown, true);
        if (status === 200) {
            assert.equal(result.error.phase, payload.phase);
            assert.equal(result.error.resume_available, true);
            assert.equal(result.error.partial, true);
        }
        assert.equal(s.parseCount(), 1);
    }
    for (const payload of [{ success: false }, { error: 'Rejected', applied: false, unknown: false, phase: 'checked', resume_available: false, partial: false },
        { success: false, applied: 'true', unknown: 'true', resume_available: 'true', partial: 'true' }]) {
        const s = setup(), { request, calls } = post(s);
        request.reply(payload);
        assert.equal(calls[0].data, null);
        assert.equal(calls[0].error.message, payload.error || 'Operation failed');
        assert.equal(calls[0].error.applied, false);
        assert.equal(calls[0].error.unknown, undefined);
        assert.equal(calls[0].error.resume_available, false);
        assert.equal(calls[0].error.partial, false);
        assert.deepEqual(calls[0].error.data, payload, 'legacy coercions do not alter error.data');
    }
    {
        const s = setup(), { request, calls } = post(s);
        const payload = { success: true, arbitrary: 'HTTP failure still carries the complete object' };
        request.reply(payload, 500);
        assert.equal(calls[0].error.kind, 'http');
        assert.equal(calls[0].error.message, 'HTTP error: 500');
        assert.equal(calls[0].error.details, request.responseText);
        assert.deepEqual(calls[0].error.data, payload);
        assert.equal(calls[0].data, null);
    }

    // HTTP errors keep their status classification, but only a non-array object
    // can supply error.data. Scalars, arrays, bad JSON and HTML cannot do so.
    const invalidBodies = ['', ' \t\r\n', '{broken JSON', 'null', '[]', '[{"applied":true,"unknown":true}]',
        '0', '1', 'true', 'false', '"scalar"', '"<html>JSON scalar, not an object</html>"',
        '<!DOCTYPE HTML><html><form>LuCI login</form></html>', '<div>LuCI session expired</div>',
        '<?xml version="1.0"?><html>LuCI error</html>'];
    for (const body of invalidBodies) for (const status of [200, 403, 500]) {
        const s = setup(), { request, calls } = post(s);
        request.respond(body, status);
        const result = calls[0];
        assert.equal(result.data, null, `HTTP ${status}: ${body}`);
        assert.equal(result.error.kind, status === 200 ? 'parse' : 'http');
        assert.equal(result.error.message, status === 200 ? 'Invalid response' : 'HTTP error: ' + status);
        assert.equal(result.error.details, body);
        assert.equal(Object.hasOwn(result.error, 'data'), false, 'never fabricate an object from invalid content');
        assert.equal(Object.hasOwn(result.error, 'applied'), false);
        assert.equal(Object.hasOwn(result.error, 'unknown'), false);
        assert.equal(result.xhr, request);
        assert.equal(s.parseCount(), 1);
    }

    // First terminal event wins, even if a completed XHR receives late load,
    // timeout, network and abort events. No request is replayed or parsed twice.
    for (const first of ['success', 'application', 'http', 'error', 'timeout', 'abort']) {
        const s = setup(), { request, calls } = post(s, 'action=apply', 54321);
        assert.equal(request.timeout, 54321);
        request.responseText = JSON.stringify(payload); request.status = 500;
        if (first === 'success') request.reply({ success: true, marker: 'original result' });
        else if (first === 'application') request.reply(payload);
        else if (first === 'http') request.reply(payload, 500);
        else request['on' + first]();
        assert.equal(calls.length, 1);
        const result = calls[0], parses = s.parseCount();
        if (['error', 'timeout', 'abort'].includes(first)) {
            assert.equal(result.error.kind, 'transport');
            assert.equal(result.error.message, { error: 'Network error', timeout: 'Request timed out', abort: 'Request aborted' }[first]);
            assert.equal(result.data, null); assert.equal(result.xhr, null);
            assert.equal(Object.hasOwn(result.error, 'data'), false);
            assert.equal(parses, 0, 'a failed transport has no received object body');
        }
        request.reply({ success: true, enabled: false }); request.onerror(); request.ontimeout(); request.abort();
        s.tick(600000);
        assert.equal(calls.length, 1);
        assert.equal(calls[0], result);
        assert.equal(s.parseCount(), parses);
        assert.equal(s.requests.length, 1);
        assert.equal(request.sendCount, 1);
        if (first === 'success') {
            assert.equal(result.error, null);
            assert.equal(result.data.marker, 'original result', 'late events cannot replace a completed success');
        }
    }
}

async function multipartCases() {
    const csrf = 'csrf &+/%=\u0442\u0435\u0441\u0442';
    {
        const s = setup({ csrf }), { request } = post(s, 'action=enable');
        assert.equal(request.body, 'token=' + encodeURIComponent(csrf) + '&action=enable');
        assert.equal(new URLSearchParams(request.body).get('token'), csrf);
        assert.equal(request.headers['Content-Type'], 'application/x-www-form-urlencoded');
        s.PT.csrf = undefined;
        assert.equal(post(s).request.body, 'token=', 'missing bootstrap token is not invented');
    }
    {
        const s = setup({ csrf }), bytes = Buffer.from([0x1f, 0x8b, 0, 0xff, 0x0d, 0x0a, 0x80]);
        const file = new File([bytes], 'luci-app-podkop-tweaker-v4.10.3.tar.gz', { type: 'application/gzip' });
        const form = new s.FormData(); form.append('archive', file, file.name);
        const { request, calls } = post(s, form);
        assert.equal(request.body, form, 'send the original FormData');
        assert.equal(form.parts[0].value, file, 'the original File is not converted to base64 or text');
        assert.equal(form.parts[0].filename, file.name);
        assert.equal(form.parts[0].value.size, bytes.length);
        assert.deepEqual(Buffer.from(await form.parts[0].value.arrayBuffer()), bytes);
        assert.deepEqual(form.getAll('token'), [csrf]);
        assert.deepEqual(Object.keys(request.headers), [], 'the browser owns the multipart Content-Type and boundary');
        request.reply({ error: 'Archive rejected', details: fullDetails }, 400);
        assert.equal(calls[0].error.data.details, fullDetails);
        request.onerror(); request.ontimeout(); request.abort(); s.tick(600000);
        assert.equal(calls.length, 1); assert.equal(s.requests.length, 1); assert.equal(request.sendCount, 1);
        assert.equal(form.parts.length, 2, 'late events neither append more tokens nor resend the file');
    }
    {
        const s = setup({ csrf }), text = "config section 'main'\n\toption note '\u0442\u0435\u0441\u0442 <literal> & data'\n";
        const form = s.PT.contentForm(text, { items: 'podkop,stubby' }, 'router.conf');
        const { request } = post(s, form);
        assert.equal(form.parts[0].name, 'content_file');
        assert.equal(form.parts[0].filename, 'router.conf');
        assert.ok(form.parts[0].value instanceof Blob);
        assert.equal(await form.parts[0].value.text(), text);
        assert.equal(form.parts[0].value.size, Buffer.byteLength(text));
        assert.equal(form.get('items'), 'podkop,stubby');
        assert.deepEqual(form.getAll('token'), [csrf]);
        assert.equal(request.headers['Content-Type'], undefined);
    }
}

const badAutostartObjects = [null, [], {}, false, 0, 'false', { arbitrary: 'not an autostart response' },
    ...[null, 0, 1, 'false', 'true', [], {}].map(enabled => ({ enabled })),
    { enabled: false, error: 'Cannot inspect boot links', details: fullDetails },
    { enabled: false, error: '' }, { enabled: false, success: false }, { enabled: false, success: 'true' },
    { enabled: false, unknown: true }];
const badAutostartReads = [
    { name: 'network', message: 'Network error', run: request => request.onerror() },
    { name: 'timeout', message: 'Request timed out', run: request => request.ontimeout() },
    { name: 'abort', message: 'Request aborted', run: request => request.abort() },
    { name: 'HTML session', message: 'Invalid response', run: request => request.respond('<html>LuCI login</html>') },
    { name: 'HTTP 403', message: 'HTTP error: 403', run: request => request.reply({ enabled: false }, 403) },
    ...badAutostartObjects.map(data => ({ name: JSON.stringify(data).slice(0, 100),
        message: data && data.error || 'Invalid', details: data && data.details,
        run: request => request.reply(data) }))
];

function autostartSetup() {
    const s = setup();
    s.get('diff-toolbar').appendChild(s.get('ps-diff-stats'));
    s.get('ps-error-modal').style.display = s.get('ps-diff-modal').style.display = 'none';
    s.api = s.PT.editorPage({
        urls: { read: '/config', save: '/save', rollback: '/rollback', status: '/status',
            autostart: '/autostart', autostartToggle: '/autostart/toggle' },
        texts: { saving: 'Saving', restarting: 'Restarting', saved: 'Saved', unchanged: 'Unchanged' }
    });
    s.last('/status').reply({ running: false });
    s.last('/config').respond("config stubby 'global'\n\toption log_level '3'\n", 200, 'text/plain');
    s.button = s.get('ps-autostart-btn'); s.initialRead = s.last('/autostart');
    s.posts = () => s.requests.filter(request => request.method === 'POST');
    s.reads = () => s.requests.filter(request => request.url === '/autostart');
    return s;
}

function autostartErrors(s) {
    s.get('ps-error-btn').click();
    assert.equal(s.get('ps-error-modal').style.display, 'flex');
    assert.equal(s.get('ps-error-details').children.length, 0, 'diagnostics remain literal text in the existing error modal');
    return s.get('ps-error-details').textContent;
}

function startAutostart() {
    const s = autostartSetup(); s.initialRead.reply({ enabled: false }); s.button.click();
    s.mutation = s.last('/autostart/toggle');
    assert.equal(s.mutation.body, 'token=test-token&action=enable');
    return s;
}

function autostartCases() {
    {
        const s = setup();
        for (const enabled of [true, false]) {
            const value = freezeTree({ enabled, future_metadata: { retained: true } });
            assert.equal(s.PT.typedAutostart(value), value, 'shared typing preserves the original boolean facts');
            assert.equal(s.PT.typedAutostart({ enabled, success: true }).enabled, enabled);
        }
        for (const value of badAutostartObjects) assert.equal(s.PT.typedAutostart(value), null);
    }
    for (const enabled of [true, false]) {
        const s = autostartSetup();
        assert.deepEqual(Object.keys(s.api).sort(), ['loadConfig', 'refreshStatus']);
        assert.equal(s.get('ps-config-status').textContent, 'Loaded', 'internal editor status helpers remain active');
        assert.equal(s.button.disabled, true, 'a pending read cannot supply an action');
        assert.equal(s.button.textContent, 'Autostart: Unknown');
        s.button.dispatch('click'); assert.equal(s.posts().length, 0);
        assert.equal(s.initialRead.timeout, 30000);
        s.initialRead.reply({ enabled });
        assert.equal(s.button.textContent, enabled ? 'Autostart: ON' : 'Autostart: OFF');
        assert.equal(s.button.disabled, false);
        s.button.textContent = enabled ? 'Autostart: OFF' : 'Autostart: ON';
        s.button.click();
        const mutation = s.last('/autostart/toggle');
        assert.equal(mutation.body, 'token=test-token&action=' + (enabled ? 'disable' : 'enable'), 'the action comes from typed state, never the caption');
        assert.equal(mutation.timeout, 30000);
        s.button.dispatch('click'); s.button.dispatch('click');
        assert.equal(s.posts().length, 1);
        mutation.reply({ success: true, enabled: !enabled });
        assert.equal(s.reads().length, 2, 'a checked POST is followed by a separate current observation');
        assert.equal(s.button.disabled, true, 'retain the operation gate through readback');
        assert.equal(s.button.textContent, 'Autostart: Unknown', 'POST alone does not establish the displayed readback');
        s.button.dispatch('click'); assert.equal(s.posts().length, 1);
        s.last('/autostart').reply({ enabled: !enabled });
        assert.equal(s.button.textContent, enabled ? 'Autostart: OFF' : 'Autostart: ON');
        assert.equal(s.button.disabled, false);
        assert.equal(s.requests.filter(request => request.url === '/config').length, 1);
        assert.equal(s.requests.filter(request => request.url === '/status').length, 1, 'Autostart does not start service-generation polling');
    }

    for (const failure of badAutostartReads) {
        const s = autostartSetup(); failure.run(s.initialRead);
        assert.equal(s.button.textContent, 'Autostart: Unknown', failure.name);
        assert.equal(s.button.disabled, true, failure.name);
        assert.match(s.button.title, /Reload the page to retry the read/);
        const error = autostartErrors(s);
        assert.ok(error.includes(failure.message), failure.name);
        if (failure.details) assert.ok(error.endsWith(failure.details), 'complete failed-read diagnostics');
        assert.match(s.get('ps-config-status').textContent, /Autostart read failed/);
        s.button.textContent = 'Autostart: OFF'; s.button.dispatch('click');
        assert.equal(s.posts().length, 0, 'even forced events after a failed read cannot mutate');
        s.initialRead.reply({ enabled: false }); s.initialRead.onerror(); s.initialRead.ontimeout(); s.initialRead.abort();
        assert.equal(s.button.disabled, true, 'late success cannot unlock a completed failed read');
        assert.equal(s.reads().length, 1, 'failed reads do not initiate automatic retries');
    }

    const writeFailures = [
        { name: 'checked refusal', message: 'Autostart command failed', details: fullDetails,
            run: request => request.reply({ success: false, enabled: false, error: 'Autostart command failed', details: fullDetails }) },
        { name: 'HTTP partial', message: 'Cannot finish update', details: fullDetails,
            run: request => request.reply({ success: false, applied: true, unknown: true, enabled: false, error: 'Cannot finish update', details: fullDetails }, 500) },
        { name: 'CSRF', message: 'CSRF token mismatch', run: request => request.reply({ error: 'CSRF token mismatch' }, 403) },
        { name: 'network', message: 'Network error', run: request => request.onerror() },
        { name: 'timeout', message: 'Request timed out', run: request => request.ontimeout() },
        { name: 'abort', message: 'Request aborted', run: request => request.abort() },
        { name: 'HTML', message: 'Invalid response', run: request => request.respond('<html>LuCI login</html>') },
        ...[null, [], 0, true, 'scalar'].map(data => ({ name: 'invalid body ' + JSON.stringify(data), message: 'Invalid response', run: request => request.reply(data) })),
        ...[{}, { enabled: true }, { success: true }, { success: true, enabled: 'true' },
            { success: true, enabled: true, unknown: true }, { success: true, enabled: true, error: '' },
            { success: true, enabled: false }].map(data => ({ name: 'invalid ACK ' + JSON.stringify(data),
            message: 'Invalid autostart update response', run: request => request.reply(data) }))
    ];
    for (const failure of writeFailures) {
        const s = startAutostart(); failure.run(s.mutation);
        const readback = s.last('/autostart');
        assert.notEqual(readback, s.initialRead, failure.name);
        assert.equal(readback.method, 'GET');
        assert.equal(readback.timeout, 30000);
        assert.equal(s.button.disabled, true);
        assert.equal(s.button.textContent, 'Autostart: Unknown', 'do not display enabled from an error payload');
        s.button.dispatch('click'); assert.equal(s.posts().length, 1);
        readback.reply({ enabled: true });
        assert.equal(s.button.textContent, 'Autostart: ON', 'a separate successful GET may establish current state');
        assert.equal(s.button.disabled, false);
        const error = autostartErrors(s);
        assert.ok(error.includes(failure.message), failure.name + ': readback never erases a POST failure');
        if (failure.details) assert.ok(error.includes(failure.details), 'full mutation diagnostics survive readback');
        assert.match(s.get('ps-config-status').textContent, /Autostart update (?:failed|result unknown)/);
        assert.match(s.button.title, /Autostart update/);
        s.mutation.reply({ success: true, enabled: false }); s.mutation.onerror(); s.mutation.ontimeout(); s.mutation.abort();
        s.tick(600000);
        assert.equal(s.reads().length, 2, 'late mutation events cannot start another readback');
        assert.equal(s.posts().length, 1, 'readback and timer completion never replay the mutation');
    }

    // A readback failure retains both received operation diagnostics and the
    // read error. Neither an ACK nor error.data.enabled can replace that read.
    for (const postFailed of [false, true]) for (const failure of badAutostartReads) {
        const s = startAutostart();
        if (postFailed) s.mutation.reply({ success: false, error: 'Checked update failed', details: fullDetails });
        else s.mutation.reply({ success: true, enabled: true });
        const readback = s.last('/autostart'); failure.run(readback);
        assert.equal(s.button.textContent, 'Autostart: Unknown', failure.name);
        assert.equal(s.button.disabled, true);
        const error = autostartErrors(s);
        assert.ok(error.includes('Readback: ' + failure.message), failure.name);
        if (failure.details) assert.ok(error.includes(failure.details));
        if (postFailed) {
            assert.ok(error.includes('Checked update failed'));
            assert.ok(error.includes(fullDetails), 'readback failure retains the complete POST failure');
        } else assert.match(error, /update acknowledged; readback failed/);
        s.button.dispatch('click'); assert.equal(s.posts().length, 1);
        readback.reply({ enabled: true });
        assert.equal(s.button.disabled, true, 'a stale readback success cannot clear the failed current observation');
        assert.equal(s.posts().length, 1);
    }
    {
        const s = startAutostart(); s.mutation.reply({ success: true, enabled: true });
        s.last('/autostart').reply({ enabled: false });
        assert.equal(s.button.textContent, 'Autostart: OFF', 'display actual readback, not the desired state');
        assert.match(autostartErrors(s), /readback did not match.*\n\nExpected autostart ON, but read back OFF/);
        assert.equal(s.posts().length, 1);
    }

    // Old reads/ACKs cannot unlock a newer operation or overwrite its state.
    // Exercise the actual once-only adapters, including two explicit mutations.
    {
        const s = startAutostart(), firstPost = s.mutation;
        s.initialRead.reply({ enabled: true }); s.initialRead.onerror();
        assert.equal(s.button.disabled, true);
        assert.equal(s.button.textContent, 'Autostart: Unknown');
        firstPost.reply({ success: true, enabled: true });
        const firstReadback = s.last('/autostart');
        firstPost.reply({ success: true, enabled: false }); firstPost.ontimeout();
        assert.equal(s.reads().length, 2);
        firstReadback.reply({ enabled: true }); s.button.click();
        const secondPost = s.last('/autostart/toggle');
        assert.notEqual(secondPost, firstPost);
        assert.equal(secondPost.body, 'token=test-token&action=disable');
        firstReadback.reply({ enabled: false }); s.initialRead.reply({ error: 'Stale failure' });
        assert.equal(s.button.textContent, 'Autostart: Unknown');
        assert.equal(s.button.disabled, true);
        s.button.dispatch('click'); assert.equal(s.posts().length, 2);
        secondPost.reply({ success: true, enabled: false });
        s.last('/autostart').reply({ enabled: false });
        firstReadback.reply({ enabled: true }); secondPost.onerror();
        assert.equal(s.button.textContent, 'Autostart: OFF');
        assert.equal(s.button.disabled, false);
        assert.equal(s.reads().length, 3);
        assert.equal(s.posts().length, 2);
    }
}

async function main() {
    transportCases();
    await multipartCases();
    autostartCases();
    console.log('Frontend transport regressions: PASS (whole error.data, object/HTTP matrix, once-only events, File/CSRF, typed Autostart/readback/failed/stale outcomes)');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
