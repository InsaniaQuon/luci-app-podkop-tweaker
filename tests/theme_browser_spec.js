// theme_browser_spec.js | v4.1.0 | 09.10.2026 | In-frame clipboard icons and Stubby guidance
// node tests/theme_browser_spec.js --browser <installed Chromium/Edge executable>
// Add --diagnostics-only, --update-only or --copy-only for focused form checks.
// All generated files and the isolated browser profile live under ROOT/tmp.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const root = path.dirname(repo);
const appVersion = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/controller/podkop-tweaker.lua'), 'utf8').match(/APP_VERSION = "([^"]+)"/)[1];
const browser = process.argv[process.argv.indexOf('--browser') + 1];
const diagnosticsOnly = process.argv.includes('--diagnostics-only');
const updateOnly = process.argv.includes('--update-only');
const copyOnly = process.argv.includes('--copy-only');
const focused = diagnosticsOnly || updateOnly || copyOnly;
if ([diagnosticsOnly, updateOnly, copyOnly].filter(Boolean).length > 1) throw new Error('Choose one focused mode');
if (!process.argv.includes('--browser') || !browser) throw new Error('Supply --browser <installed executable>');
const artifacts = path.join(root, 'tmp', 'theme-smoke');
assert.ok(fs.existsSync(path.dirname(artifacts)), 'ROOT/tmp must exist');
fs.mkdirSync(artifacts, { recursive: true });

// Theme-owned rules from Argon 2.4.x, including unchanged light variables,
// brown h4, important native input/button backgrounds, and table overrides.
// These deliberately conflict with app styles; computed CSS must still work.
const lightTheme = `
:root{--background-color:#f4f5f7;--primary:#5e72e4;--dark-primary:#483d8b}
*{box-sizing:border-box}body{margin:0;padding:24px;background:#f4f5f7;color:#32325d;font:14px Arial}
.cbi-section{background:#fff;border:0;box-shadow:0 0 10px rgba(0,0,0,.2)}
h2,h3{padding:12px 16px;background:#fff;color:#32325d}h4{padding:12px 16px;color:#8c6900;background:#fff}
table td{color:#8898aa}input,select,textarea{background:#fff!important;color:#333;border:1px solid #ddd!important;padding:8px}
.btn{background:#f0f0f0;color:#8898aa;padding:8px 12px;border:0}.cbi-button-apply{background:var(--primary)!important;color:#fff!important}
`;
const darkTheme = `
body,.main-right{background:#1e1e1e;color:#ccc}
.cbi-section{background:#1e1e1e!important}h2,h3{background:#333;color:#ccc}h4{background:#1e1e1f;color:#8c6900}
div>table>tbody>tr:nth-child(2n){background:#252526}table td{color:#ccc}table th{background:#252526;border-bottom:1px solid #000!important}
.btn,button,input,select{border:1px solid #3c3c3c!important}input,select{background:transparent!important;color:#ccc}select{background:#1e1e1e!important}
.cbi-button-apply{background:var(--dark-primary)!important;color:#fff!important}
`;

const scenarios = {
    'argon-auto-dark': { os: 'dark', theme: 'argon', mode: 'normal', media: '(prefers-color-scheme: dark)', darkLink: true, late: true, dark: true },
    'argon-force-dark': { os: 'light', theme: 'argon', mode: 'dark', darkLink: true, dark: true },
    'argon-force-light': { os: 'dark', theme: 'argon', mode: 'light', dark: false },
    'argon-versioned-css': { os: 'dark', theme: '', mode: '', darkLink: true, media: '(prefers-color-scheme: dark)', dark: true },
    'argon-inline-legacy': { os: 'dark', theme: '', mode: '', inline: true, dark: true },
    'bootstrap-dark': { os: 'light', theme: 'bootstrap', mode: '', bootstrap: true, inline: true, dark: true },
    'bootstrap-light': { os: 'dark', theme: 'bootstrap', mode: '', bootstrap: false, dark: false }
};

function fixture(name, profile) {
    const s = scenarios[name];
    const app = `<link rel="stylesheet" href="/common.css?v=${appVersion}">`;
    const darkLink = s.darkLink ? `<link rel="stylesheet" href="/luci-static/argon/css/dark.css?v=2.4.8#version" ${s.media ? `media="${s.media}"` : ''}>` : '';
    return `<!doctype html><html ${s.bootstrap === undefined ? '' : `data-darkmode="${s.bootstrap}"`}><head><meta charset="utf-8">
<link rel="stylesheet" href="/luci-static/argon/css/cascade.css?v=2.4.8">
${s.late ? app + darkLink : darkLink + app}
${s.inline ? `<style>${darkTheme}</style>` : ''}
<style>.fixture-grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.ps-editor-wrap{height:190px}h3{margin:0 0 12px}.cbi-section{margin-bottom:18px}</style>
</head><body><div class="main-right"><div id="cbi-podkop-tweaker">
<span hidden id="ps-theme-context" data-theme="${s.theme}" data-mode="${s.mode}" data-profile="${profile}" data-mono-size="${profile === 'contrast' ? '18' : '13'}" data-mono-weight="${profile === 'contrast' ? '500' : '400'}" data-mono-line-height="${profile === 'contrast' ? '1.8' : '1.6'}"></span>
<h2>Podkop Tweaker — ${name}</h2><div class="fixture-grid">
<section class="cbi-section" id="editor-card"><h3>Podkop / Stubby / Sing-box Config</h3>
<span class="ps-config-path">/etc/config/podkop</span><div class="ps-editor-wrap">
<div class="ps-line-numbers" id="gutter">1<br>2<br>3<br>4</div>
<textarea class="ps-config-editor" id="editor">config settings 'settings'
    option dns_type 'udp'
    option user_domains_text 'atom.io
github.com'</textarea></div><button id="apply" class="btn cbi-button cbi-button-apply">Save Changes</button><span id="live-status">Running</span></section>
<section class="cbi-section" id="dns-card"><h3>Diagnostics</h3>
<div class="ps-dns-chain" id="chain"><span class="ps-chain-line">LAN → dnsmasq → sing-box → Stubby</span></div>
<h4 id="log-title">Run Log</h4><div class="ps-log-viewer-wrap" id="log"><div class="ps-log-event">
<div class="ps-log-summary" id="log-summary"><span class="ps-log-ts" id="timestamp">08.10.2026 12:30</span> DNS: <strong id="diag-ok" class="ps-status-updated">OK</strong> <strong id="diag-fail" class="ps-status-failed">FAIL</strong></div>
<div class="ps-log-details"><div class="ps-log-detail-line" id="log-detail">resolver: 127.0.0.53<br>http_status: 200</div></div></div></div>
<div class="ps-diff-body"><div class="ps-diff-add" id="diff-added">+ option enabled '1'</div><div class="ps-diff-del" id="diff-removed">- option enabled '0'</div></div></section>
<section class="cbi-section" id="subscriptions-card"><h3>Subscriptions</h3>
<div class="ps-sub-section"><div class="ps-sub-section-header" id="sub-header"><span class="ps-sub-section-name">main</span><span class="ps-sub-section-meta" id="sub-meta">URLTest · 2 proxies</span></div>
<div class="ps-sub-slot" id="sub-slot"><span class="ps-sub-slot-name">Example server</span><span class="ps-sub-slot-detail"> — vless · TLS</span></div></div>
<h4>Update Log</h4><div class="ps-log-viewer-full" id="history"><div class="ps-log-event"><span class="ps-log-ts">12:35</span> main: updated<br><div class="ps-log-detail-line">updated=1, unchanged=0, failed=0</div></div></div></section>
<section class="cbi-section" id="about-card"><h3>About</h3><div class="ps-disclaimer" id="disclaimer"><strong>Disclaimer</strong><p id="disclaimer-text">Podkop Tweaker is an independent third-party tool and is not affiliated with the Podkop project.</p></div>
<div class="ps-warning-box" id="warning">Config contains credentials.</div><div class="ps-danger-box" id="danger">Service restart failed.</div><table class="ps-sysinfo-table"><tbody><tr><th>Service</th><th>Version</th></tr><tr><td>Argon Theme</td><td class="ps-sysinfo-value" id="table-value">2.4.7 <span class="ps-ver-outdated" id="update-available">(Update available 2.4.8)</span><span id="install-error"></span></td></tr></tbody></table></section>
</div></div></div><input id="outside" value="Theme-owned control outside the application">
<div class="ps-modal" id="modal" style="display:none"><div class="ps-modal-content"><h3>Attach subscription</h3><input id="modal-input" class="ps-sub-url-input" value="https://example.test/sub"><label class="ps-check-item"><input id="modal-check" type="checkbox" checked><span>Import settings</span></label><label class="ps-diff-toggle"><input id="diff-check" type="checkbox" checked>Only changed</label><pre class="ps-error-details" id="error-details">ERROR: unable to select packages</pre><button class="btn cbi-button" id="modal-close">Close</button></div></div>
<script>window.PT={urls:{},csrf:'test'};</script><script src="/common.js?v=${appVersion}"></script>
<script>document.getElementById('live-status').style.color=PT.color('success');PT.setErr(document.getElementById('install-error'),'Theme package installation failed','ERROR: ucode dependency conflict');document.querySelector('#install-error summary').id='install-summary';</script></body></html>`;
}

