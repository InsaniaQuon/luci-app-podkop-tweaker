// Real frontend scripts: failed transports, independent settings and restart recovery.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');

function setup(view, urls) {
    const elements = {}, requests = [], timers = [], events = {}, documentEvents = {};
    let now = 0, reloads = 0;
    class Element {
        constructor(tag = 'span') {
            this.tagName = tag.toUpperCase(); this.attrs = {}; this.style = { setProperty(key, value) { this[key] = value; } };
            this.children = []; this.listeners = {}; this.value = '10'; this.disabled = false;
            this.options = [5, 10, 15, 20, 25].map(value => ({ value: String(value) }));
            this.classList = { add() {}, remove() {}, contains: name => (this.className || '').split(' ').includes(name) };
        }
        getAttribute(key) { return this.attrs[key] ?? null; }
        setAttribute(key, value) { this.attrs[key] = value; }
        addEventListener(event, cb) { (this.listeners[event] ||= []).push(cb); }
        removeEventListener(event, cb) { this.listeners[event] = (this.listeners[event] || []).filter(fn => fn !== cb); }
        dispatch(event, data = {}) { for (const cb of this.listeners[event] || []) cb.call(this, { preventDefault() {}, target: this, ...data }); }
        click() { if (!this.disabled) this.dispatch('click'); }
        get firstChild() { return this.children[0]; }
        set textContent(value) { this._text = String(value); this.children = []; }
        get textContent() { return (this._text || '') + this.children.map(child => child.textContent).join(''); }
        set innerHTML(value) {
            this._text = value; this.children = [];
            if (/^<input type="checkbox" checked>/.test(value)) { const input = new Element('input'); input.type = 'checkbox'; input.checked = true; this.appendChild(input); }
        }
        get innerHTML() { return this._text || ''; }
        appendChild(child) { if (child.parentNode) child.parentNode.removeChild(child); this.children.push(child); child.parentNode = this; }
        removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
        insertBefore(child, before) { if (child.parentNode) child.parentNode.removeChild(child); const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentNode = this; }
        querySelectorAll(selector) {
            if (this.buttons && (selector === '[data-section]' || selector === '.ps-sub-proxy-item')) return this.buttons;
            const all = this.children.flatMap(child => [child, ...child.querySelectorAll('*')]);
            if (selector === 'input[type="checkbox"]') return all.filter(child => child.tagName === 'INPUT' && child.type === 'checkbox');
            if (selector.startsWith('.ps-patch-cb')) return all.filter(child => child.className === 'ps-patch-cb' && (!selector.endsWith(':checked') || child.checked));
            if (selector.startsWith('.')) return all.filter(child => (child.className || '').split(' ').includes(selector.slice(1)));
            return all;
        }
        setCustomValidity(message) { this.validityMessage = message; }
        contains() { return true; }
        closest() { return this.attrs['data-section'] ? this : null; }
    }
    const get = id => elements[id] ||= new Element();
    class XHR {
        constructor() { requests.push(this); this.headers = {}; }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader(key, value) { this.headers[key] = value; }
        send(body) { this.body = body; }
        reply(data, status = 200) { this.status = status; this.responseText = typeof data === 'string' ? data : JSON.stringify(data); this.onload(); }
        abort() { if (this.onabort) this.onabort(); }
    }
    class FormData { constructor() { this.parts = []; } append(name, value, filename) { this.parts.push({ name, value, filename }); } }
    class Clock extends Date { static now() { return now; } }
    const document = { documentElement: get('root'), body: get('body'), getElementById: get,
        querySelectorAll(selector) { return selector === '.ps-modal' ? Object.values(elements).filter(el => el.__ptModalHide) : []; }, createElement: tag => new Element(tag),
        addEventListener(event, fn) { (documentEvents[event] ||= []).push(fn); } };
    const window = { PT: { csrf: 'token', version: '4.9.0', urls },
        location: { href: 'http://router.test/admin/services/podkop-tweaker/' + view, origin: 'http://router.test', reload() { reloads++; }, replace(url) { this.href = url; reloads++; } },
        addEventListener(event, cb) { events[event] = cb; }, removeEventListener(event) { delete events[event]; } };
    const context = vm.createContext({ window, document, XMLHttpRequest: XHR, FormData, Blob, URL, Date: Clock,
        confirm: () => true, setTimeout(fn, delay) { const t = { fn, at: now + delay }; timers.push(t); return t; },
        clearTimeout(t) { if (t) t.cancelled = true; }, setInterval() {}, clearInterval() {} });
    vm.runInContext(fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8'), context);
    context.PT = window.PT; window.PT.checkStale = () => {};
    const source = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker', view + '.htm'), 'utf8');
    if (view === 'argon' || view === 'singbox') {
        // Reflect the initial disabled/value state from the actual forms. Keep
        // this lightweight DOM; native geometry/cascade stays in browser tests.
        for (const [, tag, attrs, id] of source.matchAll(/<([a-z][\w-]*)\b([^>]*\bid="([^"]+)"[^>]*)>/gi)) {
            const el = get(id); el.tagName = tag.toUpperCase(); el.disabled = /\bdisabled\b/.test(attrs);
            el.checked = /\bchecked\b/.test(attrs);
            const value = attrs.match(/\bvalue="([^"]*)"/), display = attrs.match(/\bdisplay:([^;"\s]+)/);
            if (value) el.value = value[1];
            if (display) el.style.display = display[1];
        }
        if (view === 'singbox') get('diff-parent').appendChild(get('ps-diff-stats'));
    }
    const scripts = [...source.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    vm.runInContext(scripts.at(-1)[1], context);
    return { get, window, context, requests, events, FormData,
        escape() { for (const fn of documentEvents.keydown || []) fn({ key: 'Escape', preventDefault() {}, stopPropagation() {} }); },
        last(url) { return requests.filter(r => r.url === url).at(-1); },
        tick(ms) { now += ms; for (const t of [...timers]) if (!t.cancelled && !t.ran && t.at <= now) { t.ran = true; t.fn(); } },
        reloads() { return reloads; },
        button(kind, section = 'main', index = 0) { const btn = new Element('button'); btn.className = kind; btn.setAttribute('data-section', section); btn.setAttribute('data-index', String(index)); btn.setAttribute('data-url', 'https://sub.test'); get('ps-subs-content').buttons = [btn]; return btn; } };
}

// Run the real object adapter, then discard its raw failure text before the page
// receives the callback. Per-page recovery must consume the retained typed body,
// including fields that were never flattened onto the transport error.
function retainErrorBodies(s) {
    const failures = [], postJson = s.window.PT.postJson;
    s.window.PT.postJson = function(url, params, callback, timeout) {
        return postJson(url, params, function(data, error, xhr) {
            if (error) {
                assert.equal(data, null);
                failures.push(error);
                if (xhr) xhr.responseText = '';
            }
            callback(data, error, xhr);
        }, timeout);
    };
    return failures;
}
function assertRetainedBody(failures, expected) {
    assert.ok(failures.at(-1)?.data, 'the shared adapter retains the complete object failure body');
    assert.deepEqual(JSON.parse(JSON.stringify(failures.at(-1).data)), expected, 'page consumers must not strip or mutate the retained body');
}

const subUrls = { state: '/state', settings_read: '/settings', settings_save: '/settings/save', auto_status: '/auto/status',
    read_log: '/log', fetch: '/fetch', attach: '/attach', detach: '/detach', update_all: '/all', service_status: '/service' };
function subscriptions() { return setup('subscriptions', { ...subUrls }); }

const typographyUrls = { typography: '/typography', save: '/typography/save', reset: '/typography/reset', reinject: '/typography/reinject',
    appearance: '/appearance', appearanceSave: '/appearance/save', appearanceReset: '/appearance/reset', appearanceColorsReset: '/appearance/colors' };
const typographySettings = { font_size: '18', font_family: 'Verdana', font_family_custom: '', font_weight: '550',
    line_height: '1.7', letter_spacing: '0.2', menu_font_size: '1.1', menu_padding: '14' };
const singboxUrls = { read: '/read', save: '/save', status: '/status', rollback: '/rollback', toggle: '/toggle',
    outbounds: '/outbounds', patchFragment: '/patch', wrapperStatus: '/wrapper/status', wrapperToggle: '/wrapper/toggle', fragmentSettings: '/fragment/settings' };
const typedOutbound = { tag: 'proxy', type: 'vless', server: '<img src=x onerror=literal()>', tls_enabled: true, has_fragment: false };
const formReadFailures = [
    { name: 'network', run: r => r.onerror() }, { name: 'timeout', run: r => r.ontimeout() }, { name: 'abort', run: r => r.abort() },
    ...[null, [], {}, '<html>LuCI login</html>', { error: 'Current settings cannot be read', details: '<script>complete literal IO details</script>\n' + 'read failed\n'.repeat(100) }]
        .map(data => ({ name: JSON.stringify(data), run: r => r.reply(data) })),
    { name: 'HTTP 403', run: r => r.reply('<html>LuCI login</html>', 403) }
];

// A failed first Typography read cannot turn DOM defaults into a mutation or
// CSS-active evidence, even if a caller bypasses disabled buttons/events.
for (const failure of [...formReadFailures,
    ...[{ settings: [], stale: false }, { settings: {}, stale: 'false' }, { settings: {}, stale: false, success: 'true' }, { settings: {}, stale: false, unknown: true },
        { settings: { error: 'Cannot read typography' }, stale: false }, { settings: { arbitrary: 'not native defaults' }, stale: false },
        { settings: { font_size: {} }, stale: false }, { settings: { font_size: '99' }, stale: false },
        { settings: { font_family: null }, stale: false }, { settings: {}, stale: false, error: 'No current UCI' }]
        .map(data => ({ name: JSON.stringify(data), run: r => r.reply(data) }))]) {
    const s = setup('argon', typographyUrls), read = s.last('/typography');
    assert.equal(read.timeout, 30000);
    assert.equal(s.get('ps-argon-save').disabled, true);
    s.get('ps-argon-save').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0, 'pending read: ' + failure.name);
    failure.run(read);
    for (const id of ['ps-argon-save', 'ps-argon-reset', 'ps-argon-reinject']) {
        assert.equal(s.get(id).disabled, true, failure.name);
        s.get(id).dispatch('click');
    }
    s.get('ps-font-size').value = '20'; s.get('ps-font-size').dispatch('input');
    assert.equal(s.get('root').style.fontSize, undefined, 'failed read does not enable global preview');
    assert.equal(s.get('ps-argon-css-status').textContent, 'CSS status unknown');
    assert.doesNotMatch(s.get('ps-argon-status').textContent, /CSS active/);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0, 'failed first read cannot POST: ' + failure.name);
    assert.equal(s.requests.filter(r => r.url === '/typography').length, 1, 'there is no automatic retry');

    s.get('ps-argon-retry').click();
    const retry = s.last('/typography'); assert.notEqual(retry, read);
    assert.equal(retry.method, 'GET');
    retry.reply({ settings: typographySettings, stale: true });
    assert.equal(s.get('ps-argon-save').disabled, false);
    assert.equal(s.get('ps-font-size').value, '18', 'valid retry replaces placeholder values with current settings');
    assert.equal(s.get('root').style.fontSize, undefined, 'valid GET still does not apply global preview on load');
    read.reply({ settings: {}, stale: false });
    assert.equal(s.get('ps-font-size').value, '18', 'late completion of a failed GET cannot replace the retry');
    s.get('ps-font-size').dispatch('input');
    assert.equal(s.get('root').style.fontSize, '18px', 'successful read retains the existing live preview');
    s.get('ps-argon-save').click();
    const params = new URLSearchParams(s.last('/typography/save').body);
    for (const [key, value] of Object.entries(typographySettings)) assert.equal(params.get(key), value);
    assert.equal(params.get('token'), 'token');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
    assert.equal(s.requests.some(r => r.method === 'POST' && r.url.startsWith('/appearance')), false, 'typography never writes app appearance');
}

const appearanceDefaults = { profile: 'soft', mono_font_size: '13', mono_font_weight: '400', mono_line_height: '1.6',
    color_success_light: '#00be00', color_error_light: '#ff0000', color_warning_light: '#ff8c42',
    color_success_dark: '#00ff00', color_error_dark: '#ff8080', color_warning_dark: '#ffbd42' };
