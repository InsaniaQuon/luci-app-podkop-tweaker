// frontend_update_spec.js | v1.1.0 | 17.10.2026 | Ordinary JSON requests, multipart and generation regressions
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
        this.disabled = false;
        this.classList = { add() {}, remove() {}, contains() { return false; } };
    }
    set textContent(text) { this._text = String(text); this.children = []; }
    get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
    set innerHTML(text) { this._text = text; this.children = []; }
    get innerHTML() { return this._text; }
    appendChild(child) { if (child.parentNode) child.parentNode.removeChild(child); this.children.push(child); child.parentNode = this; }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
    insertBefore(child, before) { if (child.parentNode) child.parentNode.removeChild(child); const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentNode = this; }
    get firstChild() { return this.children[0]; }
    addEventListener(event, cb) { this.listeners[event] = cb; }
    click() { if (!this.disabled && this.listeners.click) this.listeners.click(); }
    getAttribute(name) { return this.attrs[name] || null; }
    setAttribute(name, value) { this.attrs[name] = value; }
}

class Form {
    constructor() { this.parts = []; }
    append(name, value, filename) { this.parts.push({ name, value, filename }); }
}

const repo = path.resolve(__dirname, '..');
const common = fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');
const urls = { upload: '/upload', apply: '/apply', systemInfo: '/info', checkUpdates: '/check',
    tweakerUpdate: '/git', argonThemeUpdate: '/theme', clearCache: '/cache', restartStatus: '/restart/status', appVersion: '/version' };

