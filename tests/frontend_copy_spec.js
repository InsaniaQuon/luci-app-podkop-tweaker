// frontend_copy_spec.js | v1.2.0 | 19.10.2026 | Clipboard transport and actual compact subscription snapshots
// Run: node tests/frontend_copy_spec.js. No dependencies or OS clipboard writes.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const shared = fs.readFileSync(path.join(__dirname, '../www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');
const subscriptionsSource = fs.readFileSync(path.join(__dirname, '../usr/lib/lua/luci/view/podkop-tweaker/subscriptions.htm'), 'utf8');

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

// Model the real log sources, not a second journal formatter. This small DOM
// parses the page's generated markup and distinguishes textContent from visible
// innerText (including closed/open Details); native layout stays in Edge tests.
function subscriptionLogPage() {
    const elements = {}, requests = [], writes = [];
    const decode = text => text.replace(/&(?:amp|lt|gt|quot|#39);/g, entity => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" })[entity]);
    const blocks = new Set(['DIV', 'P', 'PRE', 'DETAILS', 'SUMMARY', 'H3', 'H4', 'TR']);
    class Element {
        constructor(tag = 'span') {
            this.tagName = tag.toUpperCase(); this.nodes = []; this.attrs = {}; this.style = {}; this.events = {};
            this.classList = { contains: name => (this.className || '').split(/\s+/).includes(name),
                add: name => { if (!this.classList.contains(name)) this.className = ((this.className || '') + ' ' + name).trim(); } };
        }
        get children() { return this.nodes.filter(node => node instanceof Element); }
        get firstChild() { return this.nodes[0]; }
        appendChild(node) { if (node.parentNode) node.parentNode.removeChild(node); this.nodes.push(node); node.parentNode = this; return node; }
        removeChild(node) { this.nodes.splice(this.nodes.indexOf(node), 1); node.parentNode = null; }
        insertBefore(node, before) { if (node.parentNode) node.parentNode.removeChild(node); const i = this.nodes.indexOf(before); this.nodes.splice(i < 0 ? this.nodes.length : i, 0, node); node.parentNode = this; }
        setAttribute(key, value) { this.attrs[key] = String(value); if (key === 'class') this.className = value; if (key === 'id') this.id = value; }
        getAttribute(key) { return this.attrs[key] ?? null; }
        addEventListener(type, fn) { (this.events[type] ||= []).push(fn); }
        dispatch(type, data = {}) { for (const fn of this.events[type] || []) fn({ target: this, preventDefault() {}, stopPropagation() {}, ...data }); }
        click() { if (!this.disabled) this.dispatch('click'); }
        matches(selector) {
            if (selector === '*') return true;
            if (selector[0] === '#') return this.id === selector.slice(1);
            if (selector[0] === '.') return this.classList.contains(selector.slice(1));
            if (/^\[[\w-]+\]$/.test(selector)) return Object.hasOwn(this.attrs, selector.slice(1, -1));
            return this.tagName === selector.toUpperCase();
        }
        closest(selector) { return this.matches(selector) ? this : this.parentNode?.closest(selector) || null; }
        contains(node) { return node === this || this.children.some(child => child.contains(node)); }
        querySelectorAll(selector) { return this.children.flatMap(child => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]); }
        querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
        set textContent(value) { this.nodes = []; this._text = String(value); this._html = ''; }
        get textContent() { return (this._text || '') + this.nodes.map(node => node.textContent).join(''); }
        set innerHTML(html) {
            this.nodes = []; this._text = ''; this._html = String(html);
            const stack = [this];
            for (const token of this._html.match(/<[^>]*>|[^<]+/g) || []) {
                if (token.startsWith('</')) { stack.pop(); continue; }
                if (token[0] === '<') {
                    const tag = token.match(/^<([a-z][\w-]*)/i)?.[1];
                    if (!tag) continue;
                    const node = new Element(tag);
                    for (const [, name, value] of token.matchAll(/([\w-]+)="([^"]*)"/g)) node.setAttribute(name, decode(value));
                    if (/\bopen(?:\s|>|=)/.test(token)) node.open = true;
                    if (/\bhidden(?:\s|>|=)/.test(token)) node.hidden = true;
                    for (const [, name, value] of (node.getAttribute('style') || '').matchAll(/([\w-]+)\s*:\s*([^;]+)/g)) node.style[name.replace(/-([a-z])/g, (_, ch) => ch.toUpperCase())] = value.trim();
                    stack.at(-1).appendChild(node);
                    if (!/^(?:input|br|hr|img|link)$/i.test(tag) && !token.endsWith('/>')) stack.push(node);
                } else stack.at(-1).appendChild({ textContent: decode(token) });
            }
        }
        get innerHTML() { return this._html || ''; }
        get innerText() {
            function visible(node) {
                if (!(node instanceof Element)) return node.textContent;
                if (node.hidden || node.style.display === 'none' || node.style.visibility === 'hidden') return '';
                const nodes = node.tagName === 'DETAILS' && !node.open ? node.children.filter(child => child.tagName === 'SUMMARY') : node.nodes;
                const text = (node._text || '') + nodes.map(visible).join('');
                return blocks.has(node.tagName) ? '\n' + text + '\n' : text;
            }
            return visible(this).replace(/\n{3,}/g, '\n\n').replace(/^\n+|\n+$/g, '');
        }
    }
    const get = id => elements[id] ||= Object.assign(new Element(), { id });
    for (const [, tag, attrs, id] of subscriptionsSource.matchAll(/<([a-z][\w-]*)\b([^>]*\bid="([^"]+)"[^>]*)>/gi)) {
        const el = get(id); el.tagName = tag.toUpperCase();
        const cls = attrs.match(/\bclass="([^"]*)"/), display = attrs.match(/\bdisplay:([^;"\s]+)/);
        if (cls) el.className = cls[1];
        if (display) el.style.display = display[1];
    }
    const document = { documentElement: Object.assign(new Element('html'), { style: { setProperty() {} } }), body: new Element('body'),
        getElementById(id) { return elements[id] || this.body.querySelector('#' + id); }, createElement: tag => new Element(tag), addEventListener() {},
        querySelectorAll(selector) {
            if (selector.includes('#cbi-podkop-tweaker textarea')) return [get('ps-log-wrap'), get('ps-full-log-body')];
            return this.body.querySelectorAll(selector);
        } };
    for (const el of Object.values(elements)) document.body.appendChild(el);
    get('ps-log-display-count').value = '2';
    get('ps-log-display-count').options = [5, 10, 15, 20, 25].map(value => ({ value: String(value) }));
    class XHR {
        constructor() { requests.push(this); this.status = 0; this.readyState = 0; this.responseText = ''; }
        open(method, url) { this.method = method; this.url = url; }
        setRequestHeader() {}
        send(body) { this.body = body; }
        reply(body, status = 200) { this.status = status; this.readyState = 4; this.responseText = typeof body === 'string' ? body : JSON.stringify(body); this.onload(); }
    }
    const window = { PT: { csrf: 'token', urls: { state: '/state', settings_read: '/settings', read_log: '/log', auto_status: '/auto',
        update_all: '/all', fetch: '/fetch', attach: '/attach', service_status: '/service' } },
        navigator: { clipboard: { writeText(text) { writes.push(text); return Promise.resolve(); } } } };
    const context = vm.createContext({ window, document, Promise, XMLHttpRequest: XHR, confirm: () => true, setTimeout() {}, clearTimeout() {} });
    vm.runInContext(shared, context);
    context.PT = window.PT;
    const getJson = window.PT.getJson;
    window.PT.getJson = function(url, callback, timeout) {
        return getJson(url, function(body, status, reason) {
            const before = JSON.stringify(body);
            callback(body, status, reason);
            assert.equal(JSON.stringify(body), before, 'presentation/Copy must not rewrite the raw API journal snapshot');
        }, timeout);
    };
    vm.runInContext([...subscriptionsSource.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].at(-1)[1], context);
    return { PT: window.PT, get: id => document.getElementById(id) || get(id), requests, writes, last: url => requests.filter(request => request.url === url).at(-1) };
}