const currentAppearance = { ...appearanceDefaults, profile: 'contrast', mono_font_size: '17', mono_font_weight: '500', mono_line_height: '1.7' };
function appearanceForm() {
    const s = setup('argon', typographyUrls);
    // Only the preview's fixed surface/alpha inputs are needed by this VM DOM.
    // Actual computed cascade/contrast remains in the native browser fixture.
    s.window.getComputedStyle = () => ({ backgroundColor: 'rgb(255, 255, 255)', getPropertyValue: key =>
        key.includes('preview-bg') ? key.endsWith('-dark') ? '#252526' : '#ffffff' : key.endsWith('-alpha') ? '0.1' : '' });
    return s;
}
for (const failure of [...formReadFailures, ...[
    { settings: {} }, { settings: [] }, { settings: currentAppearance, error: 'Checked UCI read failed' },
    { settings: currentAppearance, unknown: true }, { settings: { ...currentAppearance, mono_font_size: 17 } },
    { settings: { ...currentAppearance, color_error_dark: 'red' } }
].map(data => ({ name: JSON.stringify(data), run: r => r.reply(data) }))]) {
    const s = appearanceForm(), read = s.last('/appearance'), initialMono = s.get('root').style['--ps-mono-size'];
    s.get('ps-appearance-save').dispatch('click');
    failure.run(read);
    for (const id of ['ps-appearance-save', 'ps-appearance-reset', 'ps-colors-reset']) {
        assert.equal(s.get(id).disabled, true, failure.name);
        s.get(id).dispatch('click');
    }
    s.get('ps-mono-size').value = '18'; s.get('ps-mono-size').dispatch('input');
    assert.equal(s.get('root').style['--ps-mono-size'], initialMono, 'failed settings read cannot activate default-filled appearance preview');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0);
    s.get('ps-appearance-retry').click();
    assert.notEqual(s.last('/appearance'), read);
    s.last('/appearance').reply({ settings: currentAppearance, settings_source: 'uci', config_missing: false });
    assert.equal(s.get('ps-appearance-save').disabled, false);
    assert.equal(s.get('ps-mono-size').value, '17');
    assert.equal(s.get('root').style['--ps-success-dark'], '#00ff00', 'exact selected colors survive the typed read gate');
    s.get('ps-appearance-save').click();
    const params = new URLSearchParams(s.last('/appearance/save').body);
    for (const [key, value] of Object.entries(currentAppearance)) assert.equal(params.get(key), value);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
{
    const s = appearanceForm();
    s.last('/appearance').reply({ settings: { ...appearanceDefaults }, settings_source: 'defaults', config_missing: true });
    assert.equal(s.get('ps-appearance-save').disabled, false, 'explicit normalized first-run settings are accepted');
    s.get('ps-mono-size').value = '18'; s.get('ps-mono-size').dispatch('input');
    s.get('ps-appearance-save').click();
    s.last('/appearance/save').reply({ success: false, error: 'Cannot commit appearance settings' });
    assert.equal(s.get('ps-appearance-save').disabled, false, 'a checked non-applied failure retains the last successful read');
    s.get('ps-appearance-save').click();
    s.last('/appearance/save').reply({ success: false, applied: true, partial: true, uci_saved: true, lock_error: 'Cannot release appearance lock', error: 'Cannot finish appearance save' });
    assert.equal(s.get('ps-appearance-save').disabled, true);
    assert.equal(s.get('ps-mono-size').value, '18');
    assert.equal(s.get('root').style['--ps-mono-size'], '18px', 'partial failure retains unsaved preview instead of applying defaults');
    s.get('ps-appearance-save').dispatch('click'); s.get('ps-colors-reset').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 2);
    s.get('ps-appearance-retry').click(); s.last('/appearance').reply({ settings: { ...appearanceDefaults, mono_font_size: '18' } });
    assert.equal(s.get('ps-appearance-save').disabled, false);
}
{
    const s = appearanceForm(); s.last('/appearance').reply({ settings: currentAppearance });
    s.get('ps-mono-size').value = '18'; s.get('ps-mono-size').dispatch('input');
    s.get('ps-colors-reset').click();
    assert.equal(s.last('/appearance/colors').body, 'token=token');
    s.last('/appearance/colors').reply({ success: true, settings: currentAppearance });
    assert.equal(s.get('ps-mono-size').value, '18', 'Reset Colors preserves the unsaved font preview');
    s.get('ps-color-success-dark-hex').value = '#112233'; s.get('ps-color-success-dark-hex').dispatch('input');
    s.get('ps-appearance-reset').click();
    s.last('/appearance/reset').reply({ success: true, settings: appearanceDefaults });
    assert.equal(s.get('ps-mono-size').value, '13');
    assert.equal(s.get('ps-color-success-dark-hex').value, '#112233', 'Reset Appearance preserves unsaved selected colors');
    assert.equal(s.get('root').style['--ps-success-dark'], '#112233');
}
{
    const s = setup('argon', typographyUrls);
    s.last('/typography').reply({ settings: {}, stale: true });
    assert.equal(s.get('ps-argon-save').disabled, false, 'an explicit typed first-run/default response is allowed');
    assert.equal(s.get('ps-font-size').value, '16');
    assert.equal(s.get('ps-font-family').value, 'Google Sans');
    s.get('ps-argon-save').click();
    const details = '<img src=x onerror=literal()>\n' + 'complete CSS failure\n'.repeat(100);
    s.last('/typography/save').reply({ success: false, applied: true, error: 'UCI saved; CSS publication failed', details });
    assert.equal(s.get('ps-argon-save').disabled, true, 'partial mutation needs a fresh current GET');
    assert.equal(s.get('ps-argon-css-status').textContent, 'CSS status unknown');
    assert.equal(s.get('ps-argon-status').querySelectorAll('*').find(el => el.tagName === 'PRE').textContent, details);
    s.get('ps-argon-save').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
{
    const s = setup('argon', typographyUrls);
    s.last('/typography').reply({ settings: { ...typographySettings, font_family: '' }, stale: false, settings_source: 'uci', config_missing: false });
    assert.equal(s.get('ps-argon-save').disabled, false);
    assert.equal(s.get('ps-font-family').value, '', 'native empty family is retained as a theme default, not replaced by Google Sans');
    s.get('ps-argon-save').click();
    assert.equal(new URLSearchParams(s.last('/typography/save').body).get('font_family'), '');
}

// Appearance keeps a successful current read after a definitive refusal, but
// disk-applied/unknown finishing needs another explicit read. None of the three
// mutation callbacks may reconstruct that distinction from XHR text.
for (const [control, endpoint] of [['ps-appearance-save', '/appearance/save'], ['ps-appearance-reset', '/appearance/reset'], ['ps-colors-reset', '/appearance/colors']]) {
    for (const outcome of [{ applied: false }, { applied: true, partial: true, uci_saved: true }, { applied: false, unknown: true }]) {
        const s = appearanceForm(), failures = retainErrorBodies(s);
        s.last('/appearance').reply({ settings: currentAppearance, settings_source: 'uci', config_missing: false });
        s.get('ps-mono-size').value = '18'; s.get('ps-mono-size').dispatch('input');
        s.get('ps-color-success-dark-hex').value = '#112233'; s.get('ps-color-success-dark-hex').dispatch('input');
        s.get(control).click();
        const details = '<script>literal checked UCI result</script>\n' + 'complete appearance diagnostics\n'.repeat(100);
        const body = { success: false, ...outcome, error: 'Appearance finishing failed', details };
        s.last(endpoint).reply(body);
        assertRetainedBody(failures, body);
        assert.equal(preText(s.get('ps-appearance-status')), details);
        const gated = outcome.applied === true || outcome.unknown === true;
        for (const id of ['ps-appearance-save', 'ps-appearance-reset', 'ps-colors-reset']) assert.equal(s.get(id).disabled, gated);
        assert.equal(s.get('root').style['--ps-mono-size'], '18px');
        assert.equal(s.get('root').style['--ps-success-dark'], '#112233', 'a failed mutation never replaces the live selected preview with defaults');
        s.tick(60000);
        assert.equal(s.reloads(), 0);
        assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'finishing failures never replay appearance mutations');
        if (gated) {
            s.get(control).dispatch('click');
            assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
            s.get('ps-appearance-retry').click();
            assert.equal(s.last('/appearance').method, 'GET');
        }
    }
}