const colorDefaults = {
    color_success_light: '#00be00', color_error_light: '#ff0000', color_warning_light: '#ff8c42',
    color_success_dark: '#00ff00', color_error_dark: '#ff8080', color_warning_dark: '#ffbd42'
};
const defaults = { profile: 'soft', mono_font_size: '13', mono_font_weight: '400', mono_line_height: '1.6', ...colorDefaults };
let appearanceState = { ...defaults, profile: 'contrast', mono_font_size: '18', mono_font_weight: '500', mono_line_height: '1.8' };
const appearanceRequests = [];
let appearanceFailure = false;
function appearanceFixture() {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/argon.htm'), 'utf8');
    const colorAttrs = Object.keys(colorDefaults).map(key => `data-${key.replaceAll('_', '-')}="${appearanceState[key]}"`).join(' ');
    const marker = `<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="${appearanceState.profile}" data-mono-size="${appearanceState.mono_font_size}" data-mono-weight="${appearanceState.mono_font_weight}" data-mono-line-height="${appearanceState.mono_line_height}" ${colorAttrs}></span>`;
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"')).replace('<%+podkop-tweaker/tabs%>', marker);
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = { csrf: 'browser-token', urls: { typography: '/api/typography', appearance: '/api/appearance', appearanceSave: '/api/appearance-save', appearanceReset: '/api/appearance-reset', appearanceColorsReset: '/api/appearance-colors-reset' } };
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}${view.match(/<style>([\s\S]*?)<\/style>/)[1]}</style><link rel="stylesheet" href="/common.css?v=${appVersion}"></head><body><div class="main-right">${markup}</div><script>window.PT=${JSON.stringify(bootstrap)};</script><script src="/common.js?v=${appVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

function diagnosticsFixture() {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/diagnostics.htm'), 'utf8');
    const marker = '<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="soft"></span>';
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"'))
        .replace('<%+podkop-tweaker/tabs%>', marker).replace(/<%=url\('admin\/services\/podkop'\)%>/g, '/admin/services/podkop');
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = { csrf: 'browser-token', urls: { chainInfo: '/testapi/chain', dnsObservationStart: '/testapi/dns-start', dnsObservationResults: '/testapi/dns-results' } };
    // Provider probes are mapped to a local image: exercise real browser events
    // without sending DNS/HTTP test traffic to a third-party from the host.
    const probes = `window.probeURLs=[];window.Image=class{constructor(){this.img=document.createElement('img');this.img.onload=()=>this.onload&&this.onload();this.img.onerror=()=>this.onerror&&this.onerror();}set src(url){if(!url)return;window.probeURLs.push(url);this.img.src='/testapi/probe.png';}};`;
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}${view.match(/<style>([\s\S]*?)<\/style>/)[1]}</style><link rel="stylesheet" href="/common.css?v=${appVersion}"></head><body><div class="main-right">${markup}</div><script>window.PT=${JSON.stringify(bootstrap)};${probes}</script><script src="/common.js?v=${appVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

const localApplyRequests = [];
let localApplyFailure = false;
function updateFixture(mode) {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/update.htm'), 'utf8');
    const marker = '<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="soft"></span>';
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"')).replace('<%+podkop-tweaker/tabs%>', marker);
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = { csrf: 'browser-token', urls: { upload: '/testapi/local-upload?case=' + mode, apply: '/testapi/local-apply?case=' + mode } };
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}</style><link rel="stylesheet" href="/common.css?v=${appVersion}"></head><body><div class="main-right">${markup}</div><script>window.PT=${JSON.stringify(bootstrap)};</script><script src="/common.js?v=${appVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