async function copyDisplayedLog(s, id) {
    const source = s.get(id), before = source.innerText;
    assert.ok(source.__ptCopyButton, 'the actual page source is initialized through PT.initCopyButtons');
    assert.equal(source.querySelectorAll('.ps-copy-btn').length, 0, 'the source never contains its own Copy label/icon');
    source.__ptCopyButton.click();
    await Promise.resolve(); await Promise.resolve();
    assert.equal(s.writes.at(-1), before, 'Copy equals the current displayed ' + id + ' content');
    assert.equal(source.innerText, before, 'Copy does not alter the log or a disclosure state');
    return before;
}

async function subscriptionSnapshots() {
    const s = subscriptionLogPage(), id = '0123456789abcdef0123456789abcdef';
    const header = (state, service, outcome, skipped = '0') => '12:00 19.10.2026|auto|updated=1|unchanged=2|failed=0|id=' + id +
        '|state=' + state + '|service=' + service + '|skipped=' + skipped + '|outcome=' + outcome;
    const pending = header('pending', 'pending', 'pending');
    const finished = header('finished', 'requested', 'ok');
    const legacy = '11:59 19.10.2026|manual|updated=0|unchanged=1|failed=0';
    s.last('/log').reply({ lines: [legacy, '  legacy section:', '    legacy proxy: unchanged',
        pending, '  current section:', '    pending-only proxy: updated',
        finished, '  service:', '    podkop: updated', '    exact <proxy> & literal: unchanged', '  service:', '    podkop: requested'] });
    s.get('ps-full-log-btn').click();
    for (const target of ['ps-log-wrap', 'ps-full-log-body']) assert.equal(s.get(target).querySelectorAll('details').length, 0, 'normal/legacy/pending snapshots have no routine diagnostic disclosure');
    const recent = await copyDisplayedLog(s, 'ps-log-wrap'), full = await copyDisplayedLog(s, 'ps-full-log-body');
    for (const text of [recent, full]) {
        assert.match(text, /12:00 19\.10\.2026.*auto.*updated=1 unchanged=2 failed=0/);
        assert.match(text, /pending-only proxy: updated/);
        assert.match(text, /podkop: updated/);
        assert.match(text, /exact <proxy> & literal: unchanged/);
        assert.equal((text.match(/  service:/g) || []).length, 1, 'Copy retains the real user section called service');
        assert.equal((text.match(/updated=1 unchanged=2 failed=0/g) || []).length, 2, 'same-ID blocks remain two visible/copyable server records');
        assert.doesNotMatch(text, /Operation:|0123456789abcdef|Finished —|Outcome: OK|Service: restart requested|podkop: requested|skipped=0/);
    }
    assert.doesNotMatch(recent, /legacy section/); assert.match(full, /legacy proxy: unchanged/);

    // A later same-ID snapshot is authoritative, not merged with pending text.
    s.get('ps-subs-refresh').click();
    s.last('/log').reply({ lines: [finished, '  replacement section:', '    finished-only proxy: updated', '  service:', '    podkop: requested'] });
    for (const target of ['ps-log-wrap', 'ps-full-log-body']) {
        const text = await copyDisplayedLog(s, target);
        assert.match(text, /finished-only proxy: updated/);
        assert.doesNotMatch(text, /pending-only|legacy section|exact <proxy>|podkop: requested/);
        assert.equal((text.match(/updated=1 unchanged=2 failed=0/g) || []).length, 1);
    }

    // Log problems expose concise typed facts even with zero slot failures.
    // Their complete raw block participates in Copy only while Details is open.
    for (const service of ['failed', 'unknown']) {
        const rawHeader = header('finished', service, service === 'failed' ? 'failed' : 'partial', service === 'failed' ? '02' : '0');
        const lines = [rawHeader, '  problem section:', '    affected <proxy>: updated', '  service:',
            '    podkop: ' + service + ' (complete checked output & errno evidence)'];
        s.get('ps-subs-refresh').click(); s.last('/log').reply({ lines });
        for (const target of ['ps-log-wrap', 'ps-full-log-body']) {
            const source = s.get(target), disclosure = source.querySelector('details');
            assert.ok(disclosure && !disclosure.open, 'problem log Details is initially collapsed');
            assert.equal(disclosure.querySelector('summary').style.color, 'var(--ps-' + (service === 'failed' ? 'error' : 'warning') + ')', 'warning disclosure does not inherit error red');
            const collapsed = await copyDisplayedLog(s, target);
            assert.match(collapsed, /failed=0/);
            assert.match(collapsed, service === 'failed' ? /restart failed/i : /restart.*unknown/i);
            assert.doesNotMatch(collapsed, /\|id=|\|state=|0123456789abcdef/);
            if (service === 'failed') assert.match(collapsed, /skipped=02/);
            disclosure.open = true; disclosure.dispatch('toggle');
            const expanded = await copyDisplayedLog(s, target);
            assert.notEqual(expanded, collapsed);
            assert.ok(expanded.includes(rawHeader), 'expanded Copy retains the complete literal raw header, including hidden metadata');
            assert.ok(expanded.includes(lines.at(-1)), 'expanded Copy retains complete service diagnostics');
            assert.doesNotMatch(expanded, /&lt;|&amp;|Copy all text|Copied/);
            disclosure.open = false; disclosure.dispatch('toggle');
            assert.equal(await copyDisplayedLog(s, target), collapsed, 'collapsing restores the same displayed/copyable compact mask');
        }
    }
    s.get('ps-subs-refresh').click();
    s.last('/log').reply({ lines: [finished, '  replacement section:', '    finished-only proxy: updated', '  service:', '    podkop: requested'] });

    // A failed read keeps the displayed snapshot. Expanding adjacent problem
    // Details exposes complete diagnostics without contaminating either log's
    // Copy source; the dedicated diagnostic Copy still uses its complete PRE.
    const details = '<script>literal IO failure</script>\n' + 'complete journal read diagnostics\n'.repeat(100);
    s.get('ps-subs-refresh').click(); s.last('/log').reply({ error: 'Cannot close journal', details });
    for (const [target, errorId] of [['ps-log-wrap', 'ps-log-error'], ['ps-full-log-body', 'ps-full-log-error']]) {
        const error = s.get(errorId), disclosure = error.querySelector('details');
        assert.ok(disclosure && !disclosure.open, 'log read problems retain initially collapsed Details');
        const closed = error.innerText;
        assert.doesNotMatch(closed, /complete journal read diagnostics/);
        for (const open of [false, true]) {
            disclosure.open = open; disclosure.dispatch('toggle');
            const text = await copyDisplayedLog(s, target);
            assert.match(text, /finished-only proxy: updated/);
            assert.doesNotMatch(text, /Cannot close journal|literal IO failure|complete journal read diagnostics|pending-only proxy/);
            assert.equal(disclosure.open, open, 'log Copy never toggles problem Details');
        }
        assert.match(error.innerText, /complete journal read diagnostics/);
        const pre = disclosure.querySelector('pre');
        disclosure.open = false; disclosure.dispatch('toggle');
        assert.equal(error.innerText, closed, 'collapsing returns to the exact short problem presentation');
        for (const open of [false, true]) {
            disclosure.open = open; disclosure.dispatch('toggle');
            pre.__ptCopyButton.click(); await Promise.resolve(); await Promise.resolve();
            assert.equal(s.writes.at(-1), details, 'diagnostic Copy retains complete output with Details open=' + open);
            assert.equal(disclosure.open, open, 'diagnostic Copy does not toggle Details');
        }
    }
    assert.equal(s.requests.filter(request => request.method === 'POST').length, 0, 'snapshot/disclosure/Copy interactions are read-only');
}