function fragmentForm() {
    const s = setup('singbox', singboxUrls);
    s.last('/wrapper/status').reply({ installed: false, stale: false });
    s.get('ps-wrapper-btn').click();
    assert.equal(s.get('ps-wrapper-modal').style.display, 'flex');
    return s;
}
for (const failure of [...formReadFailures,
    ...[{ fragment: 'false', record_fragment: true, fallback_delay: '500ms' },
        { fragment: false, record_fragment: 'true', fallback_delay: '500ms' },
        { fragment: false, record_fragment: true, fallback_delay: {} },
        { fragment: false, record_fragment: true, fallback_delay: '' },
        { fragment: false, record_fragment: true, fallback_delay: '500ms', success: 'true' },
        { fragment: false, record_fragment: true, fallback_delay: '500ms', unknown: true },
        { fragment: false, record_fragment: true, fallback_delay: '500ms', error: 'Cannot read current file' }]
        .map(data => ({ name: JSON.stringify(data), run: r => r.reply(data) }))]) {
    const s = fragmentForm(), read = s.last('/fragment/settings');
    assert.equal(read.timeout, 30000);
    s.get('ps-wrapper-confirm').dispatch('click');
    failure.run(read);
    assert.equal(s.get('ps-wrapper-confirm').disabled, true, failure.name);
    s.get('ps-wrapper-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0, 'failed/pending Fragment GET cannot enable: ' + failure.name);
    s.get('ps-wrapper-retry').click();
    const retry = s.last('/fragment/settings'); assert.notEqual(retry, read);
    retry.reply({ fragment: true, record_fragment: false, fallback_delay: '900ms' });
    assert.equal(s.get('ps-wrapper-confirm').disabled, false);
    assert.equal(s.get('ps-wrap-fragment').checked, true);
    assert.equal(s.get('ps-wrap-record-fragment').checked, false);
    assert.equal(s.get('ps-wrap-fallback-delay').value, '900ms');
    s.get('ps-wrapper-confirm').click();
    const params = new URLSearchParams(s.last('/wrapper/toggle').body);
    assert.deepEqual(Object.fromEntries(params), { token: 'token', action: 'enable', fragment: '1', record_fragment: '0', fallback_delay: '900ms' });
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'only an explicit Enable after valid retry mutates');
}
{
    const s = fragmentForm(); s.last('/fragment/settings').reply({ fragment: false, record_fragment: true, fallback_delay: '500ms', settings_source: 'defaults', config_missing: true });
    s.get('ps-wrapper-confirm').click();
    s.last('/wrapper/toggle').reply({ success: false, settings_saved: true, error: 'Wrapper command failed', details: '<script>literal init error</script>' });
    assert.match(s.get('ps-wrapper-modal-status').textContent, /Fragment settings saved; wrapper finishing failed/);
    assert.equal(s.get('ps-wrapper-confirm').disabled, true);
    s.get('ps-wrapper-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
for (const status of [200, 503]) {
    const s = fragmentForm(), failures = retainErrorBodies(s);
    s.last('/fragment/settings').reply({ fragment: true, record_fragment: false, fallback_delay: '900ms' });
    s.get('ps-wrapper-confirm').click();
    const details = '<script>literal wrapper stderr</script>\n' + 'complete wrapper command output\n'.repeat(100);
    const body = { success: false, settings_saved: true, error: 'Wrapper command failed after saving settings', details };
    s.last('/wrapper/toggle').reply(body, status);
    assertRetainedBody(failures, body);
    assert.match(s.get('ps-wrapper-modal-status').textContent, /Fragment settings saved; wrapper finishing failed/);
    assert.equal(preText(s.get('ps-wrapper-modal-status')), details);
    assert.equal(s.get('ps-wrapper-confirm').disabled, true);
    s.get('ps-wrapper-confirm').dispatch('click');
    s.last('/wrapper/status').reply({ installed: false, stale: false });
    s.tick(60000);
    assert.equal(s.get('ps-wrapper-modal').style.display, 'flex', 'failed finishing cannot schedule a successful modal close');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
for (const action of ['disable', 'reinstall']) {
    const s = setup('singbox', singboxUrls);
    s.last('/wrapper/status').reply({ installed: true, stale: action === 'reinstall' });
    s.get('ps-wrapper-btn').click();
    assert.equal(s.last('/wrapper/toggle').body, 'token=token&action=' + action);
    s.last('/wrapper/toggle').reply({ success: false, error: 'Checked wrapper command failed', details: '<script>literal complete command error</script>' });
    assert.equal(s.get('ps-wrapper-btn').textContent, 'Retry Wrapper Status');
    assert.equal(preText(s.get('ps-wrapper-status')), '<script>literal complete command error</script>');
    s.get('ps-wrapper-btn').click();
    assert.equal(s.last('/wrapper/status').method, 'GET');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'wrapper retry reads facts rather than replaying a mutation');
}
{
    const s = fragmentForm(), stale = s.last('/fragment/settings');
    s.escape();
    s.get('ps-wrapper-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0);
    s.get('ps-wrapper-btn').click();
    const current = s.last('/fragment/settings');
    current.reply({ fragment: false, record_fragment: true, fallback_delay: '500ms' });
    stale.reply({ fragment: true, record_fragment: false, fallback_delay: '9s' });
    assert.equal(s.get('ps-wrap-fragment').checked, false, 'closed/reopened modal ignores the previous GET');
    assert.equal(s.get('ps-wrap-fallback-delay').value, '500ms');
    s.escape();
    assert.equal(s.get('ps-wrapper-confirm').disabled, true, 'closing clears the read-dependent Enable capability');
}

const invalidOutbounds = [null, [], {}, { outbounds: [] }, { outbound_count: '0', outbounds: [] }, { outbound_count: 0, outbounds: [], success: 'true' },
    { outbound_count: 0, outbounds: {}, unknown: true },
    { outbound_count: -1, outbounds: [] }, { outbound_count: 1.5, outbounds: [] },
    { outbound_count: 0, outbounds: { error: 'not an empty container' } }, { outbound_count: 0, outbounds: null },
    { outbound_count: 1, outbounds: {} }, { outbound_count: 2, outbounds: [typedOutbound] },
    { outbound_count: 1, outbounds: [null] }, { outbound_count: 1, outbounds: [{ ...typedOutbound, tls_enabled: 'true' }] },
    { outbound_count: 1, outbounds: [{ ...typedOutbound, error: 'Enumeration failed for this entry' }] },
    { outbound_count: 1, outbounds: [{ ...typedOutbound, server: {} }] },
    { outbound_count: 1, outbounds: [{ ...typedOutbound, has_fragment: 1 }] },
    { outbound_count: 1, outbounds: [{ ...typedOutbound, tls_enabled: false, tag: null }] },
    { outbound_count: 1, outbounds: [{ ...typedOutbound, tag: 'proxy%invalid' }] },
    { outbound_count: 1, outbounds: [{ ...typedOutbound, tag: '\" onclick=literal()' }] },
    { outbound_count: 0, outbounds: {}, error: 'jq could not enumerate outbounds', details: '<script>literal jq stderr</script>\n' + 'complete jq output\n'.repeat(100) }];
for (const failure of [...formReadFailures, ...invalidOutbounds.map(data => ({ name: JSON.stringify(data), run: r => r.reply(data) }))]) {
    const s = setup('singbox', singboxUrls);
    s.get('ps-patch-btn').click();
    const read = s.last('/outbounds');
    s.get('ps-patch-apply').dispatch('click');
    failure.run(read);
    for (const id of ['ps-patch-apply', 'ps-patch-remove', 'ps-patch-select-all']) {
        assert.equal(s.get(id).disabled, true, failure.name);
        s.get(id).dispatch('click');
    }
    assert.doesNotMatch(s.get('ps-patch-list').textContent, /No TLS outbounds/);
    assert.match(s.get('ps-patch-list').textContent, /unavailable.*retry/i);
    assert.ok(s.get('ps-patch-status').textContent, 'an explicit plain-text error is visible');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0);
    s.get('ps-patch-retry').click();
    s.last('/outbounds').reply({ outbound_count: 1, outbounds: [typedOutbound] });
    assert.equal(s.get('ps-patch-apply').disabled, false, 'valid explicit retry unlocks current typed outbounds');
    const html = s.get('ps-patch-list').innerHTML;
    assert.match(html, /&lt;img src=x onerror=literal\(\)&gt;/);
    assert.doesNotMatch(html, /<img|<script/);
}
for (const outbounds of [[], {}, [{ tag: '', type: 'direct', server: '', tls_enabled: false, has_fragment: false }], [{ tag: 'direct', type: 'direct', server: '', tls_enabled: false, has_fragment: false }]]) {
    const s = setup('singbox', singboxUrls); s.get('ps-patch-btn').click();
    s.last('/outbounds').reply({ outbound_count: Array.isArray(outbounds) ? outbounds.length : 0, outbounds });
    assert.equal(s.get('ps-patch-list').textContent, 'No TLS outbounds found.', 'valid empty/non-TLS result is distinct from a failed read');
    assert.equal(s.get('ps-patch-status').textContent, '');
    assert.equal(s.get('ps-patch-apply').disabled, true);
    assert.equal(s.get('ps-patch-apply').style.display, 'none');
}

// The real editor/toggle wiring must not dispatch Start/Stop from an error's
// false running flag or from a forged button caption.
{
    const s = setup('singbox', singboxUrls);
    s.last('/status').reply({ error: 'Process query failed', running: false });
    assert.equal(s.get('ps-status-text').textContent, 'Unknown');
    s.get('ps-toggle-btn').textContent = 'Start'; s.get('ps-toggle-btn').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 0);
}
{
    const s = setup('singbox', singboxUrls);
    s.last('/status').reply({ running: false });
    s.get('ps-toggle-btn').click();
    assert.equal(s.last('/toggle').body, 'token=token&action=start');
    s.last('/toggle').reply({ success: false, error: 'Init command failed', details: '<script>literal service output</script>' });
    assert.match(s.get('ps-config-status').textContent, /Service command failed or is unverified/);
    assert.equal(s.get('ps-toggle-btn').disabled, true, 'command failure waits for a fresh known observation');
    s.last('/status').reply({ error: 'Query still unavailable' });
    s.get('ps-toggle-btn').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
for (const applied of [false, true]) {
    const s = setup('singbox', singboxUrls), initialRead = s.last('/read');
    s.last('/status').reply({ running: false }); s.get('ps-toggle-btn').click();
    s.last('/toggle').reply({ success: false, unknown: true, ...(applied ? { applied: true } : {}), error: 'Cannot release service lock' });
    s.last('/status').reply({ running: true, pid: '42', instance: '42:101' });
    initialRead.reply('{"stale":"before toggle"}');
    assert.equal(s.get('ps-toggle-btn').disabled, true, 'a known current status cannot turn an unknown command into a confirmed result');
    assert.match(s.get('ps-config-status').textContent, /Service command result unknown/);
    s.get('ps-toggle-btn').dispatch('click'); s.get('ps-config-save').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'stale pre-command config GET cannot unlock another mutation');
}
{
    const s = setup('singbox', singboxUrls);
    s.last('/status').reply({ running: false }); s.get('ps-toggle-btn').click();
    s.last('/toggle').reply({ error: 'Server failed without an operation outcome' }, 500);
    s.last('/status').reply({ running: false });
    assert.equal(s.get('ps-toggle-btn').disabled, true);
    assert.match(s.get('ps-config-status').textContent, /Service command result unknown/);
    s.get('ps-toggle-btn').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
{
    const s = setup('singbox', singboxUrls);
    s.last('/read').reply('{"original":true}');
    s.last('/status').reply({ running: true, pid: '42', instance: '42:100' });
    s.get('ps-config-editor').value = '{"sent":"A"}'; s.get('ps-config-editor').dispatch('input');
    s.get('ps-config-save').click();
    s.last('/save').reply({ success: true, restarting: true, verification_required: true,
        previous_running: true, previous_identity_known: true, previous_instance: '42:100' });
    s.get('ps-config-editor').value = '{"draft":"B"}'; s.get('ps-config-editor').dispatch('input');
    s.tick(2000); s.last('/status').reply({ running: true, pid: '42', instance: '42:100' });
    assert.equal(s.get('ps-config-save').disabled, true, 'the real editor stays pending on the old instance');
    assert.doesNotMatch(s.get('ps-config-status').textContent, /sing-box restarted/);
    s.tick(2000); s.last('/status').reply({ running: true, pid: '42', instance: '42:101' });
    assert.equal(s.get('ps-config-save').disabled, false);
    assert.equal(s.get('ps-config-editor').value, '{"draft":"B"}');
    assert.match(s.get('ps-config-status').textContent, /sing-box restarted.*unsaved changes remain/);
    s.get('ps-config-undo').click();
    assert.equal(s.get('ps-config-editor').value, '{"sent":"A"}', 'the real poll completes against the sent disk baseline');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}

// A failed settings GET cannot turn a display preference into a schedule overwrite.
{
    const s = subscriptions();
    s.last('/settings').onerror();
    s.get('ps-log-display-count').value = '15';
    s.get('ps-log-settings-save').click();
    const save = s.last('/settings/save');
    assert.equal(save.body, 'token=token&log_only=1&log_display_count=15');
    assert.equal(s.requests.filter(r => r.url === '/settings').length, 1);
    assert.equal(s.get('ps-log-settings-save').disabled, true);
    save.reply({ success: true });
    assert.equal(s.get('ps-log-settings-save').disabled, false);
    assert.match(s.get('ps-log-settings-status').textContent, /Saved/);
}

// Definitive refusal frees controls; lost/malformed mutation ACKs stay unknown
// and permit read-only inspection without replaying Update All.
for (const failure of ['network', 'timeout', 'null', '[]', '{}', 'html', 'internal', 'http500', '403']) {
    const s = subscriptions(); s.get('ps-subs-update-all').click();
    const request = s.last('/all');
    assert.equal(s.get('ps-subs-update-all').disabled, true);
    if (failure === 'network') request.onerror();
    else if (failure === 'timeout') request.ontimeout();
    else if (failure === 'internal') request.reply({ error: 'Internal error' });
    else if (failure === 'http500') request.reply({ error: 'Server handler failed without an operation outcome' }, 500);
    else request.reply(failure === 'html' || failure === '403' ? '<html>LuCI login</html>' : failure, failure === '403' ? 403 : 200);
    assert.equal(s.get('ps-subs-update-all').disabled, failure !== '403', failure);
    assert.match(s.get('ps-global-status').textContent, failure === '403' ? /HTTP error: 403/ : /result unknown/i, failure);
    s.get('ps-subs-update-all').click();
    assert.equal(s.requests.filter(r => r.url === '/all').length, failure === '403' ? 2 : 1, 'only a definitive refusal permits a new explicit update');
    if (failure !== '403') {
        s.get('ps-subs-refresh').click();
        assert.equal(s.last('/state').method, 'GET');
        s.last('/state').reply({ sections: [] });
        assert.equal(s.get('ps-subs-update-all').disabled, true, 'a current read is not evidence of completion of the lost operation');
        assert.equal(s.requests.filter(r => r.url === '/all').length, 1);
    }
}

const serviceAck = (previous = '42:100') => ({ success: true, restarting: true, verification_required: true,
    previous_running: true, previous_identity_known: true, previous_instance: previous });
const processStatus = identity => ({ running: true, pid: identity.split(':')[0], instance: identity });
const updateCounts = { updated: 1, unchanged: 2, failed: 0, skipped: 1 };
function preText(el) { return el.querySelectorAll('*').filter(child => child.tagName === 'PRE').map(child => child.textContent).join('\n'); }
function slotUpdate(s) {
    const button = s.button('ps-sub-btn-update');
    s.get('ps-subs-content').dispatch('click', { target: button });
    s.last('/fetch').reply({ success: true, proxies: [{ name: 'Current proxy', link: 'vless://fixture@proxy.test:443' }] });
    return button;
}
function openSubscription(s, section = 'main', index = 0) {
    const button = s.button('ps-sub-btn-attach', section, index);
    s.get('ps-subs-content').dispatch('click', { target: button });
    assert.equal(s.get('ps-sub-modal').style.display, 'flex');
    return button;
}
function fetchSubscription(s, url = 'https://sub.test') {
    s.get('ps-sub-url').value = url; s.get('ps-sub-fetch-btn').click();
    const request = s.last('/fetch');
    assert.equal(new URLSearchParams(request.body).get('url'), url);
    return request;
}
function modalAttachment(s) {
    const button = openSubscription(s), choice = s.get('selected-proxy');
    choice.setAttribute('data-idx', '0'); s.get('ps-sub-proxy-list').buttons = [choice];
    fetchSubscription(s).reply({ success: true, proxies: [{ name: 'Selected', link: 'vless://fixture@proxy.test:443' }] });
    choice.click();
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 1);
    return { button, post: s.last('/attach') };
}

// A restart command ACK is not an observed process transition, including the
// old `restarted` subscription field. Keep all counts and slot outcomes visible.
{
    const s = subscriptions(); s.get('ps-subs-update-all').click();
    const stateReads = s.requests.filter(r => r.url === '/state').length, logReads = s.requests.filter(r => r.url === '/log').length;
    s.last('/all').reply({ ...serviceAck(), ...updateCounts, restarted: true, applied: true,
        outcomes: [{ section: 'main', slot: 0, status: 'updated' }, { section: 'other', slot: 1, status: 'skipped', reason: 'Association changed during download' }] });
    assert.match(s.get('ps-global-status').textContent, /1 updated, 2 unchanged, 0 failed, 1 skipped/);
    assert.match(preText(s.get('ps-global-status')), /Association changed during download/);
    assert.equal(s.requests.filter(r => r.url === '/state').length, stateReads + 1);
    assert.equal(s.requests.filter(r => r.url === '/log').length, logReads + 1, 'read current state/log as soon as the mutation ACK is received');
    s.tick(2000); s.last('/service').reply(processStatus('42:100'));
    assert.equal(s.get('ps-subs-update-all').disabled, true, 'old worker keeps verification pending');
    assert.doesNotMatch(s.get('ps-global-status').textContent, /new service process instance/);
    s.tick(2000); s.last('/service').reply(processStatus('42:101'));
    assert.equal(s.get('ps-subs-update-all').disabled, false);
    assert.match(s.get('ps-global-status').textContent, /new service process instance/);
    assert.match(s.get('ps-global-status').textContent, /1 skipped/);
    assert.equal(s.requests.filter(r => r.url === '/all').length, 1);
}
for (const status of [200, 503]) for (const result of [
    { success: false, error: 'Cannot save final subscription state', applied: true, restart_required: true },
    { success: false, error: 'Service restart command failed', applied: true, restart_required: true, verification_required: true, previous_running: true, previous_identity_known: true, previous_instance: '42:100' }
]) {
    const s = subscriptions(), failures = retainErrorBodies(s); s.get('ps-subs-update-all').click();
    const details = '<script>complete literal failure</script>\n' + 'full operation diagnostics\n'.repeat(100);
    const outcomes = [{ section: 'main', slot: 0, proxy: 'plain <img> name', status: 'failed', error: 'State write failed after config publication' }];
    const body = { ...result, updated: 1, unchanged: 0, failed: 1, skipped: 2, restarted: false, details, outcomes };
    s.last('/all').reply(body, status);
    assertRetainedBody(failures, body);
    assert.match(s.get('ps-global-status').textContent, /Partial result: 1 updated, 0 unchanged, 1 failed, 2 skipped/);
    assert.match(s.get('ps-global-status').textContent, /restart is still required/);
    assert.ok(preText(s.get('ps-global-status')).includes(details));
    assert.ok(preText(s.get('ps-global-status')).includes(JSON.stringify(outcomes, null, 2)));
    assert.equal(s.get('ps-subs-update-all').disabled, false, 'known partial failure frees mutation controls');
    assert.equal(s.requests.filter(r => r.url === '/service').length, 0, 'a failed restart command is not promoted to a successful restart');
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
    s.last('/state').reply({ error: 'Readback unavailable' }, 500);
    assert.match(s.get('ps-global-status').textContent, /Partial result: 1 updated.*Cannot refresh sections/);
    assert.ok(preText(s.get('ps-global-status')).includes(details), 'readback errors cannot discard the received partial outcome');
    s.get('ps-subs-refresh').click(); s.last('/state').reply({ sections: [] });
    assert.match(s.get('ps-global-status').textContent, /Partial result: 1 updated/);
    assert.doesNotMatch(s.get('ps-global-status').textContent, /Cannot refresh sections/);
    s.tick(60000);
    assert.equal(s.requests.filter(r => r.url === '/all').length, 1, 'no automatic replay after a disk-applied failure');
}
for (const metadata of [{}, { verification_required: true, previous_running: false, previous_identity_known: false }]) {
    const s = subscriptions(); s.get('ps-subs-update-all').click();
    s.last('/all').reply({ success: true, restarted: true, ...updateCounts, ...metadata });
    for (let i = 0; i < 8; i++) { s.tick(2000); s.last('/service').reply(processStatus('42:100')); }
    assert.equal(s.get('ps-subs-update-all').disabled, false, 'known disk result frees controls after bounded unverified service polling');
    assert.match(s.get('ps-global-status').textContent, /running, but restart is unconfirmed/);
    assert.doesNotMatch(s.get('ps-global-status').textContent, /did not start|new service process instance/);
    assert.equal(s.requests.filter(r => r.url === '/all').length, 1);
}
{
    const s = subscriptions(); s.get('ps-subs-update-all').click();
    s.last('/all').reply({ success: false, unknown: true, applied: true, restart_required: true,
        updated: 1, unchanged: 0, failed: 1, skipped: 0, error: 'Owned lock release outcome unknown' });
    assert.match(s.get('ps-global-status').textContent, /Partial result; finishing unknown: 1 updated, 0 unchanged, 1 failed, 0 skipped/);
    assert.equal(s.get('ps-subs-update-all').disabled, true, 'explicit backend uncertainty retains the mutation gate');
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
    s.get('ps-subs-update-all').dispatch('click');
    assert.equal(s.requests.filter(r => r.url === '/all').length, 1);
}
{
    const s = subscriptions(), button = slotUpdate(s);
    s.last('/attach').reply({ ...serviceAck(), applied: true });
    s.tick(2000); s.last('/service').reply(processStatus('42:100'));
    assert.equal(button.disabled, true);
    s.tick(2000); s.last('/service').reply(processStatus('42:101'));
    assert.equal(button.disabled, false);
    assert.match(s.get('ps-slot-status-main-0').textContent, /new service process instance/);
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 1);
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
}
{
    const s = subscriptions(), button = slotUpdate(s);
    s.last('/attach').reply({ success: false, applied: true, restart_required: true, error: 'State commit failed', details: '<script>literal state failure</script>' });
    assert.equal(button.disabled, false);
    assert.match(s.get('ps-slot-status-main-0').textContent, /Partially applied/);
    assert.match(s.get('ps-global-status').textContent, /restart is still required/);
    assert.ok(preText(s.get('ps-slot-status-main-0')).endsWith('State commit failed\n\n<script>literal state failure</script>'));
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 1);
}
{
    const s = subscriptions(), button = s.button('ps-sub-btn-detach');
    s.get('ps-subs-content').dispatch('click', { target: button });
    s.last('/detach').reply({ success: false, applied: true, error: 'State publication finished, but lock cleanup failed', details: '<script>literal cleanup error</script>' });
    assert.equal(button.disabled, false);
    assert.match(s.get('ps-slot-status-main-0').textContent, /Detach was applied, but finishing failed/);
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/detach').length, 1);
}
{
    const s = subscriptions(), button = s.button('ps-sub-btn-attach'), choice = s.get('proxy-choice');
    choice.setAttribute('data-idx', '0'); s.get('ps-sub-proxy-list').buttons = [choice];
    s.get('ps-subs-content').dispatch('click', { target: button });
    s.get('ps-sub-url').value = 'https://sub.test'; s.get('ps-sub-fetch-btn').click();
    s.last('/fetch').reply({ success: true, proxies: [{ name: 'Selected', link: 'vless://fixture@proxy.test:443' }] });
    choice.click();
    s.last('/attach').reply({ ...serviceAck(), applied: true });
    assert.equal(s.get('ps-sub-modal').style.display, 'none');
    s.tick(2000); s.last('/service').reply(processStatus('42:100'));
    assert.equal(button.disabled, true, 'modal attach passes the same pre-command generation context');
    s.tick(2000); s.last('/service').reply(processStatus('42:101'));
    assert.equal(button.disabled, false);
    assert.match(s.get('ps-global-status').textContent, /new service process instance/);
}
{
    const s = subscriptions(); s.get('ps-sub-url').value = 'https://sub.test'; s.get('ps-sub-fetch-btn').click();
    s.last('/fetch').onerror();
    assert.equal(s.get('ps-sub-fetch-btn').disabled, false);
    assert.match(s.get('ps-sub-fetch-status').textContent, /Network error/);
    s.get('ps-sub-fetch-btn').click(); s.last('/fetch').reply({ success: true, proxies: [null] });
    assert.match(s.get('ps-sub-fetch-status').textContent, /Invalid response/);
}
{
    const s = subscriptions(), btn = s.button('ps-sub-btn-detach');
    s.get('ps-subs-content').dispatch('click', { target: btn });
    assert.equal(btn.disabled, true);
    s.get('ps-subs-content').dispatch('click', { target: btn });
    assert.equal(s.requests.filter(r => r.url === '/detach').length, 1, 'no overlapping mutation');
    const reads = s.requests.filter(r => r.url === '/state').length;
    s.last('/detach').reply({ error: 'Failed to save data' });
    assert.equal(btn.disabled, false);
    assert.equal(s.requests.filter(r => r.url === '/state').length, reads, 'failed Detach is not reported as success');
    assert.match(s.get('ps-slot-status-main-0').textContent, /Failed to save data/);
}
{
    const s = subscriptions();
    s.last('/auto/status').reply({ cron: { enabled: true, matches: false, running: false, expected: '<script>literal</script>' },
        launcher: { matches: false }, hotplug: { enabled: false, exists: true }, last_auto: { ts: '12:00 09.10.2026', updated: 0, unchanged: 2, failed: 1 } });
    const html = s.get('ps-auto-status').innerHTML;
    assert.match(html, /Missing or different cron entry/);
    assert.match(html, /scheduled checks cannot start/);
    assert.match(html, /failed=1/);
    assert.match(html, /&lt;script&gt;literal&lt;\/script&gt;/);
    assert.doesNotMatch(html, /<script>/);
}
{
    const s = subscriptions(), button = s.button('ps-sub-btn-attach');
    s.get('ps-subs-content').dispatch('click', { target: button });
    assert.equal(s.get('ps-sub-modal').style.display, 'flex');
    const posts = s.requests.filter(request => request.method === 'POST').length;
    s.escape();
    assert.equal(s.get('ps-sub-modal').style.display, 'none');
    assert.equal(s.requests.filter(request => request.method === 'POST').length, posts);
}