// Use real page markup/bootstrap/scripts; intercept native copy events so the
// HTTP fallback is exercised without changing the host OS clipboard.
function copyFixture(name) {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker', name + '.htm'), 'utf8');
    const marker = '<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="soft"></span>';
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"')).replace('<%+podkop-tweaker/tabs%>', marker);
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = scripts[0][1].replace(/<%=([\s\S]*?)%>/g, (_, expr) => {
        if (expr.includes('app_version')) return appVersion;
        if (expr.includes('csrf_token')) return 'browser-token';
        const endpoint = expr.match(/api\/([^"']+)/);
        return endpoint ? '/copyapi/' + endpoint[1] : '';
    });
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}</style><link rel="stylesheet" href="/common.css?v=${appVersion}"></head><body><div class="main-right">${markup}</div><script>${bootstrap};window.copyWrites=[];Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined});document.addEventListener('copy',event=>{window.copyWrites.push(document.activeElement.value);event.preventDefault();});</script><script src="/common.js?v=${appVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

const copyLogLines = Array.from({ length: 15 }, (_, i) => [`09.10.2026 12:${String(i).padStart(2, '0')}|manual|updated=1|unchanged=0|failed=0`, `  main-${i}: updated`, `    detail ${i}: <script>plain text</script>`]).flat();

const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/copy-form') {
        res.setHeader('Content-Type', 'text/html'); res.end(copyFixture(url.searchParams.get('view')));
    } else if (url.pathname.startsWith('/copyapi/')) {
        const endpoint = url.pathname.slice('/copyapi/'.length);
        if (['read_config', 'read_stubby_config', 'read_singbox_config'].includes(endpoint)) {
            res.setHeader('Content-Type', 'text/plain'); res.end("config settings 'settings'\n    option enabled '1'\n");
        } else {
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify(endpoint === 'read_update_log' ? { lines: copyLogLines } : endpoint === 'subscription_state' ? { sections: [] } : { running: false, status: 'fixed' }));
        }
    } else if (url.pathname === '/local-update-form') {
        res.setHeader('Content-Type', 'text/html'); res.end(updateFixture(url.searchParams.get('case')));
    } else if (url.pathname === '/testapi/local-upload' || url.pathname === '/testapi/local-apply') {
        let body = ''; req.on('data', data => { body += data; }); req.on('end', () => {
            res.setHeader('Content-Type', 'application/json');
            const mode = url.searchParams.get('case');
            if (url.pathname.endsWith('-upload')) {
                if (!body.includes('name="token"') || !body.includes('browser-token')) { res.statusCode = 403; res.end('{}'); return; }
                const newer = appVersion.split('.').map((n, i) => i === 2 ? +n + 1 : n).join('.');
                res.end(JSON.stringify({ success: true, current_version: appVersion, archive_version: mode === 'same' ? appVersion : mode === 'newer' ? newer : '4.7.0', same_version: mode === 'same', can_update: mode === 'newer' }));
            } else {
                const params = Object.fromEntries(new URLSearchParams(body));
                if (params.token !== 'browser-token') { res.statusCode = 403; res.end('{}'); return; }
                localApplyRequests.push({ mode, params });
                res.end(JSON.stringify(localApplyFailure ? { success: false, error: 'Update application failed', details: 'mock IO failure' } : { success: true, reinstalled: mode === 'same' }));
            }
        });
    } else if (url.pathname === '/diagnostics-form') {
        res.setHeader('Content-Type', 'text/html'); res.end(diagnosticsFixture());
    } else if (url.pathname === '/admin/services/podkop') {
        res.setHeader('Content-Type', 'text/html');
        res.end(`<!doctype html><html><body><ul class="cbi-tabmenu"><li data-tab="diagnostic"><a href="#">Diagnostics</a></li></ul><div id="tabs" data-initialized="false"><div id="pane" data-tab="diagnostic" data-tab-active="false">Native Podkop diagnostics</div></div><script>setTimeout(()=>{document.querySelector('a').onclick=(event)=>{event.preventDefault();document.getElementById('pane').setAttribute('data-tab-active','true');};document.getElementById('tabs').setAttribute('data-initialized','true');},300);</script></body></html>`);
    } else if (url.pathname === '/testapi/chain') {
        res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ resolvers: [] }));
    } else if (url.pathname === '/testapi/probe.png') {
        res.setHeader('Content-Type', 'image/png'); res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jPioAAAAASUVORK5CYII=', 'base64'));
    } else if (url.pathname === '/testapi/dns-start' || url.pathname === '/testapi/dns-results') {
        let body = ''; req.on('data', data => { body += data; }); req.on('end', () => {
            res.setHeader('Content-Type', 'application/json');
            if (new URLSearchParams(body).get('token') !== 'browser-token') { res.statusCode = 403; res.end('{}'); return; }
            res.end(JSON.stringify(url.pathname.endsWith('-start') ? { success: true, id: 'native', hosts: Array.from({ length: 6 }, (_, i) => `${i + 1}.native.bash.ws`) } :
                { success: true, complete: true, provider: 'bash.ws', scope: 'current_browser', resolvers: [{ ip: '1.1.1.1', asn: 'AS13335' }], control_request_ips: [{ ip: '203.0.113.1' }], control_request_scope: 'router', conclusion: 'Observations collected, compare intended policy' }));
        });
    } else if (url.pathname === '/api/appearance' || url.pathname === '/api/typography') {
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify(url.pathname.endsWith('/appearance') ? { settings: appearanceState } : { settings: { font_size: '17', font_weight: '550', line_height: '1.7' }, stale: false }));
    } else if (['/api/appearance-save', '/api/appearance-reset', '/api/appearance-colors-reset'].includes(url.pathname)) {
        let body = '';
        req.on('data', data => { body += data; });
        req.on('end', () => {
            const form = new URLSearchParams(body);
            res.setHeader('Content-Type', 'application/json');
            if (form.get('token') !== 'browser-token') { res.statusCode = 403; res.end(JSON.stringify({ error: 'Invalid token' })); return; }
            appearanceRequests.push({ path: url.pathname, params: Object.fromEntries(form) });
            if (appearanceFailure) { appearanceFailure = false; res.end(JSON.stringify({ success: false, error: 'Cannot commit appearance settings' })); return; }
            if (url.pathname === '/api/appearance-colors-reset') appearanceState = { ...appearanceState, ...colorDefaults };
            else if (url.pathname === '/api/appearance-reset') {
                for (const key of ['profile', 'mono_font_size', 'mono_font_weight', 'mono_line_height']) appearanceState[key] = defaults[key];
            } else appearanceState = Object.fromEntries(Object.keys(defaults).map(key => [key, form.get(key)]));
            res.end(JSON.stringify({ success: true, settings: appearanceState }));
        });
    } else if (url.pathname === '/appearance-form') {
        res.setHeader('Content-Type', 'text/html');
        res.end(appearanceFixture());
    } else if (url.pathname === '/common.css' || url.pathname === '/common.js') {
        res.setHeader('Content-Type', url.pathname.endsWith('.css') ? 'text/css' : 'text/javascript');
        res.end(fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker', url.pathname.slice(1))));
    } else if (url.pathname.endsWith('/cascade.css') || url.pathname.endsWith('/dark.css')) {
        res.setHeader('Content-Type', 'text/css');
        res.end(url.pathname.endsWith('/dark.css') ? darkTheme : lightTheme);
    } else if (scenarios[url.pathname.slice(1)]) {
        res.setHeader('Content-Type', 'text/html');
        res.end(fixture(url.pathname.slice(1), url.searchParams.get('profile') === 'contrast' ? 'contrast' : 'soft'));
    } else { res.statusCode = 404; res.end(); }
});

function connect(endpoint) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(endpoint);
        const pending = new Map();
        let seq = 0;
        ws.addEventListener('error', reject);
        ws.addEventListener('message', event => {
            const result = JSON.parse(String(event.data));
            if (!result.id) return;
            const p = pending.get(result.id);
            if (!p) return;
            pending.delete(result.id);
            clearTimeout(p.timer);
            if (result.error) p.reject(new Error(JSON.stringify(result.error)));
            else p.resolve(result.result);
        });
        ws.addEventListener('open', () => resolve({
            call(method, params = {}, sessionId) {
                return new Promise((resolve, reject) => {
                    const id = ++seq;
                    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 15000);
                    pending.set(id, { resolve, reject, timer });
                    ws.send(JSON.stringify({ id, method, params, sessionId }));
                });
            },
            close() { ws.close(); }
        }));
    });
}