// The problem cut's own Copy control must retain the original typed response,
// including null/string booleans and known journal IO failures after unchanged
// work. The compact visible summary must never replace the complete copy source.
async function subscriptionMutationDetails() {
    const invalid = [
        { outcome: 'success' }, { outcome: null }, { outcome: 'pending' }, { unknown: 'true' },
        { service: 'running' }, { operation_id: null }, { journal: { recorded: true, finalized: 'false' } },
        { journal: { recorded: true, finalized: true, unknown: 'true' } }
    ];
    const journalError = 'Cannot publish journal: errno 5 <script>literal IO</script>\n' + 'complete owned journal diagnostics\n'.repeat(100);
    const cases = [
        ...invalid.map(fields => ({ fields, role: 'warning', unchanged: true })),
        ...[false, true].flatMap(unknown => [false, true].map(recorded => ({ role: unknown ? 'warning' : 'error', unchanged: false,
            fields: { success: false, applied: true, error: 'Journal finishing failed', unknown, outcome: 'partial',
                journal: { recorded, finalized: false, unknown, error: journalError } } })))
    ];
    for (const action of ['all', 'attach']) for (const test of cases) {
        const s = subscriptionLogPage();
        if (action === 'all') s.get('ps-subs-update-all').click();
        else {
            s.last('/state').reply({ sections: [{ name: 'main', proxy_config_type: 'url', slots: [{ index: 0,
                proxy: { name: 'Selected' }, subscription: { subscription_url: 'https://sub.test', proxy_name: 'Selected' } }] }] });
            const button = s.get('ps-subs-content').querySelector('.ps-sub-btn-update');
            assert.ok(button, 'Attach Copy fixture uses the actual rendered per-slot action');
            s.get('ps-subs-content').dispatch('click', { target: button });
            s.last('/fetch').reply({ success: true, proxies: [{ name: 'Selected', link: 'vless://fixture@proxy.test:443' }] });
        }
        const body = { success: true, applied: false, service: 'not_required', outcome: 'ok',
            operation_id: '0123456789abcdef0123456789abcdef', journal: { recorded: true, finalized: true },
            ...(action === 'all' ? { updated: test.unchanged ? 0 : 1, unchanged: 2, failed: 0, skipped: 0 } : { unchanged: test.unchanged }),
            opaque_original: { literal: '<img> original JSON & facts', retained: [false, null, 0] }, ...test.fields };
        s.last(action === 'all' ? '/all' : '/attach').reply(body);
        const notice = s.get(action === 'all' ? 'ps-global-status' : 'ps-slot-status-main-0'), disclosure = notice.querySelector('details');
        assert.ok(disclosure && !disclosure.open, 'malformed/journal feedback keeps complete initially collapsed Details');
        assert.equal(notice.style.color, 'var(--ps-' + test.role + ')');
        assert.equal(disclosure.querySelector('summary').style.color, notice.style.color, 'Copy summary retains warning/error role');
        const pre = disclosure.querySelector('pre'), complete = pre.textContent;
        assert.deepEqual(JSON.parse(complete.split('Response:\n').at(-1)), body, 'complete Copy source is the exact original response');
        assert.doesNotMatch(notice.innerText, /opaque_original|original JSON & facts/, 'collapsed summary does not expose the raw payload');
        for (const open of [false, true]) {
            disclosure.open = open; disclosure.dispatch('toggle');
            pre.__ptCopyButton.click(); await Promise.resolve(); await Promise.resolve();
            assert.equal(s.writes.at(-1), complete, 'problem Copy preserves the full original payload with Details open=' + open);
            assert.equal(disclosure.open, open, 'problem Copy never toggles the diagnostic cut');
        }
        assert.equal(s.requests.filter(request => request.url === (action === 'all' ? '/all' : '/attach')).length, 1);
        assert.equal(s.requests.filter(request => request.method === 'POST').length, action === 'all' ? 1 : 2, 'Copy never replays a mutation');
    }
}