// A typed unknown body retains disk facts, complete counts/outcomes and prior
// process metadata without converting applied=false into a saved configuration.
for (const action of ['attach', 'detach', 'all']) for (const applied of [false, true]) {
    const s = subscriptions(), failures = retainErrorBodies(s);
    let button;
    if (action === 'attach') button = slotUpdate(s);
    else if (action === 'detach') {
        button = s.button('ps-sub-btn-detach');
        s.get('ps-subs-content').dispatch('click', { target: button });
    } else s.get('ps-subs-update-all').click();
    const details = '<script>literal uncertain finishing</script>\n' + 'full owned lock diagnostics\n'.repeat(100);
    const outcomes = [{ section: 'main', slot: 0, status: 'failed', applied, error: 'Final state cleanup unknown' }];
    const body = { success: false, applied, unknown: true, partial: applied, restart_required: applied,
        verification_required: true, previous_running: true, previous_identity_known: true, previous_instance: '42:100',
        error: 'Owned lock release outcome unknown', details, outcomes,
        ...(action === 'all' ? { updated: applied ? 1 : 0, unchanged: 2, failed: 1, skipped: 3 } : {}) };
    s.last('/' + action).reply(body);
    assertRetainedBody(failures, body);
    const notice = s.get(action === 'all' ? 'ps-global-status' : 'ps-slot-status-main-0');
    assert.match(notice.textContent, /unknown/i);
    if (action === 'all') assert.match(notice.textContent, applied ? /Partial result; finishing unknown: 1 updated, 2 unchanged, 1 failed, 3 skipped/ : /Update result unknown: 0 updated, 2 unchanged, 1 failed, 3 skipped/);
    else if (applied) assert.match(notice.textContent, action === 'attach' ? /Changes saved, but finishing result unknown/ : /Detach applied; finishing result unknown/);
    else assert.doesNotMatch(notice.textContent, /Changes saved|Detach applied|Partially applied/);
    assert.ok(preText(notice).includes(details));
    assert.ok(preText(notice).includes(JSON.stringify(outcomes, null, 2)));
    assert.equal(s.get('ps-subs-update-all').disabled, true);
    if (button) assert.equal(button.disabled, true);
    s.get('ps-subs-update-all').dispatch('click');
    if (button) s.get('ps-subs-content').dispatch('click', { target: button });
    s.tick(60000);
    assert.equal(s.requests.filter(r => r.url === '/' + action).length, 1);
    assert.equal(s.requests.filter(r => r.url === '/service').length, 0, 'unknown finishing is never promoted to restart verification');
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
}