function setup(viewName) {
    const requests = [], elements = {}, calls = [], timers = [], events = {}, prompts = [];
    let now = 0, reloads = 0, parses = 0;
    class XHR {
        constructor() { this.headers = {}; requests.push(this); }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader(name, value) { this.headers[name] = value; }
        send(body) { this.body = body; }
        reply(data, status = 200) { this.status = status; this.responseText = typeof data === 'string' ? data : JSON.stringify(data); this.onload(); }
        abort() { if (this.onabort) this.onabort(); }
    }
    class Clock extends Date { static now() { return now; } }
    const get = id => elements[id] || (elements[id] = new Element('span'));
    const root = { attrs: {}, style: { setProperty(key, value) { this[key] = value; } }, getAttribute(name) { return this.attrs[name]; }, setAttribute(name, value) { this.attrs[name] = value; } };
    const document = { documentElement: root, querySelectorAll() { return []; }, getElementById: get, createElement: tag => new Element(tag) };
    const window = { PT: { csrf: 'test-token', version: '4.10.2', urls: { ...urls } },
        location: { href: 'http://router.test/admin/services/podkop-tweaker/' + (viewName || 'update'),
            replace(url) { this.href = url; reloads++; }, reload() { reloads++; } },
        addEventListener(event, cb) { events[event] = cb; }, removeEventListener(event) { delete events[event]; } };
    const context = vm.createContext({ window, document, XMLHttpRequest: XHR, FormData: Form, URL, Date: Clock,
        JSON: { parse(text) { parses++; return JSON.parse(text); }, stringify: JSON.stringify },
        confirm(text) { prompts.push(text); return true; },
        setTimeout(fn, delay) { const timer = { fn, at: now + delay }; timers.push(timer); return timer; },
        clearTimeout(timer) { if (timer) timer.cancelled = true; } });
    vm.runInContext(common, context);
    const PT = window.PT;
    context.PT = PT;
    PT.checkStale = function() {};
    // Observe the real adapter; neither page nor its transport is substituted.
    const postJson = PT.postJson;
    PT.postJson = function(url, params, callback, timeout) {
        const call = { url, params, timeout, completions: 0 };
        calls.push(call);
        return postJson(url, params, function(data, error, xhr) {
            Object.assign(call, { data, error, xhr, completions: call.completions + 1 });
            callback(data, error, xhr);
        }, timeout);
    };
    if (viewName) {
        const source = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker', viewName + '.htm'), 'utf8');
        const scripts = [...source.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
        vm.runInContext(scripts.at(-1)[1], context);
    }
    return { PT, context, requests, elements, calls, prompts, get,
        last(url) { return requests.filter(request => request.url === url).at(-1); },
        call(url) { return calls.filter(call => call.url === url).at(-1); },
        parses() { return parses; }, reloads() { return reloads; },
        tick(ms) { now += ms; for (const timer of [...timers]) if (!timer.cancelled && !timer.ran && timer.at <= now) { timer.ran = true; timer.fn(); } } };
}
const { PT, context, requests, elements } = setup();

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
const backend = fs.readFileSync(path.join(repo, 'usr/lib/lua/podkop-tweaker/api_update.lua'), 'utf8');
const uploadLimit = Number(backend.match(/M\.UPLOAD_MAX_SIZE = (\d+)/)[1]);
assert.equal(uploadLimit, 256000);
assert.equal(Number(view.match(/var uploadMaxSize = (\d+)/)[1]), uploadLimit, 'UI/server upload limits must agree');
const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
vm.runInContext(scripts[scripts.length - 1][1], context);
const input = elements['ps-file-input'];
const file = { name: 'luci-app-podkop-tweaker-v4.5.1.tar.gz', size: 110000 };
input.files = [file];
input.listeners.change();
const upload = requests[1];
assert.equal(upload.url, '/upload');
assert.equal(upload.method, 'POST');
assert.equal(upload.timeout, 120000);
assert.ok(upload.body instanceof Form);
assert.equal(upload.headers['Content-Type'], undefined, 'browser must supply the multipart boundary');
assert.equal(upload.body.parts[0].name, 'archive');
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
input.files = [{ name: file.name, size: uploadLimit + 1 }];
input.listeners.change();
assert.equal(requests.length, requestCount, 'oversized archive must be rejected before sending');
assert.match(elements['ps-update-actions'].textContent, /Archive too large/);
for (const size of [128001, uploadLimit]) {
    const boundaryFile = { name: file.name, size };
    input.files = [boundaryFile];
    const before = requests.length;
    input.listeners.change();
    assert.equal(requests.length, before + 1, 'accepted boundary must reach multipart transport');
    const request = requests[requests.length - 1];
    assert.equal(request.body.parts[0].value, boundaryFile);
    request.status = 400;
    request.responseText = JSON.stringify({ error: 'Controlled archive validation failure' });
    request.onload();
    assert.equal(input.disabled, false);
}

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

function findElement(el, predicate) {
    if (predicate(el)) return el;
    for (const child of el.children) { const match = findElement(child, predicate); if (match) return match; }
    return null;
}
function preElement(el) { return findElement(el, node => node.tagName === 'PRE'); }
function startUpload(s, selected = file) {
    s.get('ps-file-input').files = [selected];
    s.get('ps-file-input').listeners.change();
    return s.last('/upload');
}
const preview = { success: true, current_version: '4.10.2', archive_version: '4.10.3', same_version: false, can_update: true };
const previousInstance = { verification_required: true, previous_running: true, previous_instance: '42:100', previous_identity_known: true };
const failureData = { success: false, error: 'Cannot complete request', details: full, applied: true, unknown: true,
    phase: 'cleanup', resume_available: true, partial: true, ...previousInstance,
    archive_version: '9.9.9', can_update: true,
    results: { theme: { ok: false, applied: true, details: full } }, restarts: { theme: previousInstance },
    theme: { current_version: '9.9.9-r1', latest_version: '9.9.9-r2', update_available: true, resume_available: true, phase: 'cleanup' } };
const failures = [
    ...[400, 500, 200].map(status => ({ name: status === 200 ? 'application metadata' : 'HTTP metadata ' + status,
        kind: status === 200 ? 'application' : 'http', message: failureData.error, data: failureData, details: full,
        run: request => request.reply(failureData, status) })),
    { name: 'application error without success', kind: 'application', message: 'Validation failed', details: full,
        data: { error: 'Validation failed', details: full }, run: request => request.reply({ error: 'Validation failed', details: full }) },
    { name: 'explicit false success', kind: 'application', message: 'Operation failed',
        data: { success: false }, run: request => request.reply({ success: false }) },
    { name: 'HTTP login page', kind: 'http', message: 'HTTP error: 403', details: '<html>LuCI login</html>',
        run: request => request.reply('<html>LuCI login</html>', 403) },
    ...['<html>LuCI login</html>', '{invalid JSON', '[]', 'null', 'true', '42', '"scalar"'].map(text => ({
        name: 'invalid object: ' + text, kind: 'parse', message: 'Invalid response', details: text, run: request => request.reply(text) })),
    ...[['onerror', 'Network error'], ['ontimeout', 'Request timed out'], ['onabort', 'Request aborted']].map(([event, message]) => ({
        name: event, kind: 'transport', message, run: request => request[event]() }))
];
function assertFailure(s, call, request, failure, beforeParses) {
    assert.ok(call, 'page uses the shared object adapter: ' + failure.name);
    assert.equal(call.data, null, failure.name);
    assert.equal(call.error.kind, failure.kind, failure.name);
    assert.equal(call.error.message, failure.message, failure.name);
    assert.equal(call.completions, 1);
    assert.equal(call.xhr, failure.kind === 'transport' ? null : request);
    assert.equal(s.parses() - beforeParses, failure.kind === 'transport' ? 0 : 1, 'only the adapter parses: ' + failure.name);
    if (failure.data) assert.deepEqual(call.error.data, failure.data, 'complete error metadata remains intact');
    else assert.equal(Object.prototype.hasOwnProperty.call(call.error, 'data'), false, 'no fabricated payload');
    if (failure.details) assert.equal(call.error.details, failure.details, 'diagnostics are not truncated');
}

// Upload failures never become a preview from error.data. Every terminal path
// frees only its own upload gate, and a duplicate event cannot unlock a new one.
for (const failure of failures) {
    const s = setup('update'), request = startUpload(s), call = s.call('/upload'), beforeParses = s.parses();
    assert.equal(call.params, request.body);
    assert.ok(call.params instanceof Form);
    assert.deepEqual(request.body.parts.map(part => part.name), ['archive', 'token']);
    assert.equal(request.body.parts[0].value, file);
    assert.equal(request.body.parts[0].filename, file.name);
    assert.equal(request.headers['Content-Type'], undefined);
    assert.equal(request.timeout, 120000);
    const inFlight = s.requests.length;
    startUpload(s);
    assert.equal(s.requests.length, inFlight, 'upload is not sent twice');
    failure.run(request);
    assertFailure(s, call, request, failure, beforeParses);
    assert.equal(s.get('ps-file-input').disabled, false);
    assert.equal(s.get('ps-current-ver').textContent, '-');
    assert.equal(s.get('ps-archive-ver').textContent, '-');
    const status = s.get('ps-update-actions');
    assert.ok(status.textContent.includes(failure.message));
    assert.doesNotMatch(status.innerHTML, /ps-apply-btn/);
    if (failure.details) {
        assert.equal(preElement(status).textContent, failure.details);
        assert.equal(preElement(status).children.length, 0, 'markup in diagnostics remains plain text');
    }
    const next = startUpload(s), uploadingText = status.textContent, parsesAfterFailure = s.parses();
    request.reply(preview); request.onerror();
    assert.equal(call.completions, 1);
    assert.equal(s.parses(), parsesAfterFailure, 'late events do not parse again');
    assert.equal(s.get('ps-file-input').disabled, true, 'old completion cannot release the new upload');
    assert.equal(status.textContent, uploadingText);
    next.reply(preview);
    assert.equal(s.get('ps-file-input').disabled, false);
    assert.equal(s.get('ps-archive-ver').textContent, 'v4.10.3');
    assert.match(status.innerHTML, /ps-apply-btn/);
}
for (const data of [{}, { archive_version: '9.9.9', can_update: true, details: full }]) {
    const s = setup('update');
    startUpload(s).reply(data);
    assert.match(s.get('ps-update-actions').textContent, /Unknown error/);
    if (data.details) assert.equal(preElement(s.get('ps-update-actions')).textContent, data.details);
    assert.equal(s.get('ps-file-input').disabled, false, 'upload still requires its endpoint-specific success reply');
}
{
    const s = setup('update'), drop = selected => s.get('ps-drop-zone').listeners.drop({ preventDefault() {}, stopPropagation() {}, dataTransfer: { files: [selected] } });
    drop({ name: file.name, size: uploadLimit + 1 });
    assert.equal(s.requests.length, 0, 'drop obeys the same pre-transport size guard');
    assert.equal(s.calls.length, 0);
    assert.match(s.get('ps-update-actions').textContent, /max 256000 bytes/);
    const selected = { name: file.name, size: uploadLimit };
    drop(selected);
    assert.equal(s.last('/upload').body.parts[0].value, selected);
    assert.equal(s.last('/upload').body.parts[0].filename, selected.name);
}

const releaseUrl = 'https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.10.3/luci-app-podkop-tweaker-v4.10.3.tar.gz';
function systemPage(fields = {}) {
    const s = setup('system-info');
    s.last('/info').reply({ podkop_version: '0.7.4', podkop_latest_version: '0.7.5', update_available: true,
        tweaker_version: '4.10.2', tweaker_latest: '4.10.3', tweaker_download_url: releaseUrl,
        argon_theme_version: '3.0.0-r1', argon_theme_latest: '3.0.0-r2', argon_theme_update_available: true,
        argon_theme_resume_available: false, ...fields });
    return s;
}
function aggregate(theme = {}) {
    return { podkop: { latest_version: '0.7.5', update_available: true },
        tweaker: { current_version: '4.10.2', latest_version: '4.10.3', update_available: true, download_url: releaseUrl },
        theme: { current_version: '3.0.0-r2', latest_version: '3.0.0-r2', update_available: true, ...theme } };
}
function forceCheck(s, response) {
    s.get('ps-check-updates').click();
    const request = s.last('/check'); request.reply(response);
    return s.call('/check');
}
function rowState(s) {
    return ['ps-info-podkop', 'ps-info-tweaker', 'ps-info-argon', 'ps-row-argon'].map(id => [s.get(id).innerHTML, s.get(id).style.display]);
}

// A top-level failed check leaves the last decisions intact. A successful
// aggregate does not need success=true, even if one of its sources has an error.
for (const failure of failures) {
    const s = systemPage(), rows = rowState(s);
    s.get('ps-check-updates').click();
    const request = s.last('/check'), call = s.call('/check'), beforeParses = s.parses();
    assert.equal(request.method, 'POST');
    assert.equal(request.body, 'token=test-token');
    assert.equal(request.timeout, 120000);
    assert.equal(s.get('ps-check-updates').disabled, true);
    failure.run(request);
    assertFailure(s, call, request, failure, beforeParses);
    assert.equal(s.get('ps-check-updates').disabled, false);
    assert.deepEqual(rowState(s), rows);
    const status = s.get('ps-update-status');
    assert.ok(status.textContent.includes(failure.message));
    if (failure.details) assert.equal(preElement(status).textContent, failure.details);
    s.get('ps-check-updates').click();
    const next = s.last('/check'), checkingText = status.textContent, parsesAfterFailure = s.parses();
    request.reply(aggregate()); request.onabort();
    assert.equal(call.completions, 1);
    assert.equal(s.parses(), parsesAfterFailure);
    assert.equal(s.get('ps-check-updates').disabled, true);
    assert.equal(status.textContent, checkingText);
    next.reply(aggregate());
    assert.equal(s.get('ps-check-updates').disabled, false);
    assert.match(s.get('ps-update-status').textContent, /Argon: update available/);
}
{
    const s = systemPage(), response = aggregate({ resume_available: true, phase: 'translation <pending>&', extra: { pinned: true } });
    const beforeParses = s.parses(), call = forceCheck(s, response);
    assert.equal(Object.prototype.hasOwnProperty.call(response, 'success'), false);
    assert.equal(call.error, null);
    assert.deepEqual(call.data, response, 'full source decisions survive the adapter');
    assert.equal(s.parses() - beforeParses, 1);
    assert.match(s.get('ps-info-argon').innerHTML, /^3\.0\.0-r2 /);
    assert.match(s.get('ps-info-argon').innerHTML, /Resume Theme Update/);
    assert.match(s.get('ps-info-argon').innerHTML, /phase: translation &lt;pending&gt;&amp;/);
    assert.match(s.get('ps-update-status').textContent, /Argon: resume available/);

    const perSource = aggregate({ error: 'Cannot verify packages', details: full, resume_available: true, phase: 'packages' });
    perSource.podkop = { error: 'Podkop check unavailable' };
    perSource.tweaker = { error: 'rate_limited' };
    const failedSource = forceCheck(s, perSource);
    assert.equal(failedSource.error, null, 'per-source failure is still a valid aggregate');
    assert.deepEqual(failedSource.data, perSource);
    assert.doesNotMatch(s.get('ps-info-argon').innerHTML, /ps-argon-update-btn/);
    assert.equal(preElement(s.get('ps-info-argon')).textContent, full);
    assert.match(s.get('ps-info-tweaker').innerHTML, /Update from Git/, 'source errors retain the existing Tweaker decision');
    assert.match(s.get('ps-update-status').textContent, /Podkop: error.*Tweaker: checked just now.*Argon: error/);
    s.get('ps-argon-update-btn').listeners.click();
    assert.equal(s.requests.filter(request => request.url === '/theme').length, 0, 'stale theme listener cannot bypass the new error');

    forceCheck(s, aggregate({ update_available: false, resume_available: false }));
    assert.equal(s.get('ps-info-argon').textContent, '3.0.0-r2', 'clears old error, phase and resume state');
    forceCheck(s, aggregate({ update_available: true, resume_available: false }));
    assert.match(s.get('ps-info-argon').innerHTML, /Update Theme/, 'equal revisions may still need a companion update');
    forceCheck(s, aggregate({ current_version: null, latest_version: null, update_available: false }));
    assert.equal(s.get('ps-row-argon').style.display, 'none', 'absence replaces the entire previous decision');
    assert.equal(s.get('ps-info-argon').textContent, '');
}

// Text-only sinks receive raw values; dynamic HTML remains escaped.
for (const available of [false, true]) {
    const s = systemPage({ podkop_version: '<current>&', podkop_latest_version: '<next>&', update_available: available });
    if (!available) assert.equal(s.get('ps-info-podkop').textContent, '<current>&');
    else {
        assert.match(s.get('ps-info-podkop').innerHTML, /^&lt;current&gt;&amp; /);
        assert.match(s.get('ps-info-podkop').innerHTML, /&lt;next&gt;&amp;/);
        assert.doesNotMatch(s.get('ps-info-podkop').innerHTML, /<current>|<next>/);
    }
}
for (const [latest, button] of [['5.0.0<&>', 'ps-tweaker-update-btn'], ['3.0.0<&>', 'ps-tweaker-downgrade-btn']]) {
    const s = systemPage({ tweaker_latest: latest });
    s.context.confirm = text => { s.prompts.push(text); return false; };
    s.get(button).click();
    assert.ok(s.prompts.at(-1).includes('v' + latest + '?'));
    assert.doesNotMatch(s.prompts.at(-1), /&lt;|&gt;|&amp;/);
    assert.match(s.get('ps-info-tweaker').innerHTML, /&lt;&amp;&gt;/);
    assert.equal(s.requests.filter(request => request.url === '/git').length, 0, 'cancel does not apply');
}

// Refreshed Git metadata still owns the selected URL/version and force flag.
// A lost downgrade ACK must not authorize the legacy version-only fallback.
for (const [latest, downgrade] of [['4.10.3', false], ['4.8.1', true]]) {
    const s = systemPage({ tweaker_latest: null, tweaker_download_url: '' }), response = aggregate();
    const downloadUrl = releaseUrl.replace(/4\.10\.3/g, latest);
    response.tweaker.latest_version = latest;
    response.tweaker.download_url = downloadUrl;
    forceCheck(s, response);
    s.get(downgrade ? 'ps-tweaker-downgrade-btn' : 'ps-tweaker-update-btn').click();
    const post = s.last('/git'), params = new URLSearchParams(post.body), id = params.get('restart_id');
    assert.equal(params.get('download_url'), downloadUrl);
    assert.equal(params.get('token'), 'test-token');
    assert.equal(params.get('force'), downgrade ? '1' : null);
    assert.match(id, /^[a-f0-9]{32}$/);
    const probe = () => s.requests.filter(request => request.url.startsWith('/restart/status?')).at(-1);
    if (downgrade) {
        post.onerror(); probe().reply('Not found', 404); s.tick(1000);
        assert.equal(s.requests.filter(request => request.url.startsWith('/version')).length, 0);
        assert.equal(s.get('ps-check-updates').disabled, true);
        assert.equal(s.get('ps-refresh-info').disabled, true);
        assert.equal(s.reloads(), 0);
    } else {
        post.reply({ success: true, restart_id: id, new_version: latest });
        const ready = { id, state: 'applied', ready: true, installed_version: latest };
        probe().reply({ ...ready, restarted: false });
        assert.equal(s.reloads(), 0);
        s.tick(1000); probe().reply({ ...ready, restarted: true });
        assert.equal(s.reloads(), 1);
    }
    assert.equal(s.requests.filter(request => request.url === '/git').length, 1);
}

// A check started in an earlier webGeneration must return before touching any
// decision, status or action lock, whether its terminal outcome is success/error.
for (const knownFailure of [false, true]) {
    for (const terminal of [{ name: 'aggregate', run: request => request.reply(aggregate({ update_available: false })) }, ...failures]) {
        const s = systemPage();
        s.get('ps-check-updates').click();
        const check = s.last('/check');
        s.get('ps-argon-update-btn').click();
        const mutation = s.last('/theme');
        if (knownFailure) mutation.reply({ success: false, error: 'Locale install failed', details: full, partial: true, resume_available: true, phase: 'translation' });
        else { mutation.onerror(); s.tick(60000); }
        const rows = rowState(s), status = s.get('ps-argon-status').textContent, checkStatus = s.get('ps-update-status').textContent;
        const controls = ['ps-check-updates', 'ps-refresh-info', 'ps-clear-cache', 'ps-argon-update-btn'];
        const locks = controls.map(id => s.get(id).disabled);
        terminal.run(check);
        assert.deepEqual(rowState(s), rows, terminal.name);
        assert.equal(s.get('ps-argon-status').textContent, status, terminal.name);
        assert.equal(s.get('ps-update-status').textContent, checkStatus, terminal.name);
        assert.deepEqual(controls.map(id => s.get(id).disabled), locks, 'stale callback cannot unlock controls: ' + terminal.name);
        assert.equal(s.get('ps-check-updates').disabled, !knownFailure);
        assert.equal(s.requests.filter(request => request.url === '/theme').length, 1);
        if (knownFailure) assert.equal(s.get('ps-argon-update-btn').textContent, 'Resume Theme Update');
        else {
            const retry = findElement(s.get('ps-argon-status'), node => /ps-restart-retry/.test(node.className || ''));
            assert.ok(retry); retry.click();
            assert.equal(s.requests.filter(request => request.url === '/theme').length, 1, 'uncertain state permits read-only verification');
        }
    }
}

// A completed upload cannot unlock Apply after a lost ACK/applied uncertainty.
// Reinstall still needs operation ID + restarted proof, not equal version alone.
for (const outcome of ['network', 'parse', 'applied']) {
    const s = setup('update'), upload = startUpload(s);
    upload.reply({ ...preview, archive_version: '4.10.2', same_version: true, can_update: false });
    s.get('ps-apply-btn').click();
    const apply = s.last('/apply'), id = new URLSearchParams(apply.body).get('restart_id');
    assert.match(apply.body, /^token=test-token&reinstall=1&restart_id=[a-f0-9]{32}$/);
    if (outcome === 'network') apply.onerror();
    else if (outcome === 'parse') apply.reply('<html>lost apply response</html>');
    else apply.reply({ success: false, applied: true, error: 'Cannot record application result', details: full });
    if (outcome !== 'applied') s.tick(60000);
    const requestCount = s.requests.length, status = s.get('ps-apply-status').textContent;
    upload.reply(preview);
    startUpload(s, { name: file.name, size: uploadLimit + 1 });
    s.get('ps-apply-btn').listeners.click();
    assert.equal(s.requests.length, requestCount);
    assert.equal(s.get('ps-apply-status').textContent, status);
    assert.equal(s.get('ps-file-input').disabled, true);
    assert.equal(s.get('ps-apply-btn').disabled, true);
    const retry = findElement(s.get('ps-apply-status'), node => /ps-restart-retry/.test(node.className || ''));
    assert.ok(retry); retry.click();
    const probe = () => s.requests.filter(request => request.url.startsWith('/restart/status?')).at(-1);
    assert.equal(new URL('http://router.test' + probe().url).searchParams.get('id'), id);
    const ready = { id, state: 'applied', ready: true, installed_version: '4.10.2' };
    probe().reply({ ...ready, restarted: false });
    assert.equal(s.reloads(), 0);
    s.tick(1000); probe().reply({ ...ready, restarted: true });
    assert.equal(s.reloads(), 1);
    assert.match(s.context.window.location.href, new RegExp('_pt_reload=' + id));
    assert.equal(s.requests.filter(request => request.url === '/apply').length, 1, 'verification never replays Apply');
}

if (process.argv[2]) {
    const archive = fs.readFileSync(process.argv[2]);
    const b64 = archive.toString('base64');
    const body = 'token=' + 'c'.repeat(64) + '&file_data=' + encodeURIComponent(b64) + '&file_name=' + encodeURIComponent(path.basename(process.argv[2]));
    console.log(`Archive: ${archive.length} bytes; old encoded POST: ${body.length} bytes; LuCI text limit: 102400 bytes`);
}
console.log('Frontend update regressions: PASS (object transport/errors, aggregate/theme decisions, generation guards, multipart/CSRF/size, reinstall/downgrade, lost ACK locks, plaintext sinks)');