async function autoSetupDetails() {
    const s = subscriptionLogPage(), id = '0123456789abcdef0123456789abcdef';
    const healthy = () => ({
        cron: { enabled: true, matches: true, running: true, expected: '0 0,6,12,18 * * * /usr/bin/pt-auto-update', actual: ['0 0,6,12,18 * * * /usr/bin/pt-auto-update'] },
        launcher: { exists: true, matches: true, executable: true }, hotplug: { enabled: false, exists: false, matches: false, executable: false },
        last_auto: { ts: '12:00 19.10.2026', id, state: 'finished', service: 'failed', outcome: 'failed', updated: 1, unchanged: 0, failed: 0, skipped: 0 }
    });
    s.last('/log').reply({ lines: ['11:58 19.10.2026|manual|updated=0|unchanged=1|failed=0', '  oldest proxy: unchanged',
        '11:59 19.10.2026|manual|updated=1|unchanged=0|failed=0', '  visible manual proxy: updated',
        '12:00 19.10.2026|auto|updated=0|unchanged=1|failed=0', '  visible automatic proxy: unchanged'] });
    s.get('ps-full-log-btn').click();
    const snapshots = { 'ps-log-wrap': await copyDisplayedLog(s, 'ps-log-wrap'), 'ps-full-log-body': await copyDisplayedLog(s, 'ps-full-log-body') };
    s.last('/auto').reply(healthy());
    const widget = s.get('ps-auto-status');
    assert.equal(widget.style.display, 'none'); assert.equal(widget.textContent, '');
    assert.equal(widget.querySelectorAll('details').length, 0, 'historical failure alone creates no setup widget or duplicate history');
    assert.equal(widget.querySelectorAll('.ps-auto-status-note').length, 0, 'healthy setup retains no persistent normal footnote');

    const body = healthy(), error = 'Cannot close launcher: errno 5 <script>literal setup IO</script>\n' + 'complete launcher read output\n'.repeat(100);
    body.launcher = { ...body.launcher, error, details: '<img> additional owned IO facts', errno: 5 };
    s.get('ps-subs-refresh').click(); s.last('/auto').reply(body);
    const disclosure = widget.querySelector('details');
    assert.ok(disclosure && !disclosure.open, 'setup IO problem keeps initially collapsed complete Details');
    assert.equal(disclosure.querySelector('summary').style.color, 'var(--ps-error)');
    const diagnostic = disclosure.querySelector('.ps-error-details');
    assert.ok(diagnostic.textContent.includes(error), 'component Details retains complete literal IO output');
    assert.ok(diagnostic.textContent.includes(body.launcher.details));
    const context = JSON.parse(diagnostic.textContent.split('Context:\n').at(-1).split('\n\nHTTP status:')[0]);
    assert.deepEqual(context.launcher, body.launcher, 'component diagnostics retain all original IO/errno facts');
    for (const open of [false, true]) {
        disclosure.open = open; disclosure.dispatch('toggle');
        for (const target of ['ps-log-wrap', 'ps-full-log-body']) {
            assert.equal(await copyDisplayedLog(s, target), snapshots[target], 'setup problem Details never contaminates Recent/Full Copy');
        }
        assert.equal(disclosure.open, open);
    }

    // A valid pending observation is neutral and has no technical Copy/error
    // component. A malformed one retains its original facts in warning Details.
    const pending = { ts: '11:59 19.10.2026', id: 'fedcba9876543210fedcba9876543210', state: 'pending', service: 'pending', outcome: 'pending', updated: 1, unchanged: 0, failed: 0, skipped: 0 };
    s.get('ps-subs-refresh').click(); s.last('/auto').reply({ ...healthy(), last_auto_pending: pending });
    assert.match(widget.innerText, /Completion pending\/not recorded/);
    assert.equal(widget.querySelectorAll('details').length, 0);
    assert.match(widget.querySelector('.ps-auto-status-note').textContent, /Completion pending\/not recorded/, 'the scoped note is conditional pending content');
    assert.doesNotMatch(widget.innerText, /Last automatic|Expected entry|updated=|Service restart|[a-f0-9]{32}/);
    const malformed = { ...pending, failed: '<img> malformed typed counter' };
    s.get('ps-subs-refresh').click(); s.last('/auto').reply({ ...healthy(), last_auto_pending: malformed });
    const warning = widget.querySelector('details');
    assert.ok(warning && !warning.open);
    assert.equal(warning.querySelector('summary').style.color, 'var(--ps-warning)');
    const original = JSON.parse(warning.querySelector('.ps-error-details').textContent.split('Context:\n').at(-1).split('\n\nHTTP status:')[0]);
    assert.deepEqual(original.last_auto_pending, malformed, 'warning Details retains the original malformed value without clamping');
    warning.open = true; warning.dispatch('toggle');
    for (const target of ['ps-log-wrap', 'ps-full-log-body']) assert.equal(await copyDisplayedLog(s, target), snapshots[target]);

    // Read-envelope failures use the shared complete-details Copy control. Both
    // collapsed/expanded activation copy exactly the same full original response.
    const failure = { error: 'Cannot read scheduling settings', details: '<script>complete settings IO</script>\n' + 'full setup read failure\n'.repeat(100), errno: 5 };
    s.get('ps-subs-refresh').click(); s.last('/auto').reply(failure);
    const failedRead = widget.querySelector('details'), pre = failedRead.querySelector('pre');
    assert.ok(pre.__ptCopyButton, 'setup read failure exposes the actual shared diagnostic Copy control');
    const complete = pre.textContent;
    assert.ok(complete.endsWith('Response body:\n' + JSON.stringify(failure)), 'setup read diagnostics retain the complete original response body');
    for (const open of [false, true]) {
        failedRead.open = open; failedRead.dispatch('toggle');
        pre.__ptCopyButton.click(); await Promise.resolve(); await Promise.resolve();
        assert.equal(s.writes.at(-1), complete, 'setup read failure Copy retains the complete diagnostic source');
        assert.equal(failedRead.open, open, 'Copy never toggles setup Details');
        for (const target of ['ps-log-wrap', 'ps-full-log-body']) assert.equal(await copyDisplayedLog(s, target), snapshots[target]);
    }
    s.get('ps-subs-refresh').click(); s.last('/auto').reply(healthy());
    assert.equal(widget.style.display, 'none'); assert.equal(widget.textContent, '');
    assert.equal(widget.querySelectorAll('details').length, 0, 'confirmed recovery removes the old diagnostic/Copy presentation');
    assert.equal(s.requests.filter(request => request.method === 'POST').length, 0, 'setup reads, observations and Copy never apply/replay updates');
    assert.equal(s.requests.filter(request => request.url === '/service').length, 0);
}