const lateFetches = [
    { name: 'success', complete: request => request.reply({ success: true, proxies: [{ name: 'OLD proxy', link: 'vless://old@proxy.test:443' }] }) },
    { name: 'application failure', complete: request => request.reply({ success: false, error: 'OLD subscription failed', details: '<script>old fetch error</script>' }) },
    { name: 'network failure', complete: request => request.onerror() }
];
for (const late of lateFetches) for (const oldFirst of [true, false]) {
    const s = subscriptions(); openSubscription(s);
    const old = fetchSubscription(s, 'https://old-sub.test');
    s.escape();
    openSubscription(s, 'other', 1);
    const choice = s.get('current-proxy'); choice.setAttribute('data-idx', '0');
    s.get('ps-sub-proxy-list').buttons = [choice];
    const current = fetchSubscription(s, 'https://current-sub.test');
    if (oldFirst) {
        late.complete(old);
        assert.equal(s.get('ps-sub-fetch-btn').disabled, true, late.name + ': an old Fetch cannot finish the current request');
        assert.equal(s.get('ps-sub-fetch-btn').textContent, 'Fetching...');
        assert.equal(s.get('ps-sub-fetch-status').textContent, 'Downloading...');
        assert.equal(s.get('ps-sub-proxies').style.display, 'none');
        assert.equal(s.get('ps-sub-proxy-list').innerHTML, '');
    }
    current.reply({ success: true, proxies: [{ name: 'CURRENT proxy', link: 'vless://current@proxy.test:443' }] });
    const html = s.get('ps-sub-proxy-list').innerHTML, status = s.get('ps-sub-fetch-status').textContent;
    if (!oldFirst) late.complete(old);
    assert.equal(s.get('ps-sub-modal').style.display, 'flex');
    assert.equal(s.get('ps-sub-fetch-btn').disabled, false);
    assert.equal(s.get('ps-sub-fetch-status').textContent, status, late.name + ': a stale completion cannot replace current results');
    assert.equal(s.get('ps-sub-proxy-list').innerHTML, html);
    assert.match(html, /CURRENT proxy/); assert.doesNotMatch(html, /OLD proxy/);
    choice.click();
    const params = new URLSearchParams(s.last('/attach').body);
    assert.equal(params.get('section'), 'other'); assert.equal(params.get('index'), '1');
    assert.equal(params.get('subscription_url'), 'https://current-sub.test');
    assert.equal(params.get('link'), 'vless://current@proxy.test:443', 'a later opening cannot attach an old Fetch result');
    s.last('/attach').reply({ success: true, unchanged: true });
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 1);
}
for (const close of ['cancel', 'backdrop']) for (const late of lateFetches) {
    const s = subscriptions(); openSubscription(s);
    const old = fetchSubscription(s);
    if (close === 'cancel') s.get('ps-sub-cancel').click(); else s.get('ps-sub-modal').dispatch('click');
    const status = s.get('ps-sub-fetch-status').textContent;
    late.complete(old);
    assert.equal(s.get('ps-sub-modal').style.display, 'none');
    assert.equal(s.get('ps-sub-proxies').style.display, 'none');
    assert.equal(s.get('ps-sub-proxy-list').innerHTML, '');
    assert.equal(s.get('ps-sub-fetch-status').textContent, status, close + ': closed Fetch callbacks have no presentation ownership');
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 0);
}
for (const leaveOpen of [false, true]) {
    const s = subscriptions(), button = s.button('ps-sub-btn-update');
    s.get('ps-subs-content').dispatch('click', { target: button });
    const old = s.last('/fetch');
    const currentButton = openSubscription(s, 'other', 1);
    s.get('ps-subs-content').buttons = [button, currentButton];
    const current = fetchSubscription(s, 'https://current-sub.test');
    if (!leaveOpen) s.escape();
    const status = s.get('ps-sub-fetch-status').textContent;
    old.reply({ success: true, proxies: [{ name: 'First alternative', link: 'vless://first@test:443' }, { name: 'Second alternative', link: 'vless://second@test:443' }] });
    assert.equal(s.get('ps-sub-modal').style.display, leaveOpen ? 'flex' : 'none', 'old per-slot Fetch cannot force a proxy-picker opening');
    assert.equal(s.get('ps-sub-url').value, 'https://current-sub.test');
    assert.equal(s.get('ps-sub-proxy-list').innerHTML, '');
    assert.equal(s.get('ps-sub-fetch-status').textContent, status);
    assert.equal(s.get('ps-sub-fetch-btn').disabled, leaveOpen);
    assert.equal(button.disabled, false, 'the old read still releases its owned slot gate');
    assert.match(s.get('ps-slot-status-main-0').textContent, /Use Change to select/);
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 0);
    current.reply({ success: true, proxies: [] });
}

// Hiding only revokes modal presentation. The sent Attach and its process
// watcher still own the original slot and complete outside any later opening.
for (const hideBeforeAck of [false, true]) {
    const s = subscriptions(), { button, post } = modalAttachment(s);
    let currentButton, current;
    function reopen() {
        currentButton = openSubscription(s, 'other', 1);
        s.get('ps-subs-content').buttons = [button, currentButton];
        current = fetchSubscription(s, 'https://current-sub.test');
    }
    if (hideBeforeAck) { s.escape(); reopen(); }
    post.reply({ ...serviceAck(), applied: true });
    if (!hideBeforeAck) { assert.equal(s.get('ps-sub-modal').style.display, 'none'); reopen(); }
    assert.equal(s.get('ps-sub-modal').style.display, 'flex', 'an earlier Attach cannot close the later opening');
    assert.equal(s.get('ps-sub-fetch-status').textContent, 'Downloading...');
    s.tick(2000); s.last('/service').reply(processStatus('42:100'));
    assert.equal(button.disabled, true);
    assert.equal(s.get('ps-subs-update-all').disabled, true);
    s.tick(2000); s.last('/service').reply(processStatus('42:101'));
    assert.equal(button.disabled, false);
    assert.equal(s.get('ps-subs-update-all').disabled, false);
    assert.match(s.get('ps-slot-status-main-0').textContent, /new service process instance/);
    assert.match(s.get('ps-global-status').textContent, /new service process instance/);
    assert.equal(s.get('ps-sub-modal').style.display, 'flex');
    assert.equal(s.get('ps-sub-fetch-btn').disabled, true);
    assert.equal(s.get('ps-sub-fetch-status').textContent, 'Downloading...');
    assert.equal(s.requests.filter(r => r.url === '/state').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/log').length, 2);
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 1);
    current.reply({ success: true, proxies: [] });
}
for (const outcome of [{ applied: false }, { applied: true, restart_required: true }, { applied: true, unknown: true }]) {
    const s = subscriptions(), failures = retainErrorBodies(s), { button, post } = modalAttachment(s);
    s.escape();
    const currentButton = openSubscription(s, 'other', 1);
    s.get('ps-subs-content').buttons = [button, currentButton];
    const current = fetchSubscription(s, 'https://current-sub.test');
    const details = '<script>literal Attach result after hide</script>\n' + 'complete Attach finishing output\n'.repeat(100);
    const body = { success: false, ...outcome, error: 'Attach finishing failed after hide', details };
    post.reply(body, 503);
    assertRetainedBody(failures, body);
    assert.equal(button.disabled, outcome.unknown === true);
    assert.equal(s.get('ps-sub-modal').style.display, 'flex');
    assert.equal(s.get('ps-sub-fetch-btn').disabled, true);
    assert.equal(s.get('ps-sub-fetch-status').textContent, 'Downloading...', 'an earlier Attach failure cannot populate a later modal');
    assert.ok(preText(s.get('ps-slot-status-main-0')).includes(details));
    assert.match(s.get('ps-slot-status-main-0').textContent, outcome.unknown ? /finishing result unknown/ : outcome.applied ? /Partially applied/ : /Change failed/);
    s.tick(60000);
    assert.equal(s.requests.filter(r => r.url === '/attach').length, 1);
    current.reply({ success: true, proxies: [] });
}

// Log counters are untrusted strings too. Recent and Full Log must preserve
// their literal content without creating markup, alongside ordinary numeric
// counters and the same detail lines used by the existing copy sources.
{
    const s = subscriptions(); s.get('ps-log-display-count').value = '1';
    s.last('/log').reply({ lines: [
        '17.10.2026 10:00|auto|updated=7|unchanged=8|failed=9',
        '17.10.2026 10:01|manual|updated=<img src=x onerror=literal()>&1|unchanged=<svg onload=literal()>&2|failed=<script>literal()</script>&3',
        '  main[0]: failed <img src=detail> & full literal detail'
    ] });
    assert.equal(s.get('ps-full-log-btn').style.display, '');
    s.get('ps-full-log-btn').click();
    for (const id of ['ps-log-wrap', 'ps-full-log-body']) {
        const html = s.get(id).innerHTML;
        assert.ok(html.includes('updated=&lt;img src=x onerror=literal()&gt;&amp;1'));
        assert.ok(html.includes('unchanged=&lt;svg onload=literal()&gt;&amp;2'));
        assert.ok(html.includes('failed=&lt;script&gt;literal()&lt;/script&gt;&amp;3'));
        assert.ok(html.includes('failed &lt;img src=detail&gt; &amp; full literal detail'));
        assert.doesNotMatch(html, /<img|<svg|<script/);
    }
    assert.doesNotMatch(s.get('ps-log-wrap').innerHTML, /updated=7/);
    assert.match(s.get('ps-full-log-body').innerHTML, /updated=7 unchanged=8 failed=9/);
}

const updateUrls = { upload: '/upload', apply: '/apply', restartStatus: '/restart/status' };
function localUpdate() {
    const s = setup('update', updateUrls);
    s.get('ps-file-input').files = [{ name: 'luci-app-podkop-tweaker-v4.9.0.tar.gz', size: 100000 }];
    s.get('ps-file-input').dispatch('change');
    s.last('/upload').reply({ success: true, current_version: '4.9.0', archive_version: '4.9.0', same_version: true });
    s.get('ps-apply-btn').click();
    return s;
}
function operation(s) { return new URLSearchParams(s.last('/apply').body).get('restart_id'); }
function probe(s) { return s.requests.filter(r => r.url.startsWith('/restart/status?')).at(-1); }
function ready(id) { return { id, state: 'applied', restarted: true, ready: true, expected_version: '4.9.0', installed_version: '4.9.0' }; }
for (const invalid of [
    { id: 'foreign-id' }, { installed_version: '4.8.1' }, { state: 'working' }, { restarted: false }
]) {
    const s = localUpdate(), id = operation(s);
    s.last('/apply').reply({ success: true, restart_id: id, new_version: '4.9.0' });
    probe(s).reply({ ...ready(id), ...invalid });
    assert.equal(s.reloads(), 0, 'incomplete or foreign readiness never triggers reload');
    s.tick(1000); probe(s).reply(ready(id));
    assert.equal(s.reloads(), 1);
}
{
    const s = localUpdate(), id = operation(s);
    s.last('/apply').reply({ success: true, restart_id: id });
    s.events.pagehide();
    probe(s).reply(ready(id)); s.tick(60000);
    assert.equal(s.reloads(), 0, 'leaving a page cancels pending verification and late responses');
}
{
    const s = localUpdate();
    s.last('/apply').reply({ success: false, applied: true, error: 'Cannot record operation result', details: 'write failed' });
    assert.equal(s.reloads(), 0);
    assert.equal(s.get('ps-file-input').disabled, true, 'an applied-but-unconfirmed result must not unlock another mutation');
    const retry = s.get('ps-apply-status').children.find(el => el.tagName === 'BUTTON');
    assert.ok(retry, 'an uncertain result offers read-only verification');
    retry.click();
    assert.equal(s.requests.filter(r => r.url === '/apply').length, 1);
}
{
    const s = localUpdate(), id = operation(s);
    s.last('/apply').reply({ success: true, restart_id: id, new_version: '4.9.0' });
    probe(s).reply({ ...ready(id), restarted: false, ready: false });
    s.tick(1000);
    assert.equal(s.reloads(), 0, 'same version alone is not a reinstall confirmation');
    probe(s).reply(ready(id));
    assert.equal(s.reloads(), 1);
    assert.match(s.window.location.href, new RegExp('_pt_reload=' + id));
    assert.equal(s.requests.filter(r => r.url === '/apply').length, 1);
}
{
    const s = localUpdate(), id = operation(s);
    s.last('/apply').onerror();
    probe(s).reply({ id, state: 'working', ready: false });
    s.tick(1000); probe(s).reply(ready(id));
    assert.equal(s.reloads(), 1, 'response loss is recovered from checked operation evidence');
    assert.equal(s.requests.filter(r => r.url === '/apply').length, 1, 'never retry a mutation automatically');
}
{
    const s = localUpdate(), id = operation(s);
    s.last('/apply').reply({ success: true, restart_id: id });
    s.tick(60000);
    assert.equal(s.reloads(), 0);
    assert.equal(s.get('ps-file-input').disabled, true, 'unknown result keeps mutation locked');
    const retry = s.get('ps-apply-status').children.find(el => el.tagName === 'BUTTON');
    assert.ok(retry); retry.click(); probe(s).reply(ready(id));
    assert.equal(s.reloads(), 1);
    assert.equal(s.requests.filter(r => r.url === '/apply').length, 1);
}
{
    const s = localUpdate(), id = operation(s);
    s.last('/apply').reply({ success: true, restart_id: id });
    probe(s).reply('<html>LuCI login</html>', 403);
    assert.equal(s.reloads(), 0);
    assert.match(s.get('ps-apply-status').textContent, /session expired/i);
    assert.equal(s.get('ps-file-input').disabled, true);
}