async function main() {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const child = spawn(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--remote-debugging-port=0', `--user-data-dir=${path.join(artifacts, 'profile')}`], { stdio: ['ignore', 'ignore', 'pipe'] });
    let cdp;
    try {
        const endpoint = await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('No DevTools endpoint from browser')), 30000);
            let stderr = '';
            child.on('error', reject);
            child.stderr.on('data', data => {
                stderr += String(data);
                const found = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
                if (found) { clearTimeout(timer); resolve(found[1]); }
            });
        });
        cdp = await connect(endpoint);
        const target = await cdp.call('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.call('Target.attachToTarget', { targetId: target.targetId, flatten: true });
        await cdp.call('Page.enable', {}, sessionId);
        await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
        const evaluate = async expression => {
            const result = await cdp.call('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
            if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
            return result.result.value;
        };
        const wait = async (expression, expected) => {
            for (let i = 0; i < 100; i++) {
                if (await evaluate(expression) === expected) return;
                await new Promise(resolve => setTimeout(resolve, 30));
            }
            throw new Error(`Waiting for ${expression} === ${expected} failed`);
        };
        const screenshot = async (name, width) => {
            const metrics = await cdp.call('Page.getLayoutMetrics', {}, sessionId);
            const shot = await cdp.call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height: Math.ceil(metrics.cssContentSize.height), scale: 1 } }, sessionId);
            fs.writeFileSync(path.join(artifacts, name + '.png'), Buffer.from(shot.data, 'base64'));
        };
        const setColor = async (role, scheme, value, picker = false) => {
            const id = `ps-color-${role}-${scheme}` + (picker ? '' : '-hex');
            await evaluate(`(() => {const el=document.getElementById(${JSON.stringify(id)});el.value=${JSON.stringify(value)};el.dispatchEvent(new Event('input'));})()`);
        };
        const reports = [];
        for (const [scenario, s, profile] of (focused ? [] : Object.entries(scenarios)).flatMap(([name, settings]) => ['soft', 'contrast'].map(profile => [name, settings, profile]))) {
            const name = scenario + (profile === 'contrast' ? '-contrast' : '');
            await cdp.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: s.os }] }, sessionId);
            await cdp.call('Page.navigate', { url: base + '/' + scenario + '?profile=' + profile }, sessionId);
            await wait('document.readyState', 'complete');
            await wait('document.documentElement.getAttribute("data-pt-dark")', String(s.dark));
            const result = await evaluate(`(() => {
                function rgb(color) { return color.match(/[\\d.]+/g).slice(0,3).map(Number); }
                function lum(color) { const c=rgb(color).map(v=>{v/=255;return v<=.04045?v/12.92:Math.pow((v+.055)/1.055,2.4)});return c[0]*.2126+c[1]*.7152+c[2]*.0722; }
                function ratio(a,b) { const x=lum(a),y=lum(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05); }
                function bg(el) { const stack=[];for(let e=el;e;e=e.parentElement)stack.unshift(e);let paint=[255,255,255];for(const e of stack){const values=getComputedStyle(e).backgroundColor.match(/[\\d.]+/g).map(Number);const a=values.length>3?values[3]:1;paint=paint.map((v,i)=>values[i]*a+v*(1-a));}return 'rgb('+paint.map(Math.round).join(', ')+')'; }
                const ids=['editor','gutter','chain','log-summary','log-detail','timestamp','sub-header','sub-meta','sub-slot','history','disclaimer-text','warning','danger','table-value','apply','live-status','log-title','diag-ok','diag-fail','diff-added','diff-removed','update-available','install-summary'];
                const colors=ids.map(id=>{const e=document.getElementById(id),c=getComputedStyle(e);return {id,fg:c.color,bg:bg(e),contrast:ratio(c.color,bg(e))};});
                const panelIds=['editor-card','editor','gutter','chain','log','sub-header','sub-slot','history','disclaimer'];
                const panels=Object.fromEntries(panelIds.map(id=>[id,getComputedStyle(document.getElementById(id)).backgroundColor]));
                const mono=Object.fromEntries(['editor','gutter','chain','log','history'].map(id=>{const c=getComputedStyle(document.getElementById(id));return [id,{size:c.fontSize,weight:c.fontWeight,height:c.lineHeight}];}));
                return {colors,panels,mono,source:document.documentElement.getAttribute('data-pt-scheme-source'),outside:getComputedStyle(document.getElementById('outside')).color};
            })()`);
            const statusRoles = { warning: 'warning', danger: 'error', 'live-status': 'success', 'diag-ok': 'success', 'diag-fail': 'error', 'diff-added': 'success', 'diff-removed': 'error', 'update-available': 'warning', 'install-summary': 'error' };
            for (const item of result.colors) {
                const role = statusRoles[item.id];
                if (role) {
                    const hex = colorDefaults[`color_${role}_${s.dark ? 'dark' : 'light'}`];
                    const rgb = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
                    assert.equal(item.fg, `rgb(${rgb.join(', ')})`, `${name}: ${item.id} must render the exact status preset`);
                }
                if (!s.dark && role) assert.ok(Number.isFinite(item.contrast) && item.contrast >= 1);
                else assert.ok(item.contrast >= 4.5, `${name}: ${item.id} contrast ${item.contrast.toFixed(2)}:1 (${item.fg} / ${item.bg})`);
            }
            assert.notEqual(result.panels['editor-card'], result.panels.editor);
            assert.notEqual(result.panels.editor, result.panels.gutter);
            assert.notEqual(result.panels['editor-card'], result.panels.log);
            assert.notEqual(result.panels['sub-header'], result.panels['sub-slot']);
            for (const item of Object.values(result.mono)) {
                assert.equal(item.size, profile === 'contrast' ? '18px' : '13px');
                assert.equal(item.weight, profile === 'contrast' ? '500' : '400');
                assert.ok(Math.abs(parseFloat(item.height) - (profile === 'contrast' ? 32.4 : 20.8)) < 0.01);
            }
            assert.equal(await evaluate('getComputedStyle(document.getElementById("editor")).whiteSpace'), 'pre', 'font-size changes must not wrap config lines out of sync with the gutter');
            if (s.dark) for (const [id, color] of Object.entries(result.panels)) assert.ok(color.match(/\d+/g).slice(0,3).every(n => +n < 100), `${name}: ${id} is light (${color})`);
            await evaluate(`document.getElementById('modal').style.display='flex'`);
            const modal = await evaluate(`(() => {const input=getComputedStyle(document.getElementById('modal-input')),card=getComputedStyle(document.querySelector('.ps-modal-content')),check=getComputedStyle(document.getElementById('modal-check')),diff=getComputedStyle(document.getElementById('diff-check'));return {input:input.backgroundColor,card:card.backgroundColor,color:input.color,checkbox:check.width,diff:diff.width};})()`);
            assert.notEqual(modal.input, modal.card, `${name}: modal input merges with the card`);
            assert.equal(modal.checkbox, '16px');
            assert.equal(modal.diff, '14px', 'load-bearing custom diff checkbox must retain its dimensions');
            await evaluate(`document.getElementById('modal').style.display='none'`);
            reports.push({ name, profile, ...result, modal });
            if (name === 'argon-auto-dark' || name === 'argon-force-light') {
                await screenshot(name, 1440);
            }
            if (name === 'argon-auto-dark') {
                await evaluate(`PT.applyAppearance({color_success_light:'#007700',color_success_dark:'#00ee22',color_error_light:'#aa2222',color_error_dark:'#ff6677',color_warning_light:'#aa5500',color_warning_dark:'#ffbb00'})`);
                assert.equal(await evaluate('getComputedStyle(document.getElementById("live-status")).color'), 'rgb(0, 238, 34)');
                assert.equal(await evaluate('getComputedStyle(document.getElementById("diff-added")).backgroundColor'), 'rgba(0, 238, 34, 0.1)', 'tints must use the custom color channels');
                await cdp.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] }, sessionId);
                await wait('document.documentElement.getAttribute("data-pt-dark")', 'false');
                const changed = await evaluate('getComputedStyle(document.getElementById("live-status")).color');
                assert.notEqual(changed, result.colors.find(c => c.id === 'live-status').fg, 'existing status must recolor live');
                assert.equal(changed, 'rgb(0, 119, 0)', 'OS scheme changes must select saved light colors');
                assert.equal(await evaluate('getComputedStyle(document.getElementById("diff-added")).backgroundColor'), 'rgba(0, 119, 0, 0.06)');
                await cdp.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] }, sessionId);
                await wait('document.documentElement.getAttribute("data-pt-dark")', 'true');
                assert.equal(await evaluate('getComputedStyle(document.getElementById("live-status")).color'), 'rgb(0, 238, 34)');
            }
            console.log(`PASS ${name}: ${result.colors.length} computed text contrasts, distinct surfaces, modal`);
        }
        // Execute the real Argon Config form code, not a hand-written imitation.
        if (!focused) {
        await cdp.call('Page.navigate', { url: base + '/appearance-form' }, sessionId);
        await wait('document.readyState', 'complete');
        await wait('document.getElementById("ps-appearance-save").disabled', false);
        assert.equal(await evaluate('document.documentElement.style.fontSize'), '', 'loading the page must not apply global typography preview');
        assert.equal(await evaluate('document.body.style.fontWeight'), '', 'appearance must not change global font weight');
        assert.equal(await evaluate('document.getElementById("ps-mono-size").value'), '18');
        const statusColors = await evaluate(`[...document.querySelectorAll('.ps-appearance-statuses span')].map(el=>getComputedStyle(el).color)`);
        await evaluate(`(() => {for(const [id,value] of Object.entries({'ps-appearance-profile':'soft','ps-mono-size':'14','ps-mono-weight':'400','ps-mono-height':'1.5'})){const el=document.getElementById(id);el.value=value;el.dispatchEvent(new Event(el.tagName==='SELECT'?'change':'input'));}})()`);
        assert.deepEqual(appearanceState, { ...defaults, profile: 'contrast', mono_font_size: '18', mono_font_weight: '500', mono_line_height: '1.8' }, 'live preview must not write settings');
        const preview = await evaluate(`(() => {const e=getComputedStyle(document.getElementById('ps-appearance-editor')),g=getComputedStyle(document.getElementById('ps-appearance-gutter'));return {size:e.fontSize,weight:e.fontWeight,height:e.lineHeight,gutter:g.lineHeight,status:[...document.querySelectorAll('.ps-appearance-statuses span')].map(el=>getComputedStyle(el).color)};})()`);
        assert.equal(preview.size, '14px');
        assert.equal(preview.weight, '400');
        assert.equal(preview.height, '21px');
        assert.equal(preview.gutter, preview.height);
        assert.deepEqual(preview.status, statusColors, 'soft profile must not dim status colors');
        await evaluate('document.getElementById("ps-appearance-save").click()');
        await wait('document.getElementById("ps-appearance-status").textContent', 'Appearance saved.');
        assert.deepEqual(appearanceState, { ...defaults, mono_font_size: '14', mono_line_height: '1.5' });
        assert.equal(appearanceRequests[0].params.token, 'browser-token');

        // Real HEX and native-picker events; custom colors apply exactly in both previews.
        const customColors = {
            color_success_light: '#007700', color_error_light: '#aa2222', color_warning_light: '#aa5500',
            color_success_dark: '#00ee22', color_error_dark: '#ff6677', color_warning_dark: '#ffbb00'
        };
        for (const [key, value] of Object.entries(customColors)) {
            const [, role, scheme] = key.split('_');
            await setColor(role, scheme, value.toUpperCase(), role === 'warning');
        }
        assert.equal(await evaluate('document.getElementById("ps-color-success-dark").value'), '#00ee22', 'HEX editing must synchronize the picker');
        assert.equal(await evaluate('document.getElementById("ps-color-warning-dark-hex").value'), '#ffbb00', 'picker editing must synchronize HEX');
        const colorPreview = await evaluate(`(() => {
            const rgb=s=>s.match(/[\\d.]+/g).map(Number);
            const lum=c=>c.slice(0,3).map(v=>{v/=255;return v<=.04045?v/12.92:Math.pow((v+.055)/1.055,2.4)}).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
            const ratio=(a,b)=>(Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
            return ['light','dark'].flatMap(scheme=>['success','error','warning'].map(role=>{
                const sample=document.getElementById('ps-color-preview-'+role+'-'+scheme),c=getComputedStyle(sample),bg=rgb(getComputedStyle(sample.closest('.ps-color-sample')).backgroundColor),tint=rgb(c.backgroundColor),fg=rgb(c.color);
                const alpha=tint.length>3?tint[3]:1,paint=bg.map((v,i)=>v*(1-alpha)+tint[i]*alpha),metric=document.getElementById('ps-color-contrast-'+role+'-'+scheme).textContent.match(/Contrast: ([\\d.]+):1; tinted: ([\\d.]+):1/);
                return {scheme,role,fg:c.color,tint:c.backgroundColor,plain:ratio(fg,bg),tinted:ratio(fg,paint),shown:metric.slice(1).map(Number)};
            }));
        })()`);
        for (const item of colorPreview) {
            const rgb = customColors[`color_${item.role}_${item.scheme}`].match(/[\da-f]{2}/g).map(v => parseInt(v, 16));
            assert.equal(item.fg, `rgb(${rgb.join(', ')})`);
            assert.ok(Math.abs(item.plain - item.shown[0]) < 0.01, 'plain contrast label must match computed CSS');
            assert.ok(Math.abs(item.tinted - item.shown[1]) < 0.01, 'tinted contrast label must match computed CSS');
        }
        await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode','light')`);
        await wait('document.documentElement.getAttribute("data-pt-dark")', 'false');
        assert.equal(await evaluate('getComputedStyle(document.querySelector(".ps-appearance-statuses .ps-status-updated")).color'), 'rgb(0, 119, 0)');
        await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode','dark')`);
        await wait('document.documentElement.getAttribute("data-pt-dark")', 'true');
        assert.equal(await evaluate('getComputedStyle(document.querySelector(".ps-appearance-statuses .ps-status-updated")).color'), 'rgb(0, 238, 34)');

        await setColor('success', 'light', '#ffffff');
        assert.equal(await evaluate('document.getElementById("ps-appearance-save").disabled'), false, 'contrast is informative and must not block an exact chosen color');
        assert.equal(await evaluate('getComputedStyle(document.getElementById("ps-color-preview-success-light")).color'), 'rgb(255, 255, 255)');
        await setColor('success', 'light', customColors.color_success_light);
        const requestsBeforeInvalid = appearanceRequests.length;
        await setColor('success', 'dark', '#00zz00');
        assert.equal(await evaluate('document.getElementById("ps-appearance-save").disabled'), true);
        assert.equal(await evaluate('getComputedStyle(document.getElementById("ps-color-preview-success-dark")).color'), 'rgb(0, 238, 34)', 'invalid intermediate HEX must leave the last valid preview intact');
        await evaluate('document.getElementById("ps-appearance-save").click()');
        assert.equal(appearanceRequests.length, requestsBeforeInvalid);
        await setColor('success', 'dark', '#00EE22');
        await evaluate('document.getElementById("ps-appearance-save").click()');
        await wait('document.getElementById("ps-appearance-status").textContent', 'Appearance saved.');
        assert.deepEqual(appearanceState, { ...defaults, mono_font_size: '14', mono_line_height: '1.5', ...customColors });
        for (const key of Object.keys(colorDefaults)) assert.equal(appearanceRequests[1].params[key], customColors[key]);

        const timeOrigin = await evaluate('performance.timeOrigin');
        await cdp.call('Page.reload', {}, sessionId);
        await wait(`performance.timeOrigin !== ${timeOrigin}`, true);
        await wait('document.getElementById("ps-appearance-save")?.disabled', false);
        assert.equal(await evaluate('document.getElementById("ps-mono-size").value'), '14', 'saved settings survive page reload');
        for (const [key, value] of Object.entries(customColors)) {
            assert.equal(await evaluate(`document.getElementById('ps-'+${JSON.stringify(key.replaceAll('_', '-'))}+'-hex').value`), value, 'saved colors survive page reload');
        }

        await evaluate(`(() => {for(const [id,value] of Object.entries({'ps-appearance-profile':'contrast','ps-mono-size':'17','ps-mono-weight':'500','ps-mono-height':'1.8'})){const el=document.getElementById(id);el.value=value;el.dispatchEvent(new Event(el.tagName==='SELECT'?'change':'input'));}window.confirm=()=>true;document.getElementById('ps-colors-reset').click();})()`);
        await wait('document.getElementById("ps-appearance-status").textContent', 'Colors reset.');
        assert.deepEqual(appearanceState, { ...defaults, mono_font_size: '14', mono_line_height: '1.5' }, 'Reset Colors preserves saved base settings');
        assert.equal(await evaluate('document.getElementById("ps-mono-size").value'), '17', 'Reset Colors also preserves unsaved font preview');
        assert.equal(await evaluate('document.getElementById("ps-appearance-profile").value'), 'contrast');
        for (const [key, value] of Object.entries(customColors)) {
            const [, role, scheme] = key.split('_');
            await setColor(role, scheme, value);
        }
        await evaluate('document.getElementById("ps-appearance-save").click()');
        await wait('document.getElementById("ps-appearance-status").textContent', 'Appearance saved.');
        await evaluate('window.confirm=()=>true;document.getElementById("ps-appearance-reset").click()');
        await wait('document.getElementById("ps-appearance-status").textContent', 'Appearance reset.');
        assert.deepEqual(appearanceState, { ...defaults, ...customColors }, 'Reset Appearance preserves custom colors');
        assert.equal(await evaluate('document.getElementById("ps-mono-size").value'), '13');
        await evaluate('document.getElementById("ps-colors-reset").click()');
        await wait('document.getElementById("ps-appearance-status").textContent', 'Colors reset.');
        assert.deepEqual(appearanceState, defaults);
        assert.equal(await evaluate('document.getElementById("ps-color-success-dark-hex").value'), '#00ff00');
        await screenshot('argon-config-dark', 1440);
        await cdp.call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, sessionId);
        assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true, 'Argon Config controls must fit a narrow viewport');
        await screenshot('argon-config-mobile', 390);
        await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
        appearanceFailure = true;
        await evaluate(`document.getElementById('ps-mono-size').value='16';document.getElementById('ps-mono-size').dispatchEvent(new Event('input'));document.getElementById('ps-appearance-save').click()`);
        await wait('document.getElementById("ps-appearance-status").textContent', 'Cannot commit appearance settings');
        assert.deepEqual(appearanceState, defaults, 'failed saves must leave persisted settings untouched');
        assert.equal(await evaluate('document.getElementById("ps-appearance-save").disabled'), false);
        appearanceFailure = true;
        await setColor('success', 'dark', '#123456');
        await evaluate('document.getElementById("ps-colors-reset").click()');
        await wait('document.getElementById("ps-appearance-status").textContent', 'Cannot commit appearance settings');
        await wait('document.getElementById("ps-colors-reset").disabled', false);
        assert.deepEqual(appearanceState, defaults, 'failed color resets must not mutate persisted colors');
        assert.equal(await evaluate('document.getElementById("ps-color-success-dark-hex").value'), '#123456');
        fs.writeFileSync(path.join(artifacts, 'appearance-form.json'), JSON.stringify({ preview, colorPreview, requests: appearanceRequests }, null, 2));
        console.log('PASS real Argon Config form: picker/HEX sync, live colors, computed contrast, invalid HEX, exact save+CSRF, reload, isolated resets, narrow layout, failure recovery');
        }
        if (!updateOnly && !copyOnly) {
        await cdp.call('Page.navigate', { url: base + '/diagnostics-form' }, sessionId);
        await wait('document.readyState', 'complete');
        await evaluate('document.getElementById("ps-leak-run").click()');
        await wait('document.getElementById("ps-leak-status").textContent', 'OBSERVATIONS COLLECTED');
        const observed = await evaluate(`({probes:window.probeURLs,log:JSON.parse(sessionStorage.getItem('pt-diag-run-log'))})`);
        assert.equal(observed.probes.length, 6);
        assert.equal(observed.log[observed.log.length - 1].data.probes_completed, 6);
        assert.equal(observed.log[observed.log.length - 1].data.resolvers[0].ip, '1.1.1.1');
        assert.equal(await evaluate('document.getElementById("ps-leak-run").disabled'), false);
        await screenshot('diagnostics-external-dns', 1440);
        await evaluate('document.getElementById("ps-dns-observation-help").open=true');
        await screenshot('diagnostics-dns-help-dark', 1440);
        await evaluate('document.getElementById("ps-theme-context").setAttribute("data-mode","light")');
        await wait('document.documentElement.getAttribute("data-pt-dark")', 'false');
        await screenshot('diagnostics-dns-help-light', 1440);
        await evaluate('document.getElementById("ps-dns-observation-help").open=false');
        await cdp.call('Runtime.evaluate', { expression: 'document.getElementById("ps-podkop-diagnostics").click()', userGesture: true }, sessionId);
        let childSession;
        for (let i = 0; i < 100; i++) {
            const targets = await cdp.call('Target.getTargets');
            const popup = targets.targetInfos.find(target => target.url.split('#')[0] === base + '/admin/services/podkop');
            if (popup) {
                if (!childSession) childSession = (await cdp.call('Target.attachToTarget', { targetId: popup.targetId, flatten: true })).sessionId;
                const state = await cdp.call('Runtime.evaluate', { expression: `document.getElementById('pane')?.getAttribute('data-tab-active')`, returnByValue: true }, childSession);
                if (state.result.value === 'true') break;
            }
            if (i === 99) throw new Error('Native Podkop diagnostic tab was not selected');
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        const opener = await cdp.call('Runtime.evaluate', { expression: 'window.opener === null', returnByValue: true }, childSession);
        assert.equal(opener.result.value, true);
        console.log('PASS real Diagnostics form: local mock probes, exact resolver run log and bounded native Podkop tab navigation');
        }
        if (!diagnosticsOnly && !copyOnly) {
            for (const mode of ['older', 'newer', 'same']) {
                await cdp.call('Page.navigate', { url: base + '/local-update-form?case=' + mode }, sessionId);
                await wait('document.readyState', 'complete');
                await evaluate(`(() => {const transfer=new DataTransfer();transfer.items.add(new File(['archive'],'luci-app-podkop-tweaker-v${appVersion}.tar.gz'));const input=document.getElementById('ps-file-input');input.files=transfer.files;input.dispatchEvent(new Event('change'));})()`);
                await wait('document.getElementById("ps-file-input").disabled', false);
                if (mode === 'older') {
                    assert.equal(await evaluate('document.getElementById("ps-apply-btn") === null'), true);
                    assert.match(await evaluate('document.getElementById("ps-update-actions").textContent'), /older than installed/);
                    continue;
                }
                assert.match(await evaluate('document.getElementById("ps-apply-btn").textContent'), mode === 'same' ? /Reinstall/ : /Update/);
                if (mode === 'same') await screenshot('local-update-reinstall', 1440);
                localApplyFailure = true;
                await evaluate('document.getElementById("ps-apply-btn").click()');
                await wait('document.getElementById("ps-apply-btn").disabled', false);
                assert.equal(localApplyRequests[localApplyRequests.length - 1].params.reinstall, mode === 'same' ? '1' : undefined);
                assert.equal(await evaluate('document.getElementById("ps-file-input").disabled'), false);
                if (mode === 'same') {
                    localApplyFailure = false;
                    await evaluate('document.getElementById("ps-apply-btn").click()');
                    await wait('document.getElementById("ps-apply-status").textContent', 'Reinstallation complete! Reloading...');
                    assert.equal(await evaluate('document.getElementById("ps-file-input").disabled'), true);
                }
            }
            console.log('PASS real Local Update form: Update/Reinstall/older actions, multipart+CSRF, explicit reinstall flag, failure recovery and success lock');
        }
        if (!focused || copyOnly) {
            const copy = async selector => {
                const placement = await evaluate(`(() => {
                    const button=document.querySelector(${JSON.stringify(selector)}),svg=button.querySelector('svg'),status=button.querySelector('.ps-copy-status');
                    const id=button.getAttribute('data-pt-copy-for'),details=button.closest('.ps-err-details');
                    const source=id?document.getElementById(id):details.querySelector('pre');
                    const frame=source.closest('.ps-copy-panel,.ps-copy-editor'),b=button.getBoundingClientRect(),f=frame.getBoundingClientRect(),s=source.getBoundingClientRect();
                    return {icon:!!svg,hidden:getComputedStyle(status).clipPath==='inset(50%)',width:b.width,height:b.height,
                        inFrame:details&&!details.open?button.parentElement.tagName==='SUMMARY':b.left>=f.left&&b.right<=f.right&&b.top>=f.top&&b.bottom<=s.top+1};
                })()`);
                assert.equal(placement.icon, true, 'copy control must display a fixed SVG icon');
                assert.equal(placement.hidden, true, 'status labels must be visually hidden, not visible buttons');
                assert.equal(placement.width, 30); assert.equal(placement.height, 30);
                assert.equal(placement.inFrame, true, 'icon must be inside its frame and outside the scrolling text');
                const before = await evaluate('window.copyWrites.length');
                await cdp.call('Runtime.evaluate', { expression: `document.querySelector(${JSON.stringify(selector)}).click()`, userGesture: true }, sessionId);
                await wait('window.copyWrites.length', before + 1);
                await wait(`document.querySelector(${JSON.stringify(selector)}).getAttribute('data-pt-copy-state')`, 'done');
                return evaluate('window.copyWrites[window.copyWrites.length-1]');
            };
            const text = '\tconfig settings\n' + "    option user_domains_text 'line <literal>'\n".repeat(2000) + 'last config line\n';
            const detail = '<!doctype html>\n<form action="/cgi-bin/luci/admin/services/podkop-tweaker/api/upload_update">Log in</form>\n' + 'full error detail\n'.repeat(2000) + 'last error line';
            for (const name of ['config', 'stubby', 'singbox']) {
                await cdp.call('Page.navigate', { url: base + '/copy-form?view=' + name }, sessionId);
                await wait('document.readyState', 'complete');
                await wait('document.getElementById("ps-config-editor").disabled', false);
                await evaluate(`(() => {const e=document.getElementById('ps-config-editor');e.value=${JSON.stringify(text)};e.dispatchEvent(new Event('input'));e.focus();e.setSelectionRange(7,19,'backward');e.scrollTop=150;e.scrollLeft=12;window.editorBefore={start:e.selectionStart,end:e.selectionEnd,direction:e.selectionDirection,top:e.scrollTop,left:e.scrollLeft};})()`);
                assert.equal(await copy('[data-pt-copy-for="ps-config-editor"]'), text);
                const unchanged = await evaluate(`(() => {const e=document.getElementById('ps-config-editor');return {focus:document.activeElement.id,value:e.value===${JSON.stringify(text)},before:window.editorBefore,after:{start:e.selectionStart,end:e.selectionEnd,direction:e.selectionDirection,top:e.scrollTop,left:e.scrollLeft}};})()`);
                assert.equal(unchanged.focus, 'ps-config-editor');
                assert.equal(unchanged.value, true);
                assert.deepEqual(unchanged.after, unchanged.before, name + ': copying must retain selection and scroll');
                assert.equal(await evaluate('document.getElementById("ps-config-save").disabled'), false, 'copy must not change dirty state');
                await evaluate(`document.getElementById('ps-error-details').textContent=${JSON.stringify(detail)};document.getElementById('ps-error-modal').style.display='flex';document.querySelector('#ps-error-modal .ps-modal-content').style.maxHeight='250px'`);
                assert.equal(await copy('[data-pt-copy-for="ps-error-details"]'), detail);
                await evaluate(`document.querySelector('#ps-error-modal .ps-modal-content').scrollTop=160;document.getElementById('ps-error-details').scrollTop=400`);
                assert.equal(await evaluate(`(() => {const card=document.querySelector('#ps-error-modal .ps-modal-content').getBoundingClientRect(),button=document.querySelector('[data-pt-copy-for="ps-error-details"]').getBoundingClientRect();return button.top>=card.top&&button.bottom<card.bottom&&button.right<=card.right;})()`), true, 'modal Copy must stay visible when content scrolls');
                if (name === 'config') await screenshot('copy-error-modal-dark', 1440);
                await evaluate(`document.getElementById('ps-error-close').click();document.getElementById('ps-config-diff').click()`);
                const expectedDiff = await evaluate('document.getElementById("ps-diff-body").innerText');
                assert.equal(await copy('[data-pt-copy-for="ps-diff-body"]'), expectedDiff);
                if (name === 'stubby') {
                    await evaluate('document.getElementById("ps-diff-close").click();document.getElementById("ps-params-btn").click()');
                    const help = await evaluate('document.getElementById("ps-params-modal").innerText');
                    assert.ok(help.includes("log_level '3'"));
                    for (const level of ['0 Emergency', '1 Alert', '2 Critical', '3 Error', '4 Warning', '5 Notice', '6 Info', '7 Debug']) assert.ok(help.includes(level));
                    assert.ok(help.includes('Local DNSSEC off') && help.includes('dot.sb'));
                    await screenshot('stubby-template-guidance', 1440);
                    await evaluate('document.getElementById("ps-params-close").click();document.getElementById("ps-initfix-btn").click()');
                    assert.equal(await copy('[data-pt-copy-for="ps-initfix-cmd"]'), await evaluate('document.getElementById("ps-initfix-cmd").textContent'));
                }
                assert.equal(await evaluate('document.querySelectorAll(".ps-copy-fallback").length'), 0);
                // Leave via the real Undo action so the verified dirty-state
                // beforeunload guard does not block navigation to the next form.
                await evaluate('window.confirm=()=>true;document.getElementById("ps-config-undo").click()');
                console.log('PASS clipboard real ' + name + ' editor, error and diff');
            }
            await cdp.call('Page.navigate', { url: base + '/copy-form?view=subscriptions' }, sessionId);
            await wait('document.readyState', 'complete');
            await wait('document.getElementById("ps-full-log-btn").style.display', '');
            const recent = await evaluate('document.getElementById("ps-log-wrap").innerText');
            assert.equal(await copy('[data-pt-copy-for="ps-log-wrap"]'), recent);
            assert.ok(recent.includes('detail 14: <script>plain text</script>'));
            await evaluate('document.getElementById("ps-full-log-btn").click()');
            const fullLog = await evaluate('document.getElementById("ps-full-log-body").innerText');
            assert.ok(fullLog.includes('detail 0: <script>plain text</script>'));
            assert.equal(await copy('[data-pt-copy-for="ps-full-log-body"]'), fullLog);
            await evaluate('PT.initCopyButtons();PT.initCopyButtons()');
            assert.equal(await evaluate('document.querySelectorAll("[data-pt-copy-for=ps-full-log-body]").length'), 1);

            await cdp.call('Page.navigate', { url: base + '/argon-auto-dark' }, sessionId);
            await wait('document.readyState', 'complete');
            await evaluate(`window.copyWrites=[];Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText(text){window.copyWrites.push(text);return Promise.resolve();}}});document.getElementById('log').innerHTML='<div class="ps-log-summary">new summary</div><div class="ps-log-detail-line">detail after refresh</div>';PT.setErr(document.getElementById('install-error'),'HTTP error: 403',${JSON.stringify(detail)})`);
            assert.equal(await copy('[data-pt-copy-for="log"]'), 'new summary\ndetail after refresh');
            assert.equal(await copy('[data-pt-copy-for="chain"]'), await evaluate('document.getElementById("chain").innerText'));
            assert.equal(await copy('#install-error summary .ps-copy-btn'), detail, 'copy hidden complete HTML error as literal text');
            assert.equal(await evaluate('document.querySelector("#install-error details").open'), false, 'Copy must not open or close the disclosure');
            assert.equal(await evaluate('document.querySelector("#install-error pre").childElementCount'), 0, 'HTML errors remain literal text');
            const beforeKeyboard = await evaluate('window.copyWrites.length');
            await cdp.call('Page.bringToFront', {}, sessionId);
            await evaluate('document.querySelector("#install-error .ps-copy-btn").focus()');
            await cdp.call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r', unmodifiedText: '\r' }, sessionId);
            await cdp.call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 }, sessionId);
            await wait('window.copyWrites.length', beforeKeyboard + 1);
            assert.equal(await evaluate('document.querySelector("#install-error details").open'), false, 'keyboard Copy must not toggle the disclosure');
            for (const scheme of ['dark', 'light']) {
                await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode',${JSON.stringify(scheme)});document.querySelector('#install-error details').open=true`);
                await wait('document.documentElement.getAttribute("data-pt-dark")', String(scheme === 'dark'));
                await wait('!!document.querySelector("#install-error .ps-copy-tools .ps-copy-btn")', true);
                assert.equal(await copy('#install-error .ps-copy-tools .ps-copy-btn'), detail, 'expanded error copies through its in-block icon');
                await screenshot('copy-details-' + scheme, 1440);
            }
            await evaluate('document.querySelector("#install-error details").open=false');
            await wait('!!document.querySelector("#install-error summary .ps-copy-btn")', true);
            assert.equal(await copy('#install-error summary .ps-copy-btn'), detail);
            await evaluate('document.querySelector("#install-error details").open=true');
            await wait('!!document.querySelector("#install-error .ps-copy-tools .ps-copy-btn")', true);
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, sessionId);
            // The theme fixture is deliberately a fixed two-column grid; isolate
            // the real error block to check its responsive toolbar geometry.
            await evaluate(`document.querySelector('.fixture-grid').style.display='block'`);
            assert.equal(await evaluate('document.documentElement.scrollWidth <= window.innerWidth'), true);
            assert.equal(await evaluate(`(() => {const a=document.querySelector('#install-error .ps-copy-panel').getBoundingClientRect(),b=document.querySelector('#install-error .ps-copy-btn').getBoundingClientRect();return b.right<=a.right&&b.left>=a.left;})()`), true);
            await screenshot('copy-details-mobile', 390);
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);

            await cdp.call('Page.navigate', { url: base + '/copy-form?view=import-export' }, sessionId);
            await wait('document.readyState', 'complete');
            await evaluate(`window.copyWrites=[];Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText(text){window.copyWrites.push(text);return Promise.resolve();}}});document.getElementById('ps-error-details').textContent=${JSON.stringify(detail)};document.getElementById('ps-error-modal').style.display='flex'`);
            assert.equal(await copy('[data-pt-copy-for="ps-error-details"]'), detail);

            await cdp.call('Page.navigate', { url: base + '/diagnostics-form' }, sessionId);
            await wait('document.readyState', 'complete');
            await evaluate(`window.copyWrites=[];Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText(text){window.copyWrites.push(text);return Promise.resolve();}}});document.getElementById('ps-leak-run').click()`);
            await wait('document.getElementById("ps-leak-status").textContent', 'OBSERVATIONS COLLECTED');
            const runLog = await evaluate('document.getElementById("ps-diaglog-wrap").innerText');
            assert.ok(runLog.includes('probes_completed: 6'));
            assert.equal(await copy('[data-pt-copy-for="ps-diaglog-wrap"]'), runLog);
            assert.equal(await copy('[data-pt-copy-for="ps-chain-content"]'), await evaluate('document.getElementById("ps-chain-content").innerText'));

            await cdp.call('Page.navigate', { url: base + '/appearance-form' }, sessionId);
            await wait('document.readyState', 'complete');
            await evaluate(`window.copyWrites=[];Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText(text){window.copyWrites.push(text);return Promise.resolve();}}})`);
            assert.equal(await copy('[data-pt-copy-for="ps-appearance-editor"]'), await evaluate('document.getElementById("ps-appearance-editor").value'));
            console.log('PASS clipboard controls: in-frame SVG/accessible feedback, real editors/error/diff/command/log forms, Stubby guidance, native HTTP copy, secure API, full literal HTML, selection+scroll+dirty preservation, keyboard and light/dark/mobile controls');
        }
        if (!focused) fs.writeFileSync(path.join(artifacts, 'computed-colors.json'), JSON.stringify(reports, null, 2));
        console.log(copyOnly ? 'Native clipboard checks: PASS' : updateOnly ? 'Native Local Update checks: PASS' : diagnosticsOnly ? 'Native Diagnostics checks: PASS (DNS flow, light/dark result guide and Podkop navigation)' : `Native browser theme checks: PASS (${reports.length} scheme/profile scenarios + real forms; screenshots in ROOT/tmp/theme-smoke)`);
    } finally {
        if (cdp) { await cdp.call('Browser.close').catch(() => {}); cdp.close(); }
        child.kill();
        await new Promise(resolve => server.close(resolve));
    }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