async function autoSetupTransportCopy() {
    const expected = '0 0,6,12,18 * * * /usr/bin/pt-auto-update';
    const healthy = { cron: { enabled: true, matches: true, running: true, expected, actual: [expected] },
        launcher: { exists: true, matches: true, executable: true }, hotplug: { enabled: false, exists: false, matches: false, executable: false } };
    const json = { success: false, error: 'Cannot read setup <script>literal server error</script>', errno: 5, stage: 'close',
        details: '<img src=x onerror=literal()> & untruncated server output\n' + 'complete HTTP diagnostics\n'.repeat(100),
        opaque: { retained: [0, false, null], literal: '<svg onload=literal()>' } };
    const html = '<!doctype html>\r\n<html><body><h1>Forbidden & session expired</h1><script>literal failure</script>\n' +
        '<p>complete original LuCI response</p>\n'.repeat(100) + '<img src=x onerror=literal()></body></html>\r\n\t ';
    const cases = [
        { status: 503, role: 'error', raw: '\r\n  ' + JSON.stringify(json, null, 4) + '\n\t ' },
        { status: 403, role: 'error', raw: html },
        { status: 200, role: 'warning', raw: html },
        { status: 200, role: 'warning', raw: '\n {"cron": <script>malformed JSON</script>, "tail": "exact last bytes"}\r\n ' },
        { status: 200, role: 'warning', raw: '\r\n [1,{"literal":"<img> non-object array","retained":[null,false]}]\t ' },
        ...['null', 'false', '7', '"OFF"'].map(raw => ({ status: 200, role: 'warning', raw: '\n\t ' + raw + '\r\n ' }))
    ];
    for (const test of cases) {
        const s = subscriptionLogPage(), request = s.last('/auto');
        s.last('/log').reply({ lines: ['11:58 19.10.2026|manual|updated=0|unchanged=1|failed=0', '  oldest snapshot: unchanged',
            '11:59 19.10.2026|manual|updated=1|unchanged=0|failed=0', '  current manual snapshot: updated',
            '12:00 19.10.2026|auto|updated=0|unchanged=1|failed=0', '  current automatic snapshot: unchanged'] });
        s.get('ps-full-log-btn').click();
        const snapshots = { 'ps-log-wrap': await copyDisplayedLog(s, 'ps-log-wrap'), 'ps-full-log-body': await copyDisplayedLog(s, 'ps-full-log-body') };
        assert.equal(request.timeout, 30000);
        request.reply(test.raw, test.status);
        const widget = s.get('ps-auto-status'), disclosure = widget.querySelector('details');
        assert.ok(disclosure && !disclosure.open);
        assert.equal(widget.style.color, 'var(--ps-' + test.role + ')');
        assert.equal(disclosure.querySelector('summary').style.color, widget.style.color);
        const pre = disclosure.querySelector('pre'), full = pre.textContent;
        assert.ok(full.endsWith('Response body:\n' + test.raw), 'complete raw body survives HTTP/schema failure without reserialization, truncation or whitespace loss');
        assert.ok(pre.__ptCopyButton, 'transport diagnostics expose the actual complete-details Copy control');
        for (const tag of ['script', 'img', 'svg']) assert.equal(pre.querySelectorAll(tag).length, 0, 'HTML-shaped response text never becomes ' + tag + ' nodes');
        assert.equal(widget.querySelectorAll('script').length, 0); assert.equal(widget.querySelectorAll('img').length, 0);
        assert.equal(widget.querySelectorAll('.ps-auto-status-note').length, 0, 'HTTP/malformed response does not create a persistent normal footer');
        assert.doesNotMatch(widget.innerText, /\bOFF\b|disabled|no cron entry|no hook|not required/i, 'unknown settings are not presented as OFF');
        const reads = s.requests.length;
        for (const open of [false, true]) {
            disclosure.open = open; disclosure.dispatch('toggle');
            pre.__ptCopyButton.click(); await Promise.resolve(); await Promise.resolve();
            const copied = s.writes.at(-1);
            assert.equal(copied, full, 'Copy reads the complete diagnostic PRE, not its short summary');
            assert.ok(copied.endsWith('Response body:\n' + test.raw), 'Copy preserves every raw response byte, including CRLF and literal HTML-shaped text');
            assert.equal(disclosure.open, open, 'diagnostic Copy never toggles Details');
            for (const target of ['ps-log-wrap', 'ps-full-log-body']) assert.equal(await copyDisplayedLog(s, target), snapshots[target], 'HTTP failures add no synthetic history/Copy record');
        }
        assert.equal(s.requests.length, reads, 'Copy has no network/mutation side effects');
        s.get('ps-subs-refresh').click(); s.last('/auto').reply(healthy);
        assert.equal(widget.style.display, 'none'); assert.equal(widget.textContent, '');
        assert.equal(widget.querySelectorAll('details').length, 0);
        assert.equal(s.requests.filter(r => r.method === 'POST').length, 0);
        assert.equal(s.requests.filter(r => r.url === '/service').length, 0);
    }
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
    await subscriptionSnapshots();
    await subscriptionMutationDetails();
    await autoSetupDetails();
    await autoSetupTransportCopy();
    console.log('Frontend clipboard: PASS (exact full text, secure/HTTP/denied paths, selection+scroll preservation, cleanup, actual compact subscription snapshots, same-ID blocks, failed-read retention, collapsed/expanded mutation and exact raw HTTP/schema diagnostics, conditional pending note, history isolation and truthful feedback)');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