const infoUrls = { systemInfo: '/info', tweakerUpdate: '/git', argonThemeUpdate: '/theme', clearCache: '/clear', checkUpdates: '/check', restartStatus: '/restart/status', appVersion: '/version' };
{
    const s = setup('system-info', infoUrls);
    s.last('/info').reply({ tweaker_version: '4.9.0', tweaker_latest: '4.10.0', tweaker_download_url: 'https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.10.0/app.tar.gz' });
    s.get('ps-tweaker-update-btn').click();
    assert.match(s.last('/git').body, /download_url=https%3A%2F%2Fgithub.com/);
    assert.equal(s.requests.filter(r => r.url === '/check').length, 0, 'cached update works without another check');
}
{
    const s = setup('system-info', infoUrls);
    s.last('/info').reply({ tweaker_version: '4.9.0', tweaker_latest: '4.10.0', tweaker_download_url: '' });
    assert.equal(s.get('ps-tweaker-update-btn').disabled, true);
    s.get('ps-clear-cache').click();
    s.last('/clear').reply({ error: 'CSRF token mismatch' }, 403);
    s.tick(10000);
    assert.equal(s.reloads(), 0, 'failed cache POST never schedules a blind reload');
    assert.equal(s.get('ps-clear-cache').disabled, false);
}
for (const lostResponse of [false, true]) {
    const s = setup('system-info', infoUrls);
    s.last('/info').reply({ tweaker_version: '4.9.0', tweaker_latest: '4.8.1', tweaker_download_url: 'https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.8.1/app.tar.gz' });
    s.get('ps-tweaker-downgrade-btn').click();
    const post = s.last('/git'), id = new URLSearchParams(post.body).get('restart_id');
    assert.match(post.body, /force=1/);
    if (lostResponse) post.onerror();
    else post.reply({ success: true, restart_id: id, new_version: '4.8.1' });
    probe(s).reply('Not found', 404);
    s.tick(1000);
    if (lostResponse) {
        assert.equal(s.requests.filter(r => r.url.startsWith('/version')).length, 0, 'old version alone cannot prove a lost/partial downgrade');
        assert.equal(s.reloads(), 0);
    } else {
        for (let i = 0; i < 3; i++) {
            s.requests.filter(r => r.url.startsWith('/version')).at(-1).reply({ version: '4.8.1' });
            if (i < 2) { assert.equal(s.reloads(), 0); s.tick(1000); }
        }
        assert.equal(s.reloads(), 1, 'checked ACK plus stable target readiness supports legacy downgrade');
        assert.match(s.get('ps-tweaker-status').textContent, /legacy verification/);
    }
}

function argonInfo(fields = {}) {
    return { tweaker_version: '4.10.0', argon_theme_version: '3.0.0-r1', argon_theme_latest: '3.0.0-r2',
        argon_theme_update_available: true, argon_theme_resume_available: false, ...fields };
}
function argonPage(fields) {
    const s = setup('system-info', infoUrls);
    s.last('/info').reply(argonInfo(fields));
    return s;
}
function themeOperation(s) { return new URLSearchParams(s.last('/theme').body).get('restart_id'); }
function forceArgon(s, theme) {
    s.get('ps-check-updates').click();
    s.last('/check').reply({ podkop: { update_available: false }, tweaker: { current_version: '4.10.0' }, theme });
}

// APK revisions and equal-theme companion/recovery work are backend decisions.
for (const fields of [
    { argon_theme_version: '2.4.8-r1', argon_theme_latest: '2.4.8-r2' },
    { argon_theme_version: '3.0.0-r2' }, // only an installed locale/compat needs an update
    { argon_theme_version: '3.0.0-r2', argon_theme_update_available: false, argon_theme_resume_available: true, argon_theme_phase: 'css' }
]) {
    const s = argonPage(fields), resume = fields.argon_theme_resume_available === true;
    const html = s.get('ps-info-argon').innerHTML;
    assert.match(html, /id="ps-argon-update-btn"/);
    assert.match(html, resume ? /Resume Theme Update/ : /Update Theme/);
    if (resume) assert.match(html, /phase: css/);
    s.get('ps-argon-update-btn').click();
    const post = s.last('/theme'), id = themeOperation(s);
    assert.match(id, /^[a-f0-9]{32}$/);
    assert.equal(new URLSearchParams(post.body).get('token'), 'token');
    assert.equal(s.get('ps-argon-update-btn').disabled, true);
    assert.equal(s.get('ps-check-updates').disabled, true);
    assert.equal(s.get('ps-refresh-info').disabled, true);
    // No new_version in the ACK: the row's full target is the fallback.
    post.reply({ success: true, restart_id: id });
    const target = fields.argon_theme_latest || '3.0.0-r2';
    probe(s).reply({ id, state: 'applied', restarted: true, ready: true, installed_version: target.replace(/-r\d+$/, '') });
    assert.equal(s.reloads(), 0, 'a semver without the exact APK revision is not ready');
    s.tick(1000);
    probe(s).reply({ id, state: 'applied', restarted: true, ready: true, expected_version: target, installed_version: target });
    assert.equal(s.reloads(), 1);
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 1);
}
{
    const s = argonPage({ argon_theme_update_available: false });
    assert.doesNotMatch(s.get('ps-info-argon').innerHTML, /ps-argon-update-btn/, 'a higher version alone cannot override backend refusal');
    s.get('ps-argon-update-btn').click();
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 0);
}
{
    const s = argonPage({ argon_theme_version: null });
    assert.equal(s.get('ps-row-argon').style.display, 'none');
    assert.equal(s.get('ps-info-argon').textContent, '');
    assert.equal(s.requests.filter(r => r.url === '/check').length, 0);
    forceArgon(s, { current_version: '3.0.0-r2', latest_version: '3.0.0-r2', update_available: true });
    assert.equal(s.get('ps-row-argon').style.display, '', 'force check can discover a newly installed theme');
    assert.match(s.get('ps-info-argon').innerHTML, /Update Theme/);
}
{
    const s = argonPage();
    forceArgon(s, { current_version: '3.0.0-r2', latest_version: '3.0.0-r2', update_available: true,
        resume_available: true, phase: 'translation' });
    assert.match(s.get('ps-info-argon').innerHTML, /^3\.0\.0-r2 /, 'force check replaces the current version as well as the target');
    assert.match(s.get('ps-info-argon').innerHTML, /Resume Theme Update/);
    assert.match(s.get('ps-info-argon').innerHTML, /phase: translation/);
    assert.match(s.get('ps-update-status').textContent, /Argon: resume available/);

    const details = '<script>literal metadata error</script>\n' + 'complete dependency diagnostics\n'.repeat(100);
    forceArgon(s, { current_version: '3.0.0-r2', update_available: false,
        error: 'Cannot verify installed Argon packages', details });
    assert.doesNotMatch(s.get('ps-info-argon').innerHTML, /ps-argon-update-btn/, 'failed refresh removes stale update/resume actions');
    assert.match(s.get('ps-info-argon').textContent, /Cannot verify installed Argon packages/);
    assert.equal(s.get('ps-info-argon').querySelectorAll('*').find(el => el.tagName === 'PRE').textContent, details);
    assert.match(s.get('ps-update-status').textContent, /Argon: error/);
    assert.equal(s.get('ps-update-status').style.color, 'var(--ps-error)');
    // The minimal DOM retains old button objects; even a stale listener is gated.
    s.get('ps-argon-update-btn').click();
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 0);

    forceArgon(s, { current_version: '3.0.0-r2', latest_version: '3.0.0-r2', update_available: false, resume_available: false });
    assert.equal(s.get('ps-info-argon').textContent, '3.0.0-r2', 'clears stale errors, phase, target action and recovery');
    assert.match(s.get('ps-update-status').textContent, /Argon: up to date/);
    forceArgon(s, { update_available: false, resume_available: false });
    assert.equal(s.get('ps-row-argon').style.display, 'none', 'absence also replaces previous installed metadata');
}
{
    const s = argonPage({ argon_theme_error: 'OpenWrt 25.12.4 or newer is required', argon_theme_resume_available: true });
    assert.doesNotMatch(s.get('ps-info-argon').innerHTML, /ps-argon-update-btn/);
    assert.match(s.get('ps-info-argon').textContent, /OpenWrt 25\.12\.4/);
}

// A received install failure permits an explicit resume with a fresh operation ID.
// Capture the real helper callback to check metadata survives both shared layers.
for (const partial of [false, true]) {
    const s = argonPage();
    let failure;
    const restartAction = s.window.PT.restartAction;
    s.window.PT.restartAction = cfg => {
        const onFailure = cfg.onFailure;
        cfg.onFailure = (error, uncertain) => { failure = { error, uncertain }; onFailure(error, uncertain); };
        return restartAction(cfg);
    };
    s.get('ps-argon-update-btn').click();
    const first = themeOperation(s);
    const details = '<img src=x onerror=alert(1)> literal package output\n' + 'apk failed: full diagnostics\n'.repeat(100);
    s.last('/theme').reply({ success: false, error: 'Argon package installation failed', details,
        phase: 'translation', partial, resume_available: true });
    assert.equal(failure.uncertain, false);
    assert.equal(failure.error.kind, 'application');
    assert.equal(failure.error.phase, 'translation');
    assert.equal(failure.error.partial, partial);
    assert.equal(failure.error.resume_available, true);
    assert.equal(failure.error.details, details);
    assert.equal(s.get('ps-argon-update-btn').textContent, 'Resume Theme Update');
    assert.match(s.get('ps-argon-update-btn').title, /translation/);
    assert.equal(s.get('ps-argon-update-btn').disabled, false);
    assert.equal(s.get('ps-check-updates').disabled, false);
    assert.equal(s.get('ps-refresh-info').disabled, false);
    assert.equal(s.get('ps-argon-status').querySelectorAll('*').find(el => el.tagName === 'PRE').textContent, details);
    assert.equal(s.requests.filter(r => r.url.startsWith('/restart/status?')).length, 0, 'a known failure is not a claimed restart');
    s.tick(10000);
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 1, 'failure never automatically replays installation');
    s.get('ps-argon-update-btn').click();
    assert.notEqual(themeOperation(s), first, 'explicit resume has a new restart_id');
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 2);
    assert.equal(new URLSearchParams(s.last('/theme').body).has('resume'), false, 'the same endpoint loads its pinned plan');
}
{
    const s = argonPage();
    s.get('ps-argon-update-btn').click();
    s.last('/theme').reply({ success: false, applied: true, error: 'Cannot record operation result', details: 'write failed',
        phase: 'cleanup', partial: true, resume_available: true });
    assert.equal(s.get('ps-argon-update-btn').disabled, true, 'applied uncertainty wins over resume metadata');
    assert.equal(s.get('ps-refresh-info').disabled, true);
    const retry = s.get('ps-argon-status').children.find(el => el.tagName === 'BUTTON');
    assert.ok(retry);
    assert.equal(retry.textContent, 'Retry verification');
    retry.click();
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 1);
    assert.ok(probe(s));
}
for (const failure of ['network', 'timeout', 'parse', 'http500']) {
    const s = argonPage({ argon_theme_version: '3.0.0-r2', argon_theme_resume_available: true, argon_theme_phase: 'config' });
    s.get('ps-argon-update-btn').click();
    const post = s.last('/theme'), id = themeOperation(s);
    if (failure === 'network') post.onerror();
    else if (failure === 'timeout') post.ontimeout();
    else post.reply('<html>upstream error</html>', failure === 'http500' ? 500 : 200);
    assert.ok(probe(s));
    assert.equal(s.get('ps-argon-update-btn').disabled, true);
    probe(s).reply({ id, state: 'working', ready: false });
    s.tick(60000);
    assert.equal(s.get('ps-argon-update-btn').disabled, true);
    assert.equal(s.get('ps-check-updates').disabled, true);
    assert.equal(s.get('ps-refresh-info').disabled, true);
    const retry = s.get('ps-argon-status').children.find(el => el.tagName === 'BUTTON');
    assert.ok(retry);
    retry.click();
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 1, 'lost resume responses only allow read-only verification: ' + failure);
    probe(s).reply({ id, state: 'applied', restarted: true, ready: true,
        expected_version: '3.0.0-r2', installed_version: '3.0.0-r2' });
    assert.equal(s.reloads(), 1);
}
for (const knownFailure of [false, true]) {
    const s = argonPage();
    s.get('ps-check-updates').click();
    const check = s.last('/check'), html = s.get('ps-info-argon').innerHTML;
    s.get('ps-argon-update-btn').click();
    if (knownFailure) s.last('/theme').reply({ success: false, error: 'Locale install failed', details: 'complete failure output',
        phase: 'translation', partial: true, resume_available: true });
    else s.last('/theme').onerror();
    check.reply({ podkop: {}, tweaker: {}, theme: { current_version: '3.0.0-r2', latest_version: '3.0.0-r2', update_available: false } });
    assert.equal(s.get('ps-info-argon').innerHTML, html, 'an older in-flight check cannot replace the operation UI');
    assert.equal(s.get('ps-check-updates').disabled, !knownFailure, 'a stale response cannot unlock uncertainty');
    if (knownFailure) {
        assert.equal(s.get('ps-argon-update-btn').textContent, 'Resume Theme Update');
        assert.match(s.get('ps-argon-status').textContent, /Locale install failed/);
    } else assert.ok(probe(s));
    assert.equal(s.requests.filter(r => r.url === '/theme').length, 1);
}
{
    const s = argonPage({ argon_theme_latest: '3.0.0-r1' });
    s.get('ps-argon-update-btn').click();
    const id = themeOperation(s);
    s.last('/theme').reply({ success: true, restart_id: id, new_version: '3.0.0-r2' });
    probe(s).reply({ id, state: 'applied', restarted: true, ready: true, installed_version: '3.0.0-r1' });
    assert.equal(s.reloads(), 0, 'a fresh ACK replaces the old row target with its full revision');
    s.tick(1000);
    probe(s).reply({ id, state: 'applied', restarted: true, ready: true, installed_version: '3.0.0-r2' });
    assert.equal(s.reloads(), 1);
}

