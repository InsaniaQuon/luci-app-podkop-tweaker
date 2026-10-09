// Real frontend scripts: failed transports, independent settings and restart recovery.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');

function setup(view, urls) {
    const elements = {}, requests = [], timers = [], events = {};
    let now = 0, reloads = 0;
    class Element {
        constructor(tag = 'span') {
            this.tagName = tag.toUpperCase(); this.attrs = {}; this.style = { setProperty() {} };
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
        set innerHTML(value) { this._text = value; this.children = []; }
        get innerHTML() { return this._text || ''; }
        appendChild(child) { if (child.parentNode) child.parentNode.removeChild(child); this.children.push(child); child.parentNode = this; }
        removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
        insertBefore(child, before) { if (child.parentNode) child.parentNode.removeChild(child); const i = this.children.indexOf(before); this.children.splice(i < 0 ? this.children.length : i, 0, child); child.parentNode = this; }
        querySelectorAll(selector) {
            if (this.buttons) return this.buttons;
            const all = this.children.flatMap(child => [child, ...child.querySelectorAll('*')]);
            return selector === 'input[type="checkbox"]' ? all.filter(child => child.tagName === 'INPUT' && child.type === 'checkbox') : all;
        }
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
        querySelectorAll() { return []; }, createElement: tag => new Element(tag), addEventListener() {} };
    const window = { PT: { csrf: 'token', version: '4.9.0', urls },
        location: { href: 'http://router.test/admin/services/podkop-tweaker/' + view, origin: 'http://router.test', reload() { reloads++; }, replace(url) { this.href = url; reloads++; } },
        addEventListener(event, cb) { events[event] = cb; }, removeEventListener(event) { delete events[event]; } };
    const context = vm.createContext({ window, document, XMLHttpRequest: XHR, FormData, Blob, URL, Date: Clock,
        confirm: () => true, setTimeout(fn, delay) { const t = { fn, at: now + delay }; timers.push(t); return t; },
        clearTimeout(t) { if (t) t.cancelled = true; }, setInterval() {}, clearInterval() {} });
    vm.runInContext(fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8'), context);
    context.PT = window.PT; window.PT.checkStale = () => {};
    const source = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker', view + '.htm'), 'utf8');
    const scripts = [...source.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    vm.runInContext(scripts.at(-1)[1], context);
    return { get, window, context, requests, events, FormData,
        last(url) { return requests.filter(r => r.url === url).at(-1); },
        tick(ms) { now += ms; for (const t of [...timers]) if (!t.cancelled && !t.ran && t.at <= now) { t.ran = true; t.fn(); } },
        reloads() { return reloads; },
        button(kind) { const btn = new Element('button'); btn.className = kind; btn.setAttribute('data-section', 'main'); btn.setAttribute('data-index', '0'); btn.setAttribute('data-url', 'https://sub.test'); get('ps-subs-content').buttons = [btn]; return btn; } };
}

const subUrls = { state: '/state', settings_read: '/settings', settings_save: '/settings/save', auto_status: '/auto/status',
    read_log: '/log', fetch: '/fetch', attach: '/attach', detach: '/detach', update_all: '/all', service_status: '/service' };
function subscriptions() { return setup('subscriptions', { ...subUrls }); }

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

// Failed, malformed and expired-session responses always release Update All.
for (const failure of ['network', 'timeout', 'null', '[]', '{}', 'html', '403']) {
    const s = subscriptions(); s.get('ps-subs-update-all').click();
    const request = s.last('/all');
    assert.equal(s.get('ps-subs-update-all').disabled, true);
    if (failure === 'network') request.onerror();
    else if (failure === 'timeout') request.ontimeout();
    else request.reply(failure === 'html' || failure === '403' ? '<html>LuCI login</html>' : failure, failure === '403' ? 403 : 200);
    assert.equal(s.get('ps-subs-update-all').disabled, false, failure);
    assert.match(s.get('ps-global-status').textContent, /error|timed out|Invalid response/i, failure);
    s.get('ps-subs-update-all').click();
    assert.equal(s.requests.filter(r => r.url === '/all').length, 2, 'retry is available');
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

async function contentImports() {
    const urls = { importBundle: '/bundle', importCfg: '/config', importStubby: '/stubby', importSingbox: '/singbox', status: '/status', stubbyStatus: '/stubby/status' };
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
    }
}
contentImports().then(() => console.log('Frontend reliability: PASS (independent settings, failed transports, locks, auto status, cached Git URL, restart recovery, raw UTF-8 config/bundle multipart)')).catch(error => { console.error(error); process.exitCode = 1; });