const importUrls = { importBundle: '/bundle', importCfg: '/config', importStubby: '/stubby', importSingbox: '/singbox',
    status: '/status', stubbyStatus: '/stubby/status', singboxStatus: '/singbox/status', rollback: '/import/rollback' };
function importReview(input, target = 'podkop') {
    const s = setup('import-export', importUrls);
    const text = typeof input === 'string' ? input : JSON.stringify({ format: 'podkop-tweaker-bundle', version: 1, items: input });
    s.context.FileReader = class { readAsText(file) { this.result = file.text; this.onload(); } };
    s.get('ps-import-file').files = [{ size: Buffer.byteLength(text), name: 'input.txt', text }];
    s.get('ps-import-open').click();
    if (typeof input === 'string') s.get('ps-import-as-select').value = target;
    return s;
}
function itemResult(s, label) { return s.get('ps-import-results').children.find(el => el.textContent.includes(label)); }
const podkopItem = { content: "config section 'main'\n" };

// All three bundle services use their own checked restart ACK. Podkop and
// sing-box polls remain independent even though both observe the same worker.
{
    const s = importReview({ podkop: podkopItem, stubby: { content: "config stubby 'global'\n" }, singbox: { content: '{"outbounds":[]}' } });
    const selection = s.get('ps-import-review-list').querySelectorAll('input[type="checkbox"]');
    s.get('ps-import-confirm').click();
    assert.equal(selection.every(box => box.disabled && box.checked), true, 'preserve/freeze the reviewed selection during application');
    assert.equal(s.last('/bundle').body.parts.find(part => part.name === 'items').value, 'podkop,stubby,singbox');
    const podkop = serviceAck('42:100'), stubby = serviceAck('9:100'), singbox = serviceAck('42:101');
    s.last('/bundle').reply({ success: true, applied: true, complete: true, partial: false, restarting: true,
        ...serviceAck('42:101'), // stale top-level facts must not replace the scoped map
        restarts: { podkop, stubby, singbox }, skipped: {}, results: {
            podkop: { ok: true, applied: true, restarting: true }, stubby: { ok: true, applied: true, restarting: true }, singbox: { ok: true, applied: true, restarting: true }
        } });
    s.get('ps-import-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.url === '/bundle').length, 1, 'pending import cannot replay the POST');
    s.tick(2000);
    s.last('/status').reply(processStatus('42:101'));
    s.last('/stubby/status').reply(processStatus('9:101'));
    s.last('/singbox/status').reply(processStatus('42:101'));
    assert.match(itemResult(s, 'Podkop config').textContent, /new process instance confirmed/);
    assert.match(itemResult(s, 'Stubby config').textContent, /new process instance confirmed/);
    assert.doesNotMatch(itemResult(s, 'Sing-box config').textContent, /new process instance confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, true, 'wait for every requested service transition');
    s.tick(2000); s.last('/singbox/status').reply(processStatus('42:102'));
    assert.match(s.get('ps-import-modal-status').textContent, /Requested service process transitions confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, false);
    assert.equal(selection.every(box => !box.disabled && box.checked), true, 'completion retains the original checked selection');
    assert.equal(s.get('ps-import-close').style.display, '');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
// Top-level Podkop and per-item flat facts remain supported without mixing a
// Podkop generation into another service's verification.
for (const name of ['podkop', 'stubby']) {
    const s = importReview({ [name]: name === 'podkop' ? podkopItem : { content: "config stubby 'global'\n" } });
    s.get('ps-import-confirm').click();
    const metadata = name === 'podkop' ? serviceAck() : { verification_required: true, previous_running: false, previous_identity_known: true };
    s.last('/bundle').reply({ success: true, applied: true, complete: true, restarting: name === 'podkop',
        ...(name === 'podkop' ? metadata : {}), results: { [name]: { ok: true, applied: true, ...(name === 'stubby' ? { ...metadata, restarting: true } : {}) } } });
    s.tick(2000); s.last(name === 'podkop' ? '/status' : '/stubby/status').reply(processStatus(name === 'podkop' ? '42:101' : '9:101'));
    assert.match(itemResult(s, name === 'podkop' ? 'Podkop config' : 'Stubby config').textContent, /new process instance confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, false);
}
for (const anotherItemSucceeded of [false, true]) {
    const s = importReview(anotherItemSucceeded ? { podkop: podkopItem, tweaker: { content: "config settings 'settings'\n" } } : { podkop: podkopItem });
    s.get('ps-import-confirm').click();
    const details = '<img src=x onerror=literal()>\n' + 'complete init restart error\n'.repeat(100);
    s.last('/bundle').reply({ success: anotherItemSucceeded, applied: true, partial: true, complete: false, restarting: false,
        restarts: { podkop: { success: false, error: 'Service restart command failed', details, verification_required: true } },
        results: { podkop: { ok: false, applied: true, partial: true, restart_required: true,
            error: 'Configuration saved, but Service restart command failed', details }, ...(anotherItemSucceeded ? { tweaker: { ok: true, applied: true } } : {}) } });
    assert.match(s.get('ps-import-modal-status').textContent, /Bundle partially applied/);
    assert.match(itemResult(s, 'Podkop config').textContent, /changes saved.*Service restart command failed/);
    assert.ok(preText(itemResult(s, 'Podkop config')).endsWith(details), 'per-item checked-command output is complete literal text');
    assert.equal(itemResult(s, 'Podkop config').className, 'is-fail');
    if (anotherItemSucceeded) assert.equal(itemResult(s, 'Tweaker settings').className, 'is-ok');
    assert.doesNotMatch(s.get('ps-import-modal-status').textContent, /Imported successfully|transitions confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, false, 'known per-item partial outcome does not strand controls');
    assert.equal(s.get('ps-import-rollback').style.display, 'inline-block');
    s.get('ps-import-confirm').dispatch('click'); s.tick(60000);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'no automatic re-apply after a finishing failure');
}
for (const location of ['item', 'restart']) {
    const s = importReview({ podkop: podkopItem }), failures = retainErrorBodies(s); s.get('ps-import-confirm').click();
    const body = { success: false, applied: true, partial: true, complete: false,
        results: { podkop: { ok: false, applied: true, ...(location === 'item' ? { unknown: true } : {}), error: 'Owned lock release failed after publication' } },
        restarts: location === 'restart' ? { podkop: { success: false, unknown: true, error: 'Restart finishing unknown' } } : {} };
    s.last('/bundle').reply(body);
    assertRetainedBody(failures, body);
    assert.match(s.get('ps-import-modal-status').textContent, /partially applied; finishing result incomplete/);
    assert.equal(s.get('ps-import-pick').disabled, true, 'nested uncertainty must retain the import mutation gate');
    s.get('ps-import-confirm').dispatch('click'); s.get('ps-import-rollback').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
{
    const s = importReview({ podkop: podkopItem }); s.get('ps-import-confirm').click();
    s.last('/bundle').reply({ success: true, complete: true, applied: true,
        results: { podkop: { ok: true, applied: true, restarting: true } },
        restarts: { podkop: { success: false, error: 'Checked restart failed', details: '<script>literal command error</script>' } } });
    assert.match(itemResult(s, 'Podkop config').textContent, /Checked restart failed/);
    assert.equal(itemResult(s, 'Podkop config').className, 'is-fail', 'a contradictory ok flag cannot mask a checked restart failure');
    assert.equal(s.get('ps-import-modal-status').style.color, 'var(--ps-error)');
    assert.doesNotMatch(s.get('ps-import-modal-status').textContent, /transitions confirmed/);
}
{
    const s = importReview({ tweaker: { content: "config settings 'settings'\n" }, stubby: { content: "config stubby 'global'\n" }, future_item: {} });
    const boxes = s.get('ps-import-review-list').querySelectorAll('input[type="checkbox"]');
    boxes.find(box => box.value === 'stubby').checked = false;
    s.get('ps-import-confirm').click();
    assert.equal(s.last('/bundle').body.parts.find(part => part.name === 'items').value, 'tweaker');
    s.last('/bundle').reply({ success: true, complete: true, applied: true, results: { tweaker: { ok: true, applied: true } }, skipped: ['stubby', 'future_item'] });
    assert.match(s.get('ps-import-results').textContent, /skipped: Stubby config/);
    assert.match(s.get('ps-import-results').textContent, /skipped: future_item/);
    assert.equal(boxes.find(box => box.value === 'stubby').checked, false);
    assert.equal(boxes.find(box => box.value === 'future_item').disabled, true);
    assert.equal(s.get('ps-import-pick').disabled, false);
}
{
    const s = importReview({ argon: { settings: {} } }); s.get('ps-import-confirm').click();
    s.last('/bundle').reply({ success: false, applied: false, partial: false, complete: false, results: {}, restarts: {}, skipped: ['argon'] });
    assert.match(s.get('ps-import-modal-status').textContent, /No selected items applied/);
    assert.match(s.get('ps-import-results').textContent, /skipped: Argon typography/);
    assert.equal(s.get('ps-import-results').children.some(el => el.className === 'is-fail'), false, 'hidden Argon remains an intentional skip');
    assert.doesNotMatch(s.get('ps-import-modal-status').textContent, /Operation failed|import failed/);
    assert.equal(s.get('ps-import-pick').disabled, false);
}
{
    const s = importReview({ podkop: podkopItem, tweaker: { content: "config settings 'settings'\n" } }); s.get('ps-import-confirm').click();
    s.last('/bundle').reply({ success: true, applied: true, results: { tweaker: { ok: true, applied: true } } });
    assert.match(s.get('ps-import-results').textContent, /Podkop config: no item result returned; outcome unknown/);
    assert.match(s.get('ps-import-modal-status').textContent, /result incomplete/);
    assert.equal(s.get('ps-import-pick').disabled, true);
    s.get('ps-import-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
for (const [name, endpoint, status] of [['podkop', '/config', '/status'], ['stubby', '/stubby', '/stubby/status'], ['singbox', '/singbox', '/singbox/status']]) {
    const s = importReview(name === 'singbox' ? '{"outbounds":[]}' : "config section 'main'\n", name);
    s.get('ps-import-confirm').click(); s.last(endpoint).reply({ ...serviceAck(), applied: true });
    s.tick(2000); s.last(status).reply(processStatus('42:100'));
    assert.equal(s.get('ps-import-pick').disabled, true);
    assert.doesNotMatch(s.get('ps-import-modal-status').textContent, /new process instance confirmed/);
    s.tick(2000); s.last(status).reply(processStatus('42:101'));
    assert.match(s.get('ps-import-modal-status').textContent, /imported to disk.*new process instance confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, false);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
{
    const s = importReview("config section 'main'\n"); s.get('ps-import-confirm').click();
    s.last('/config').reply({ success: true, applied: true, restarting: true });
    for (let i = 0; i < 8; i++) { s.tick(2000); s.last('/status').reply(processStatus('42:100')); }
    assert.match(s.get('ps-import-modal-status').textContent, /running, but restart unconfirmed/);
    assert.doesNotMatch(s.get('ps-import-modal-status').textContent, /did not start|new process instance confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, false);
}
{
    const s = importReview("config section 'main'\n"); s.get('ps-import-confirm').click();
    s.last('/config').reply({ success: false, applied: true, error: 'Service restart command failed', details: '<script>literal raw import error</script>' });
    assert.match(s.get('ps-import-modal-status').textContent, /configuration saved.*finishing failed.*restart unverified/);
    assert.ok(preText(s.get('ps-import-modal-status')).endsWith('<script>literal raw import error</script>'));
    assert.equal(s.get('ps-import-pick').disabled, false);
    s.get('ps-import-rollback').click();
    assert.equal(s.last('/import/rollback').body, 'token=token');
    s.last('/import/rollback').reply({ ...serviceAck(), applied: true });
    s.tick(2000); s.last('/status').reply(processStatus('42:100'));
    assert.equal(s.get('ps-import-pick').disabled, true);
    s.tick(2000); s.last('/status').reply(processStatus('42:101'));
    assert.match(s.get('ps-import-modal-status').textContent, /restored to disk.*new process instance confirmed/);
    assert.equal(s.get('ps-import-pick').disabled, false);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 2, 'Import and explicit Rollback only');
}
for (const failure of [r => r.onerror(), r => r.ontimeout(), r => r.reply('<html>LuCI login</html>'), r => r.reply({}),
    r => r.reply({ error: 'Internal error' }), r => r.reply({ error: 'Server failed without an operation outcome' }, 500)]) {
    const s = importReview("config section 'main'\n"); s.get('ps-import-confirm').click();
    failure(s.last('/config'));
    assert.match(s.get('ps-import-modal-status').textContent, /result unknown/);
    assert.equal(s.get('ps-import-pick').disabled, true);
    s.escape(); s.get('ps-import-open').dispatch('click'); s.get('ps-import-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1, 'uncertain mutations cannot be replayed by reopening the review');
}
{
    const s = importReview("config section 'main'\n"); s.get('ps-import-confirm').click();
    const post = s.last('/config'); s.escape();
    post.reply({ success: false, applied: true, error: 'Restart failed after close', details: 'full result retained outside the closed modal' });
    assert.equal(s.get('ps-import-modal').style.display, 'none');
    assert.match(s.get('ps-import-status').textContent, /configuration saved.*finishing failed/);
    assert.equal(s.get('ps-import-pick').disabled, false, 'closing during a known terminal outcome does not leak the request lock');
    s.get('ps-import-confirm').dispatch('click');
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}

// A failed aggregate can still contain a successful item's checked restart.
// Keep its scoped identity separate from top-level/other-service facts while
// preserving every known failure, skipped item and complete diagnostic body.
for (const status of [200, 503]) {
    const s = importReview({ podkop: podkopItem, stubby: { content: "config stubby 'global'\n" },
        tweaker: { content: "config settings 'settings'\n" }, fragment: { content: "config settings 'global'\n" } });
    const failures = retainErrorBodies(s);
    s.get('ps-import-confirm').click();
    const details = '<script>literal aggregate failure</script>\n' + 'complete bundle finishing output\n'.repeat(100);
    const stubbyDetails = '<img src=x onerror=literal()>\n' + 'complete Stubby init stderr\n'.repeat(100);
    const body = { ...serviceAck('99:100'), success: false, applied: true, partial: true, complete: false,
        error: 'Some bundle finishing stages failed', details, skipped: ['fragment'],
        results: {
            podkop: { ok: true, applied: true, restarting: true },
            stubby: { ok: false, applied: true, restart_required: true, error: 'Stubby restart command failed', details: stubbyDetails },
            tweaker: { ok: true, applied: true }
        }, restarts: {
            podkop: serviceAck('42:100'),
            stubby: { success: false, verification_required: true, previous_running: true, previous_identity_known: true,
                previous_instance: '9:100', error: 'Stubby restart command failed', details: stubbyDetails }
        } };
    s.last('/bundle').reply(body, status);
    assertRetainedBody(failures, body);
    assert.match(itemResult(s, 'Stubby config').textContent, /changes saved.*Stubby restart command failed/);
    assert.ok(preText(itemResult(s, 'Stubby config')).endsWith(stubbyDetails));
    assert.match(s.get('ps-import-results').textContent, /skipped: Fragment settings/);
    s.tick(2000); s.last('/status').reply(processStatus('42:100'));
    assert.equal(s.get('ps-import-pick').disabled, true);
    assert.doesNotMatch(itemResult(s, 'Podkop config').textContent, /new process instance confirmed/, 'the top-level foreign prior instance cannot replace item restart evidence');
    s.tick(2000); s.last('/status').reply(processStatus('42:101'));
    assert.match(itemResult(s, 'Podkop config').textContent, /new process instance confirmed/);
    assert.match(s.get('ps-import-modal-status').textContent, /Bundle partially applied: 2 accepted, 1 failed, 1 skipped/);
    assert.ok(preText(s.get('ps-import-modal-status')).includes(details));
    assert.equal(s.get('ps-import-pick').disabled, false, 'a known aggregate failure completes after its actual outstanding watcher');
    assert.equal(s.get('ps-import-modal-status').style.color, 'var(--ps-error)');
    assert.equal(s.requests.filter(r => r.url === '/stubby/status').length, 1, 'a failed restart command does not start a success watcher');
    s.tick(60000);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
    assertRetainedBody(failures, body);
}
for (const [name, endpoint] of [['podkop', '/config'], ['stubby', '/stubby'], ['singbox', '/singbox']]) {
    const s = importReview(name === 'singbox' ? '{"outbounds":[]}' : "config section 'main'\n", name), failures = retainErrorBodies(s);
    s.get('ps-import-confirm').click();
    const details = '<script>literal ' + name + ' import stderr</script>\n' + 'complete import diagnostics\n'.repeat(100);
    const body = { success: false, applied: true, restart_required: true, verification_required: true,
        previous_running: true, previous_identity_known: true, previous_instance: '42:100',
        error: 'Import finishing failed after publication', details };
    s.last(endpoint).reply(body, 503);
    assertRetainedBody(failures, body);
    assert.match(s.get('ps-import-modal-status').textContent, /configuration saved.*finishing failed.*restart unverified/);
    assert.ok(preText(s.get('ps-import-modal-status')).endsWith(details));
    assert.equal(s.get('ps-import-pick').disabled, false);
    assert.doesNotMatch(s.get('ps-import-modal-status').textContent, /new process instance confirmed|result unknown/);
    s.get('ps-import-confirm').dispatch('click'); s.tick(60000);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}
for (const outcome of [{ applied: false }, { applied: true }, { applied: true, unknown: true }]) {
    const s = importReview("config section 'main'\n"), failures = retainErrorBodies(s);
    s.get('ps-import-confirm').click();
    s.last('/config').reply({ success: false, applied: true, error: 'Import restart failed' });
    s.get('ps-import-rollback').click();
    const details = '<script>literal rollback stderr</script>\n' + 'complete rollback diagnostics\n'.repeat(100);
    const body = { success: false, ...outcome, error: 'Rollback finishing failed', details,
        verification_required: true, previous_running: true, previous_identity_known: true, previous_instance: '42:100' };
    s.last('/import/rollback').reply(body);
    assertRetainedBody(failures, body);
    assert.equal(s.get('ps-import-pick').disabled, outcome.unknown === true);
    const notice = s.get('ps-import-modal-status');
    assert.match(notice.textContent, outcome.unknown ? /backup restored; finishing result unknown/ : outcome.applied ? /restored to disk.*restart failed or is unverified/ : /Rollback failed/);
    if (!outcome.applied) assert.doesNotMatch(notice.textContent, /backup restored|restored to disk/);
    assert.ok(preText(notice).endsWith(details));
    s.get('ps-import-confirm').dispatch('click'); s.get('ps-import-rollback').dispatch('click'); s.tick(60000);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 2, 'only the original Import and explicit Rollback were sent');
}

// Both raw and bundle import watchers remain operation-owned after the review
// is hidden, whether it closes before the ACK or during process verification.
for (const bundle of [false, true]) for (const hideBeforeAck of [false, true]) {
    const s = importReview(bundle ? { podkop: podkopItem } : "config section 'main'\n");
    s.get('ps-import-confirm').click();
    const post = s.last(bundle ? '/bundle' : '/config');
    if (hideBeforeAck) s.escape();
    post.reply(bundle ? { success: true, applied: true, complete: true,
        results: { podkop: { ok: true, applied: true, restarting: true } }, restarts: { podkop: serviceAck() } } : { ...serviceAck(), applied: true });
    if (!hideBeforeAck) s.escape();
    s.tick(2000); s.last('/status').reply(processStatus('42:100'));
    assert.equal(s.get('ps-import-pick').disabled, true);
    assert.doesNotMatch(s.get('ps-import-status').textContent, /new process instance confirmed|transitions confirmed/);
    s.tick(2000); s.last('/status').reply(processStatus('42:101'));
    assert.equal(s.get('ps-import-modal').style.display, 'none');
    assert.equal(s.get('ps-import-pick').disabled, false, 'hiding the review cannot discard a sent operation completion or strand its gate');
    assert.match(s.get('ps-import-status').textContent, bundle ? /Requested service process transitions confirmed/ : /imported to disk.*new process instance confirmed/);
    s.get('ps-import-confirm').dispatch('click'); s.tick(60000);
    assert.equal(s.requests.filter(r => r.method === 'POST').length, 1);
}

async function contentImports() {
    const urls = importUrls;
    const content = "config section 'main'\n\toption user_domains_text '" + 'пример.рф\n'.repeat(14000) + "'\n";
    for (const bundle of [true, false]) {
        const s = setup('import-export', urls);
        const text = bundle ? JSON.stringify({ format: 'podkop-tweaker-bundle', version: 1, items: { podkop: { content }, stubby: { content: "config stubby 'global'" } } }) : content;
        s.context.FileReader = class { readAsText(file) { this.result = file.text; this.onload(); } };
        s.get('ps-import-file').files = [{ size: Buffer.byteLength(text), name: 'input.txt', text }];
        s.get('ps-import-open').click();
        if (bundle) s.get('ps-import-review-list').querySelectorAll('input[type="checkbox"]')[1].checked = false;
        s.get('ps-import-confirm').click();
        const request = s.last(bundle ? '/bundle' : '/config');
        assert.ok(request.body instanceof s.FormData);
        assert.equal(request.headers['Content-Type'], undefined);
        const part = request.body.parts.find(p => p.name === 'content_file');
        assert.ok(part.value.size > 102400);
        assert.equal(await part.value.text(), text, 'UTF-8, quotes and multiline values are preserved');
        assert.equal(request.body.parts.find(p => p.name === 'token').value, 'token');
        if (bundle) assert.equal(request.body.parts.find(p => p.name === 'items').value, 'podkop');
        const ack = serviceAck();
        request.reply(bundle ? { success: true, applied: true, complete: true, results: { podkop: { ok: true, applied: true, restarting: true } }, restarts: { podkop: ack }, skipped: ['stubby'] } : { ...ack, applied: true });
        s.tick(2000); s.last('/status').reply(processStatus('42:101'));
        assert.equal(s.get('ps-import-close').style.display, '');
        s.escape();
        assert.equal(s.get('ps-import-modal').style.display, 'none');
        assert.equal(s.get('ps-import-file').value, '');
        assert.equal(s.get('ps-import-open').disabled, true, 'Esc after completion follows the normal Close cleanup');
    }
    const s = setup('import-export', urls);
    s.context.FileReader = class { readAsText(file) { this.result = file.text; this.onload(); } };
    s.get('ps-import-file').files = [{ size: 30, name: 'input.txt', text: "config section 'main'\n" }];
    s.get('ps-import-open').click();
    assert.equal(s.get('ps-import-modal').style.display, 'flex');
    s.escape();
    assert.equal(s.get('ps-import-modal').style.display, 'none');
    s.get('ps-import-confirm').click();
    assert.equal(s.requests.filter(request => request.method === 'POST').length, 0, 'Esc clears pending import and never applies it');
}
contentImports().then(() => console.log('Frontend reliability: PASS (typed form gates, retained object failures, isolated previews/resets, outbound schema, service identities, subscription modal generations/literal logs/partial outcomes, operation-owned Attach/Import watchers, per-item bundle/raw/rollback finishing, uncertain no-replay controls, Argon recovery and UTF-8 multipart)')).catch(error => { console.error(error); process.exitCode = 1; });
