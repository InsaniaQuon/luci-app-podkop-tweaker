// theme_browser_spec.js | v4.3.1 | 17.10.2026 | Exact contextual Stubby diagnostics in native browser fixtures
// node tests/theme_browser_spec.js --browser <installed Chromium/Edge executable>
// Add --theme-only for schemes/live Argon modes, or a focused form flag below.
// --output-dir .test_tmp/<run> isolates generated files/profile from old runs.
// --argon-css <local cascade.css> uses real CSS in the Argon 3 mode fixtures.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const repo = path.resolve(__dirname, '..');
const root = path.dirname(repo);
const controller = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/controller/podkop-tweaker.lua'), 'utf8');
const appVersion = controller.match(/APP_VERSION = "([^"]+)"/)[1];
const assetBaseVersion = appVersion + '-' + controller.match(/ASSET_REVISION = "([^"]+)"/)[1];
function option(flag) {
    const index = process.argv.indexOf(flag);
    if (index < 0) return null;
    const value = process.argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`Supply ${flag} <value>`);
    return value;
}
const browser = option('--browser');
const diagnosticsOnly = process.argv.includes('--diagnostics-only');
const updateOnly = process.argv.includes('--update-only');
const copyOnly = process.argv.includes('--copy-only');
const reliabilityOnly = process.argv.includes('--reliability-only');
const themeOnly = process.argv.includes('--theme-only');
const focused = diagnosticsOnly || updateOnly || copyOnly || reliabilityOnly || themeOnly;
if ([diagnosticsOnly, updateOnly, copyOnly, reliabilityOnly, themeOnly].filter(Boolean).length > 1) throw new Error('Choose one focused mode');
if (!browser) throw new Error('Supply --browser <installed executable>');
const outputDir = option('--output-dir');
const runDate = new Date(Date.now() + 3 * 3600000);
const pad2 = value => String(value).padStart(2, '0');
const runStamp = `${pad2(runDate.getUTCDate())}.${pad2(runDate.getUTCMonth() + 1)}.${runDate.getUTCFullYear()}_${pad2(runDate.getUTCHours())}.${pad2(runDate.getUTCMinutes())}`;
const artifacts = outputDir ? path.resolve(root, outputDir) : path.join(root, '.test_tmp', `browser-${runStamp}-${process.pid}`);
const relativeOutput = path.relative(path.join(root, '.test_tmp'), artifacts);
assert.ok(relativeOutput && relativeOutput !== '..' && !relativeOutput.startsWith('..' + path.sep) && !path.isAbsolute(relativeOutput), '--output-dir must be a run directory inside ROOT/.test_tmp');
assert.ok(fs.existsSync(root), 'ROOT must exist');
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

// Minimal mode-aware fixture by default; a caller can supply upstream CSS
// without changing the legacy 2.4.x/Bootstrap fixtures.
const argonCssFile = option('--argon-css');
const argon3Dark = '--fixture-bg:#1e1e1e;--fixture-fg:#ccc;--fixture-card:#252526;--fixture-border:#3c3c3c';
const argon3Theme = argonCssFile ? fs.readFileSync(path.resolve(root, argonCssFile), 'utf8') : `${lightTheme}
:root{--fixture-bg:#f4f5f7;--fixture-fg:#32325d;--fixture-card:#fff;--fixture-border:#ddd}
:root[data-argon-mode="dark"]{${argon3Dark}}
@media(prefers-color-scheme:dark){:root[data-argon-mode="normal"]{${argon3Dark}}}
body,.main-right{background:var(--fixture-bg);color:var(--fixture-fg)}
.cbi-section{background:var(--fixture-card)!important}h2,h3,h4{background:var(--fixture-card)}
input,select,textarea{background:var(--fixture-card)!important;color:var(--fixture-fg);border-color:var(--fixture-border)!important}
`;

const scenarios = {
    'argon-auto-dark': { os: 'dark', theme: 'argon', mode: 'normal', media: '(prefers-color-scheme: dark)', darkLink: true, late: true, dark: true },
    'argon-force-dark': { os: 'light', theme: 'argon', mode: 'dark', darkLink: true, dark: true },
    'argon-force-light': { os: 'dark', theme: 'argon', mode: 'light', dark: false },
    'argon-versioned-css': { os: 'dark', theme: '', mode: '', darkLink: true, media: '(prefers-color-scheme: dark)', dark: true },
    'argon-inline-legacy': { os: 'dark', theme: '', mode: '', inline: true, dark: true },
    'bootstrap-dark': { os: 'light', theme: 'bootstrap', mode: '', bootstrap: true, inline: true, dark: true },
    'bootstrap-light': { os: 'dark', theme: 'bootstrap', mode: '', bootstrap: false, dark: false },
    'argon3-light-stale-dark': { os: 'dark', theme: 'argon', mode: 'dark', argonMode: 'light', dark: false },
    'argon3-dark-stale-light': { os: 'light', theme: 'argon', mode: 'light', argonMode: 'dark', dark: true },
    'argon3-normal-stale-dark': { os: 'light', theme: 'argon', mode: 'dark', argonMode: 'normal', dark: false }
};

function fixture(name, profile) {
    const s = scenarios[name];
    const app = `<link rel="stylesheet" href="/common.css?v=${assetBaseVersion}">`;
    const darkLink = s.darkLink ? `<link rel="stylesheet" href="/luci-static/argon/css/dark.css?v=2.4.8#version" ${s.media ? `media="${s.media}"` : ''}>` : '';
    const argon3 = s.argonMode !== undefined;
    return `<!doctype html><html ${s.bootstrap === undefined ? '' : `data-darkmode="${s.bootstrap}"`} ${argon3 ? `data-argon-mode="${s.argonMode}"` : ''}><head><meta charset="utf-8">
<link rel="stylesheet" href="${argon3 ? '/argon3.css' : '/luci-static/argon/css/cascade.css?v=2.4.8'}">
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
${argon3 ? `<label>Theme mode <select id="argon-mode" onchange="document.documentElement.setAttribute('data-argon-mode',this.value)">${['dark', 'light', 'normal'].map(mode => `<option ${mode === s.argonMode ? 'selected' : ''}>${mode}</option>`).join('')}</select></label>` : ''}
<div class="ps-modal" id="modal" style="display:none"><div class="ps-modal-content"><h3>Attach subscription</h3><input id="modal-input" class="ps-sub-url-input" value="https://example.test/sub"><label class="ps-check-item"><input id="modal-check" type="checkbox" checked><span>Import settings</span></label><label class="ps-diff-toggle"><input id="diff-check" type="checkbox" checked>Only changed</label><pre class="ps-error-details" id="error-details">ERROR: unable to select packages</pre><button class="btn cbi-button" id="modal-close">Close</button></div></div>
<script>window.PT={urls:{},csrf:'test'};</script><script src="/common.js?v=${assetBaseVersion}"></script>
<script>document.getElementById('live-status').style.color=PT.color('success');PT.setErr(document.getElementById('install-error'),'Theme package installation failed','ERROR: ucode dependency conflict');document.querySelector('#install-error summary').id='install-summary';</script></body></html>`;
}

const colorDefaults = {
    color_success_light: '#00be00', color_error_light: '#ff0000', color_warning_light: '#ff8c42',
    color_success_dark: '#00ff00', color_error_dark: '#ff8080', color_warning_dark: '#ffbd42'
};
const defaults = { profile: 'soft', mono_font_size: '13', mono_font_weight: '400', mono_line_height: '1.6', ...colorDefaults };
let appearanceState = { ...defaults, profile: 'contrast', mono_font_size: '18', mono_font_weight: '500', mono_line_height: '1.8' };
const typographyState = { font_size: '17', font_family: 'Google Sans', font_family_custom: '', font_weight: '550',
    line_height: '1.7', letter_spacing: '', menu_font_size: '', menu_padding: '' };
const appearanceRequests = [];
let appearanceFailure = false, appearanceReadFailure = false;
let typographyReadFailure = false, fragmentReadFailure = false, outboundReadFailure = false;
const frontendPosts = [];
// Observe the actual browser XHR/deadline and Blob download paths. No transport
// callbacks, timers, production runners or download helpers are replaced here.
const browserRequestObserver = `window.fixtureXHR=[];(()=>{const open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(method,url){this.fixtureRequest={method,url:String(url)};return open.apply(this,arguments);};XMLHttpRequest.prototype.send=function(){window.fixtureXHR.push({...this.fixtureRequest,timeout:this.timeout});return send.apply(this,arguments);};})();`;
const browserDownloadObserver = `window.fixtureDownloads=[];window.fixtureDownloadErrors=[];document.addEventListener('click',event=>{const link=event.target.closest&&event.target.closest('a[download]');if(!link||!link.href.startsWith('blob:'))return;event.preventDefault();const filename=link.download;fetch(link.href).then(response=>response.text()).then(text=>window.fixtureDownloads.push({filename,text})).catch(error=>window.fixtureDownloadErrors.push(String(error)));},true);`;

// Held HTTP replies let the native browser expose each progressive result before
// the next operation completes. Every response remains on this local server.
const fixtureReplyQueues = new Map(), fixtureCalls = [], heldFixtureReplies = new Set();
function queueFixtureReply(endpoint, data, options = {}) {
    const plan = { data, ...options };
    if (!fixtureReplyQueues.has(endpoint)) fixtureReplyQueues.set(endpoint, []);
    fixtureReplyQueues.get(endpoint).push(plan);
    return plan;
}
function fixtureResponse(req, res, fields, fallback) {
    const endpoint = new URL(req.url, 'http://localhost').pathname;
    const plan = (fixtureReplyQueues.get(endpoint) || []).shift() || {};
    plan.request = { endpoint, method: req.method, fields, receivedAt: Date.now() };
    fixtureCalls.push(plan.request);
    const send = () => {
        heldFixtureReplies.delete(send);
        if (plan.sentAt || res.destroyed || res.writableEnded) return;
        const data = plan.data === undefined ? typeof fallback === 'function' ? fallback() : fallback : plan.data;
        if (plan.effect) plan.effect();
        res.statusCode = plan.status || 200;
        res.setHeader('Content-Type', plan.contentType || 'application/json');
        res.setHeader('Cache-Control', 'no-store');
        plan.sentAt = Date.now();
        res.end(plan.raw === undefined ? JSON.stringify(data) : plan.raw);
    };
    plan.release = send;
    if (plan.hold) {
        heldFixtureReplies.add(send);
        res.once('close', () => heldFixtureReplies.delete(send));
    } else send();
}

const localDiagnostics = {
    diag_dns: { results: [
        { source: 'dot.fixture.test', target: '192.0.2.53', ip: '192.0.2.80', status: 'OK' },
        { source: 'Via Stubby', target: '127.0.0.53', ip: '192.0.2.80', status: 'OK' },
        { source: 'Via dnsmasq', target: '127.0.0.1', ip: '198.18.0.10', status: 'OK' }
    ] },
    diag_proxy: { results: [
        { source: 'sing-box mixed (:2080)', http_code: 204, time_ms: 37, status: 'OK' },
        { source: 'fixture second inbound', http_code: 200, time_ms: 49, status: 'OK' }
    ] },
    diag_e2e: { external_ip: '198.51.100.24', http_code: 204, time_ms: 61, status: 'OK' }
};
function appearanceFixture() {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/argon.htm'), 'utf8');
    const colorAttrs = Object.keys(colorDefaults).map(key => `data-${key.replaceAll('_', '-')}="${appearanceState[key]}"`).join(' ');
    const marker = `<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="${appearanceState.profile}" data-mono-size="${appearanceState.mono_font_size}" data-mono-weight="${appearanceState.mono_font_weight}" data-mono-line-height="${appearanceState.mono_line_height}" ${colorAttrs}></span>`;
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"')).replace('<%+podkop-tweaker/tabs%>', marker);
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = { csrf: 'browser-token', urls: { typography: '/api/typography', save: '/api/typography-save', reset: '/api/typography-reset', reinject: '/api/typography-reinject', appearance: '/api/appearance', appearanceSave: '/api/appearance-save', appearanceReset: '/api/appearance-reset', appearanceColorsReset: '/api/appearance-colors-reset' } };
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}${view.match(/<style>([\s\S]*?)<\/style>/)[1]}</style><link rel="stylesheet" href="/common.css?v=${assetBaseVersion}"></head><body><div class="main-right">${markup}</div><script>window.PT=${JSON.stringify(bootstrap)};</script><script src="/common.js?v=${assetBaseVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

function diagnosticsFixture() {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/diagnostics.htm'), 'utf8');
    const marker = '<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="soft"></span>';
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"'))
        .replace('<%+podkop-tweaker/tabs%>', marker).replace(/<%=url\('admin\/services\/podkop'\)%>/g, '/admin/services/podkop');
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = { version: appVersion, csrf: 'browser-token', urls: { chainInfo: '/testapi/chain', diagDns: '/testapi/diag_dns', diagProxy: '/testapi/diag_proxy', diagE2e: '/testapi/diag_e2e', dnsObservationStart: '/testapi/dns-start', dnsObservationResults: '/testapi/dns-results' } };
    // Provider probes are mapped to a local image: exercise real browser events
    // without sending DNS/HTTP test traffic to a third-party from the host.
    const probes = `window.probeURLs=[];window.Image=class{constructor(){this.img=document.createElement('img');this.img.onload=()=>this.onload&&this.onload();this.img.onerror=()=>this.onerror&&this.onerror();}set src(url){if(!url)return;window.probeURLs.push(url);this.img.src='/testapi/probe.png';}};`;
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}</style><link rel="stylesheet" href="/common.css?v=${assetBaseVersion}"><style>${view.match(/<style>([\s\S]*?)<\/style>/)[1]}</style></head><body><div class="main-right">${markup}</div><script>window.PT=${JSON.stringify(bootstrap)};${probes}${browserRequestObserver}${browserDownloadObserver}</script><script src="/common.js?v=${assetBaseVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

const localApplyRequests = [];
let localApplyFailure = false;
let localApplyUncertain = false;
let localRestart = null;
const resourceVersions = [];
function updateFixture(mode, nonce) {
    const assetVersion = assetBaseVersion + (nonce ? '-' + nonce : '');
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker/update.htm'), 'utf8');
    const marker = '<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="soft"></span>';
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"')).replace('<%+podkop-tweaker/tabs%>', marker);
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = { csrf: 'browser-token', urls: { upload: '/testapi/local-upload?case=' + mode, apply: '/testapi/local-apply?case=' + mode, restartStatus: '/testapi/restart-status' } };
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}</style><link rel="stylesheet" href="/common.css?v=${assetVersion}"></head><body><div class="main-right">${markup}</div><script>window.PT=${JSON.stringify(bootstrap)};</script><script src="/common.js?v=${assetVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

// Use real page markup/bootstrap/scripts; intercept native copy events so the
// HTTP fallback is exercised without changing the host OS clipboard.
function copyFixture(name) {
    const view = fs.readFileSync(path.join(repo, 'usr/lib/lua/luci/view/podkop-tweaker', name + '.htm'), 'utf8');
    const marker = '<span hidden id="ps-theme-context" data-theme="argon" data-mode="dark" data-profile="soft"></span>';
    const markup = view.slice(view.indexOf('<div class="cbi-map"'), view.indexOf('<link rel="stylesheet"')).replace('<%+podkop-tweaker/tabs%>', marker).replace(/<%[\s\S]*?%>/g, '');
    const scripts = [...view.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)];
    const bootstrap = scripts[0][1].replace(/<%=([\s\S]*?)%>/g, (_, expr) => {
        if (expr.includes('app_version')) return appVersion;
        if (expr.includes('csrf_token')) return 'browser-token';
        const endpoint = expr.match(/api\/([^"']+)/);
        return endpoint ? '/copyapi/' + endpoint[1] : '';
    });
    return `<!doctype html><html><head><meta charset="utf-8"><style>${lightTheme}${darkTheme}</style><link rel="stylesheet" href="/common.css?v=${assetBaseVersion}"></head><body><div class="main-right">${markup}</div><script>${bootstrap};${browserRequestObserver}window.copyWrites=[];Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined});document.addEventListener('copy',event=>{window.copyWrites.push(document.activeElement.value);event.preventDefault();});</script><script src="/common.js?v=${assetBaseVersion}"></script><script>${scripts[scripts.length - 1][1]}</script></body></html>`;
}

const copyLogLines = Array.from({ length: 15 }, (_, i) => [`09.10.2026 12:${String(i).padStart(2, '0')}|manual|updated=1|unchanged=0|failed=0`, `  main-${i}: updated`, `    detail ${i}: <script>plain text</script>`]).flat();
const contentRequests = [], subscriptionRequests = [];
const subscriptionSettings = { auto_update_interval: 4, auto_update_start: '01:30', auto_update_on_restart: true, log_display_count: 10 };
let subscriptionFailure = false, brokenSchedule = false;
let fixtureWrapperInstalled = false;
const fixtureAutostart = { podkop: false, stubby: false };
const initialStubbyConfig = "config stubby 'global'\n    option log_level '3'\n";
let fixtureStubbyConfig = initialStubbyConfig;
// Controlled process facts for frontend fixtures, not host/router services.
const fixtureProcesses = { singbox: { running: false }, stubby: { running: false } };
let fixtureStartTime = 100;
function fixtureStatus(name) { return { ...fixtureProcesses[name === 'stubby' ? 'stubby' : 'singbox'] }; }
function fixtureRestart(name) {
    const key = name === 'stubby' ? 'stubby' : 'singbox', before = fixtureStatus(key), pid = key === 'stubby' ? '456' : '123';
    fixtureProcesses[key] = { running: true, pid, instance: pid + ':' + (++fixtureStartTime) };
    return { success: true, restarting: true, verification_required: true, previous_running: before.running,
        previous_identity_known: true, ...(before.instance ? { previous_instance: before.instance } : {}) };
}
function multipartFields(body, contentType) {
    const match = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/);
    assert.ok(match, 'multipart boundary is supplied by the browser');
    const boundary = Buffer.from('--' + (match[1] || match[2]));
    const result = {};
    let offset = body.indexOf(boundary) + boundary.length + 2;
    while (offset > 0 && offset < body.length) {
        const headerEnd = body.indexOf('\r\n\r\n', offset);
        if (headerEnd < 0) break;
        const headers = body.subarray(offset, headerEnd).toString();
        const end = body.indexOf(Buffer.concat([Buffer.from('\r\n'), boundary]), headerEnd + 4);
        if (end < 0) break;
        const name = headers.match(/name="([^"]+)"/);
        if (name) result[name[1]] = body.subarray(headerEnd + 4, end).toString('utf8');
        offset = end + 2 + boundary.length + 2;
    }
    return result;
}

const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'POST') frontendPosts.push(url.pathname);
    if (url.pathname === '/cache-prime') {
        res.setHeader('Content-Type', 'text/html');
        res.end(`<!doctype html><html><script src="/common.js?v=${appVersion}"></script></html>`);
    } else if (url.pathname === '/copy-form') {
        res.setHeader('Content-Type', 'text/html'); res.end(copyFixture(url.searchParams.get('view')));
    } else if (url.pathname.startsWith('/copyapi/')) {
        const endpoint = url.pathname.slice('/copyapi/'.length);
        if (req.method === 'POST') {
            const chunks = []; let size = 0;
            req.on('data', data => { size += data.length; assert.ok(size < 5000000); chunks.push(data); });
            req.on('end', () => {
                const body = Buffer.concat(chunks);
                res.setHeader('Content-Type', 'application/json');
                if (['save_config', 'save_stubby_config', 'save_singbox_config', 'import_config', 'import_stubby_config', 'import_singbox_config', 'import_bundle'].includes(endpoint)) {
                    const fields = multipartFields(body, req.headers['content-type']);
                    assert.equal(fields.token, 'browser-token');
                    assert.ok(Buffer.byteLength(fields.content_file) > 102400);
                    contentRequests.push({ endpoint, fields });
                    if (endpoint === 'import_bundle') {
                        const selected = fields.items.split(','), results = {}, restarts = {};
                        for (const name of selected) {
                            results[name] = { ok: true, applied: true };
                            if (['podkop', 'stubby', 'singbox'].includes(name)) {
                                const ack = fixtureRestart(name); restarts[name] = ack;
                                Object.assign(results[name], ack); delete results[name].success;
                            }
                        }
                        const podkop = restarts.podkop || {};
                        res.end(JSON.stringify({ success: true, applied: true, partial: false, complete: true, results, restarts,
                            restarting: podkop.restarting === true, verification_required: podkop.verification_required,
                            previous_running: podkop.previous_running, previous_instance: podkop.previous_instance,
                            previous_identity_known: podkop.previous_identity_known, skipped: Object.keys(JSON.parse(fields.content_file).items).filter(name => !selected.includes(name)) }));
                    } else if (endpoint.startsWith('import_')) {
                        res.end(JSON.stringify({ ...fixtureRestart(endpoint === 'import_stubby_config' ? 'stubby' : 'singbox'), applied: true }));
                    } else {
                        // This transport scenario represents a checked unchanged Save.
                        res.end(JSON.stringify({ success: true, unchanged: true }));
                    }
                } else {
                    const fields = Object.fromEntries(new URLSearchParams(body.toString()));
                    assert.equal(fields.token, 'browser-token');
                    if (['podkop_autostart_toggle', 'stubby_autostart_toggle'].includes(endpoint)) {
                        const name = endpoint.startsWith('stubby') ? 'stubby' : 'podkop';
                        assert.ok(['enable', 'disable'].includes(fields.action));
                        fixtureResponse(req, res, fields, () => {
                            fixtureAutostart[name] = fields.action === 'enable';
                            return { success: true, enabled: fixtureAutostart[name] };
                        }); return;
                    }
                    if (endpoint === 'apply_recommended_stubby' || endpoint === 'stubby_init_fix') {
                        fixtureResponse(req, res, fields, () => endpoint === 'stubby_init_fix' ? { success: true, message: 'Already fixed' } : { ...fixtureRestart('stubby'), applied: true }); return;
                    }
                    subscriptionRequests.push({ endpoint, fields });
                    if (subscriptionFailure) { subscriptionFailure = false; res.statusCode = 403; res.end('<html>LuCI login</html>'); return; }
                    if (endpoint === 'settings_save') {
                        subscriptionSettings.log_display_count = +fields.log_display_count;
                        if (fields.log_only !== '1') Object.assign(subscriptionSettings, { auto_update_interval: +fields.auto_update_interval, auto_update_start: fields.auto_update_start, auto_update_on_restart: fields.auto_update_on_restart === '1' });
                    }
                    if (endpoint === 'wrapper_toggle') {
                        fixtureWrapperInstalled = fields.action !== 'disable';
                        res.end(JSON.stringify({ success: true, installed: fixtureWrapperInstalled })); return;
                    }
                    res.end(JSON.stringify({ success: true, updated: 0, unchanged: 1, failed: 0, skipped: 0, restarted: false, outcomes: [] }));
                }
            });
            return;
        }
        if (['read_config', 'read_stubby_config', 'read_singbox_config'].includes(endpoint)) {
            res.setHeader('Content-Type', 'text/plain');
            res.end(endpoint === 'read_singbox_config' ? '{"outbounds":[]}\n' : endpoint === 'read_stubby_config' ? fixtureStubbyConfig : "config settings 'settings'\n    option enabled '1'\n");
        } else {
            res.setHeader('Content-Type', 'application/json');
            if (['podkop_autostart', 'stubby_autostart'].includes(endpoint)) {
                fixtureResponse(req, res, null, { enabled: fixtureAutostart[endpoint.startsWith('stubby') ? 'stubby' : 'podkop'] }); return;
            }
            if (endpoint === 'stubby_init_check') { fixtureResponse(req, res, null, { status: 'fixed' }); return; }
            if (endpoint === 'wrapper_status') { res.end(JSON.stringify({ installed: fixtureWrapperInstalled, stale: false })); return; }
            if (endpoint === 'fragment_settings') {
                res.end(JSON.stringify(fragmentReadFailure ? { success: false, error: 'Cannot read current Fragment settings' } : { fragment: true, record_fragment: false, fallback_delay: '900ms', settings_source: 'uci', config_missing: false }));
                return;
            }
            if (endpoint === 'singbox_outbounds') {
                res.end(JSON.stringify(outboundReadFailure ? { error: 'jq enumeration failed', details: '<script>literal jq stderr</script>' } : { outbound_count: 0, outbounds: {} }));
                return;
            }
            if (['service_status', 'singbox_service_status', 'stubby_service_status'].includes(endpoint)) {
                fixtureResponse(req, res, null, () => fixtureStatus(endpoint === 'stubby_service_status' ? 'stubby' : 'singbox')); return;
            }
            const response = endpoint === 'read_update_log' ? { lines: copyLogLines } : endpoint === 'subscription_state' ? { sections: [{ name: 'main', proxy_config_type: 'url', slots: [{ index: 0, proxy: { name: 'Example', server: 'example.test', protocol: 'VLESS', security: 'tls' } }] }] } : endpoint === 'settings_read' ? subscriptionSettings : endpoint === 'auto_update_status' ? {
                cron: { enabled: true, matches: !brokenSchedule, running: !brokenSchedule, expected: '30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update' },
                launcher: { matches: !brokenSchedule, executable: !brokenSchedule }, hotplug: { enabled: true, matches: !brokenSchedule, executable: !brokenSchedule },
                last_auto: { ts: '12:00 09.10.2026', updated: 0, unchanged: 2, failed: 1 }
            } : { running: false, status: 'fixed' };
            res.end(JSON.stringify(response));
        }
    } else if (url.pathname === '/local-update-form') {
        res.setHeader('Content-Type', 'text/html'); res.end(updateFixture(url.searchParams.get('case'), url.searchParams.get('_pt_reload')));
    } else if (url.pathname === '/testapi/restart-status') {
        res.setHeader('Content-Type', 'application/json');
        const restarted = localRestart && Date.now() - localRestart.at >= 1500;
        res.end(JSON.stringify(localRestart && localRestart.id === url.searchParams.get('id') ? { ...localRestart, restarted, ready: restarted } : { error: 'No matching operation' }));
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
                localRestart = { id: params.restart_id, at: Date.now(), state: localApplyUncertain ? 'working' : localApplyFailure ? 'failed' : 'applied', expected_version: appVersion, installed_version: appVersion };
                res.end(JSON.stringify(localApplyUncertain ? { success: false, applied: true, error: 'Applied, but web restart could not be scheduled' } : localApplyFailure ? { success: false, error: 'Update application failed', details: 'mock IO failure' } : { success: true, reinstalled: mode === 'same', restart_id: params.restart_id, new_version: appVersion }));
            }
        });
    } else if (url.pathname === '/diagnostics-form') {
        res.setHeader('Content-Type', 'text/html'); res.end(diagnosticsFixture());
    } else if (url.pathname === '/admin/services/podkop') {
        res.setHeader('Content-Type', 'text/html');
        res.end(`<!doctype html><html><body><ul class="cbi-tabmenu"><li data-tab="diagnostic"><a href="#">Diagnostics</a></li></ul><div id="tabs" data-initialized="false"><div id="pane" data-tab="diagnostic" data-tab-active="false">Native Podkop diagnostics</div></div><script>setTimeout(()=>{document.querySelector('a').onclick=(event)=>{event.preventDefault();document.getElementById('pane').setAttribute('data-tab-active','true');};document.getElementById('tabs').setAttribute('data-initialized','true');},300);</script></body></html>`);
    } else if (url.pathname === '/testapi/chain') {
        res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ stubby_listen: '127.0.0.53@53', podkop_dns: '127.0.0.53', resolvers: [{ address: '192.0.2.53', tls_auth_name: 'dot.fixture.test', tls_port: '853' }] }));
    } else if (Object.hasOwn(localDiagnostics, url.pathname.slice('/testapi/'.length)) && url.pathname.startsWith('/testapi/')) {
        assert.equal(req.method, 'POST', 'local diagnostics are CSRF-protected POSTs');
        assert.match(req.headers['content-type'] || '', /^application\/x-www-form-urlencoded\b/);
        let body = '';
        req.on('data', data => { body += data; assert.ok(body.length < 4096); });
        req.on('end', () => {
            const fields = Object.fromEntries(new URLSearchParams(body));
            assert.equal(fields.token, 'browser-token');
            fixtureResponse(req, res, fields, localDiagnostics[url.pathname.slice('/testapi/'.length)]);
        });
    } else if (url.pathname === '/testapi/probe.png') {
        res.setHeader('Content-Type', 'image/png'); res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jPioAAAAASUVORK5CYII=', 'base64'));
    } else if (url.pathname === '/testapi/dns-start' || url.pathname === '/testapi/dns-results') {
        let body = ''; req.on('data', data => { body += data; }); req.on('end', () => {
            res.setHeader('Content-Type', 'application/json');
            if (new URLSearchParams(body).get('token') !== 'browser-token') { res.statusCode = 403; res.end('{}'); return; }
            res.end(JSON.stringify(url.pathname.endsWith('-start') ? { success: true, provider: 'bash.ws', scope: 'current_browser', id: 'native', hosts: Array.from({ length: 6 }, (_, i) => `${i + 1}.native.bash.ws`) } :
                { success: true, id: 'native', complete: true, provider: 'bash.ws', scope: 'current_browser', resolvers: [{ ip: '1.1.1.1', asn: 'AS13335' }], control_request_ips: [{ ip: '203.0.113.1' }], control_request_scope: 'router', conclusion: 'Observations collected, compare intended policy' }));
        });
    } else if (url.pathname === '/api/appearance' || url.pathname === '/api/typography') {
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify(url.pathname.endsWith('/appearance') ? appearanceReadFailure ? { success: false, error: 'Cannot read current appearance settings' } :
            { settings: appearanceState, settings_source: 'uci', config_missing: false } : typographyReadFailure ? { success: false, error: 'Cannot read current Typography settings' } : { settings: typographyState, stale: false, settings_source: 'uci', config_missing: false }));
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
        resourceVersions.push(url.searchParams.get('v'));
        res.setHeader('Content-Type', url.pathname.endsWith('.css') ? 'text/css' : 'text/javascript');
        res.setHeader('Cache-Control', 'public, max-age=31536000');
        if (url.pathname === '/common.js' && url.searchParams.get('v') === appVersion) {
            res.end('window.__ptOldAsset=true;');
            return;
        }
        res.end(fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker', url.pathname.slice(1))));
    } else if (url.pathname === '/argon3.css') {
        res.setHeader('Content-Type', 'text/css'); res.end(argon3Theme);
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
                    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, method === 'Page.captureScreenshot' ? 60000 : 15000);
                    pending.set(id, { resolve, reject, timer });
                    ws.send(JSON.stringify({ id, method, params, sessionId }));
                });
            },
            close() { ws.close(); }
        }));
    });
}

// Expected generic Run Log mirror, independent of each result table's renderer.
function diagnosticLines(entry) {
    const lines = ['took_ms: ' + (entry.took_ms || 0)];
    if (entry.status === 'ERROR') lines.push('http_status: ' + (entry.http_status || 0));
    if (entry.error) lines.push('error: ' + entry.error);
    const value = item => item === null || item === undefined || item === '' ? '-' : typeof item === 'object' ? JSON.stringify(item) : String(item);
    function walk(data, prefix = '') {
        for (const [key, item] of Object.entries(data)) {
            const name = prefix ? prefix + '.' + key : key;
            if (Array.isArray(item)) {
                if (!item.length) lines.push(name + ': []');
                item.forEach((row, index) => lines.push(name + '[' + index + ']: ' + value(row)));
            } else if (item !== null && typeof item === 'object') walk(item, name);
            else lines.push(name + ': ' + value(item));
        }
    }
    if (entry.data && typeof entry.data === 'object') walk(entry.data);
    return lines;
}

async function main() {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const child = spawn(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--remote-debugging-port=0', `--user-data-dir=${path.join(artifacts, 'profile')}`], { stdio: ['ignore', 'ignore', 'pipe'] });
    const browserClosed = new Promise(resolve => child.once('close', resolve));
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
        const wait = async (expression, expected, timeout = 3000) => {
            for (let i = 0; i < Math.ceil(timeout / 30); i++) {
                if (await evaluate(expression) === expected) return;
                await new Promise(resolve => setTimeout(resolve, 30));
            }
            throw new Error(`Waiting for ${expression} === ${expected} failed`);
        };
        const waitFixture = async (predicate, description, timeout = 5000) => {
            const deadline = Date.now() + timeout;
            while (Date.now() < deadline) {
                if (predicate()) return;
                await new Promise(resolve => setTimeout(resolve, 30));
            }
            throw new Error('Waiting for local fixture: ' + description);
        };
        const navigateFixture = async url => {
            const previousOrigin = await evaluate('performance.timeOrigin');
            await cdp.call('Page.navigate', { url }, sessionId);
            await wait(`performance.timeOrigin !== ${previousOrigin}`, true);
            await wait('document.readyState', 'complete');
        };
        const escape = async modalId => {
            await cdp.call('Page.bringToFront', {}, sessionId);
            await cdp.call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, sessionId);
            await cdp.call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, sessionId);
            await wait(`document.getElementById(${JSON.stringify(modalId)}).style.display`, 'none');
        };
        const screenshot = async (name, width) => {
            await cdp.call('Page.bringToFront', {}, sessionId);
            const metrics = await cdp.call('Page.getLayoutMetrics', {}, sessionId);
            assert.ok(metrics.cssContentSize.height < 20000, name + ': unexpected page height ' + metrics.cssContentSize.height);
            const shot = await cdp.call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height: Math.ceil(metrics.cssContentSize.height), scale: 1 } }, sessionId);
            fs.writeFileSync(path.join(artifacts, name + '.png'), Buffer.from(shot.data, 'base64'));
        };
        const setColor = async (role, scheme, value, picker = false) => {
            const id = `ps-color-${role}-${scheme}` + (picker ? '' : '-hex');
            await evaluate(`(() => {const el=document.getElementById(${JSON.stringify(id)});el.value=${JSON.stringify(value)};el.dispatchEvent(new Event('input'));})()`);
        };
        const diagnosticButtons = ['ps-proxy-run', 'ps-dns-run', 'ps-e2e-run', 'ps-leak-run', 'ps-run-all'];
        const diagnosticControls = busy => `[${diagnosticButtons.map(id => `document.getElementById(${JSON.stringify(id)}).disabled`).join(',')}].every(value=>value===${busy})`;
        const assertDiagnosticLog = async () => {
            const snapshot = await evaluate(`({entries:JSON.parse(sessionStorage.getItem('pt-diag-run-log')||'[]'),events:[...document.querySelectorAll('#ps-diaglog-wrap .ps-log-event')].map(el=>({summary:el.querySelector('.ps-log-summary').textContent,lines:[...el.querySelectorAll('.ps-log-detail-line')].map(line=>line.textContent),literal:[...el.querySelectorAll('.ps-log-detail-line')].every(line=>line.childElementCount===0)})),downloadDisabled:document.getElementById('ps-diaglog-download').disabled})`);
            assert.equal(snapshot.events.length, snapshot.entries.length, 'visible events and stored entries have the same count');
            assert.equal(snapshot.downloadDisabled, !snapshot.entries.length, 'partial logs are exportable while a run is still busy');
            snapshot.entries.forEach((entry, index) => {
                assert.match(entry.ts, /^\d{2}:\d{2}:\d{2}$/);
                assert.ok(['OK', 'FAIL', 'ERROR'].includes(entry.status));
                assert.ok(Number.isFinite(entry.took_ms) && entry.took_ms >= 0);
                if (entry.status === 'ERROR') assert.ok(Number.isInteger(entry.http_status) && entry.http_status >= 0);
                assert.ok(snapshot.events[index].summary.includes(entry.test));
                assert.ok(snapshot.events[index].summary.includes(entry.status));
                assert.deepEqual(snapshot.events[index].lines, diagnosticLines(entry), 'visible details mirror every current stored field');
                assert.equal(snapshot.events[index].literal, true, 'log details are literal text, including HTML-shaped errors');
            });
            return snapshot.entries;
        };
        const exportDiagnosticLog = async entries => {
            const count = await evaluate('window.fixtureDownloads.length');
            await evaluate('document.getElementById("ps-diaglog-download").click()');
            await wait('window.fixtureDownloads.length', count + 1);
            assert.deepEqual(await evaluate('window.fixtureDownloadErrors'), []);
            const download = await evaluate('window.fixtureDownloads.at(-1)');
            assert.match(download.filename, /^\d{2}\.\d{2}\.\d{4}_\d{2}\.\d{2}-diagnostics-log\.json$/);
            const data = JSON.parse(download.text);
            assert.equal(data.format, 'pt-diag-run');
            assert.equal(data.tweaker_version, appVersion);
            assert.match(data.exported, /^\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}$/);
            assert.deepEqual(data.entries, entries, 'actual Blob export matches the current partial/full log');
            return data;
        };
        const reports = [];
        for (const [scenario, s, profile] of (focused && !themeOnly ? [] : Object.entries(scenarios)).flatMap(([name, settings]) => ['soft', 'contrast'].map(profile => [name, settings, profile]))) {
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
            if (s.argonMode !== undefined) assert.equal(result.source, 'argon-mode', name + ': the live mode overrides stale context');
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
            if (name === 'argon3-light-stale-dark') {
                // Real change events on a mode selector, native MutationObserver
                // delivery and OS emulation. No reload or explicit detector call
                // is allowed to make a mode transition pass.
                await evaluate(`(() => {document.getElementById('modal').style.display='flex';const editor=document.getElementById('editor');editor.value+='\\nunsaved edit';editor.focus();editor.setSelectionRange(7,19,'backward');window.modeOrigin=performance.timeOrigin;})()`);
                const palettes = {}, liveModes = [];
                const checkMode = async (dark, source = 'argon-mode') => {
                    await wait('document.documentElement.getAttribute("data-pt-dark")', String(dark));
                    const state = await evaluate(`(() => {
                        const editor=document.getElementById('editor'),root=document.documentElement;
                        const palette=Object.fromEntries(['editor','apply','live-status','modal-input','modal-check','diff-check'].map(id=>{
                            const el=document.getElementById(id),css=getComputedStyle(el),checkbox=id.endsWith('check');
                            // Custom checkboxes paint an SVG/pseudo-element, not
                            // their inherited (invisible) input text color.
                            return [id,checkbox?{background:css.backgroundColor,image:css.backgroundImage,border:css.borderColor,width:css.width,mark:id==='diff-check'?getComputedStyle(el,'::after').borderColor:null}:{color:css.color,background:css.backgroundColor}];
                        }));
                        return {mode:root.getAttribute('data-argon-mode'),dark:root.getAttribute('data-pt-dark'),source:root.getAttribute('data-pt-scheme-source'),palette,edited:editor.value.endsWith('unsaved edit'),focus:document.activeElement.id,start:editor.selectionStart,end:editor.selectionEnd,direction:editor.selectionDirection,samePage:performance.timeOrigin===window.modeOrigin};
                    })()`);
                    assert.equal(state.source, source);
                    assert.equal(state.edited, true); assert.equal(state.samePage, true);
                    assert.equal(state.focus, 'editor'); assert.equal(state.start, 7); assert.equal(state.end, 19); assert.equal(state.direction, 'backward');
                    assert.equal(state.palette['live-status'].color, dark ? 'rgb(0, 255, 0)' : 'rgb(0, 190, 0)');
                    assert.equal(state.palette['modal-check'].width, '16px'); assert.equal(state.palette['diff-check'].width, '14px');
                    if (palettes[String(dark)]) assert.deepEqual(state.palette, palettes[String(dark)], 'existing controls must recolor consistently without rebuilding');
                    else palettes[String(dark)] = state.palette;
                    liveModes.push(state);
                };
                const selectMode = async (mode, dark) => {
                    await evaluate(`(() => {const selector=document.getElementById('argon-mode');selector.value=${JSON.stringify(mode)};selector.dispatchEvent(new Event('change',{bubbles:true}));})()`);
                    await checkMode(dark);
                };
                const osMode = async (os, dark) => {
                    await cdp.call('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: os }] }, sessionId);
                    // Wait for rendering/media change delivery even when a forced
                    // scheme should stay unchanged, so that check cannot pass early.
                    const frame = await cdp.call('Runtime.evaluate', { expression: 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))', awaitPromise: true }, sessionId);
                    assert.equal(frame.exceptionDetails, undefined);
                    await checkMode(dark);
                };
                await checkMode(false);
                await selectMode('dark', true);
                await osMode('light', true);
                await osMode('dark', true);
                await selectMode('light', false);
                await osMode('light', false);
                await osMode('dark', false);
                await selectMode('normal', true);
                await osMode('light', false);
                await osMode('dark', true);
                await osMode('light', false);
                await evaluate(`document.documentElement.setAttribute('data-argon-mode','invalid')`);
                await checkMode(true, 'argon-config');
                await evaluate(`document.documentElement.removeAttribute('data-argon-mode')`);
                await checkMode(true, 'argon-config');
                await selectMode('normal', false);
                assert.equal(await evaluate('document.getElementById("ps-theme-context").getAttribute("data-mode")'), 'dark', 'the server snapshot remains stale through live changes');
                assert.notDeepEqual(palettes.true.editor, palettes.false.editor);
                assert.notDeepEqual(palettes.true['modal-input'], palettes.false['modal-input']);
                reports.at(-1).liveModes = liveModes;
                await screenshot('argon3-live-mode', 1440);
                await evaluate(`document.getElementById('modal').style.display='none'`);
                console.log('PASS Argon 3 live mode: 14 states, selector/OS changes, stale/invalid/removed markers, editor/modal controls and unsaved selection preserved');
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
        if (!updateOnly && !copyOnly && !themeOnly) {
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
        for (const width of [390, 768]) {
            await cdp.call('Emulation.setDeviceMetricsOverride', { width, height: 844, deviceScaleFactor: 1, mobile: false }, sessionId);
            const layout = await evaluate(`(() => {const wrap=document.querySelector('.ps-split-5050'),w=wrap.getBoundingClientRect(),a=wrap.querySelector('.ps-split-left').getBoundingClientRect(),b=wrap.querySelector('.ps-split-right').getBoundingClientRect();return {width:w.width,left:a.width,right:b.width,stacked:b.top>=a.bottom,overflow:document.documentElement.scrollWidth>innerWidth,offenders:Array.from(wrap.querySelectorAll('*')).filter(el=>el.getBoundingClientRect().right>innerWidth+1).map(el=>({tag:el.tagName,id:el.id,cls:el.className,right:el.getBoundingClientRect().right,text:el.textContent.slice(0,60)}))};})()`);
            assert.ok(Math.abs(layout.left - layout.width) < 1 && Math.abs(layout.right - layout.width) < 1, 'both mobile Diagnostics panels must use the full width');
            assert.equal(layout.stacked, true); assert.equal(layout.overflow, false, JSON.stringify(layout));
            if (width === 390) await screenshot('diagnostics-mobile', width);
        }
        await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);

        const localReport = { progressive: [], errors: [] };
        const localNames = { diag_proxy: 'Proxy Connectivity Test', diag_dns: 'DNS Resolution Test', diag_e2e: 'End-to-End Test' };
        const localButtons = { diag_proxy: 'ps-proxy-run', diag_dns: 'ps-dns-run', diag_e2e: 'ps-e2e-run' };
        const order = ['diag_proxy', 'diag_dns', 'diag_e2e'];
        const postsBeforeAll = frontendPosts.length;
        const held = order.map(endpoint => queueFixtureReply('/testapi/' + endpoint, localDiagnostics[endpoint], { hold: true }));
        const probesBeforeAll = await evaluate('window.probeURLs.length');
        await evaluate('document.getElementById("ps-run-all").click()');
        await waitFixture(() => held[0].request, 'Run All Proxy request');
        assert.deepEqual(await assertDiagnosticLog(), [], 'Run All clears the previous external-observation log once');
        assert.equal(await evaluate(diagnosticControls(true)), true);
        assert.equal(held[1].request, undefined, 'DNS cannot start while Proxy is pending');
        assert.equal(held[2].request, undefined, 'E2E cannot start while Proxy is pending');
        for (let index = 0; index < held.length; index++) {
            const plan = held[index];
            await waitFixture(() => plan.request, order[index] + ' request');
            assert.deepEqual(plan.request.fields, { token: 'browser-token' });
            if (index) assert.ok(plan.request.receivedAt - held[index - 1].sentAt >= 450, 'Run All retains the real 500ms inter-test pause');
            plan.release();
            await wait('JSON.parse(sessionStorage.getItem("pt-diag-run-log")).length', index + 1);
            const entries = await assertDiagnosticLog();
            assert.deepEqual(entries.map(entry => entry.test), order.slice(0, index + 1).map(endpoint => localNames[endpoint]));
            assert.equal(entries.every(entry => entry.status === 'OK'), true);
            if (index < 2) {
                assert.equal(await evaluate(diagnosticControls(true)), true, 'individual completions cannot unlock Run All');
                assert.equal(held[index + 1].sentAt, undefined, 'later results are still pending');
            }
            localReport.progressive.push(await exportDiagnosticLog(entries));
            if (index === 1) await screenshot('diagnostics-run-all-progressive', 1440);
        }
        await wait(diagnosticControls(false), true);
        assert.equal(await evaluate('document.getElementById("ps-run-all").textContent'), 'Run All Diagnostics');
        assert.deepEqual(frontendPosts.slice(postsBeforeAll), order.map(endpoint => '/testapi/' + endpoint), 'Run All is exactly Proxy → DNS → E2E, with no external-provider requests');
        assert.equal(await evaluate('window.probeURLs.length'), probesBeforeAll, 'Run All cannot create browser DNS probes');
        const completeLog = await assertDiagnosticLog();
        assert.deepEqual(completeLog[0].data, { http_code: 204, time_ms: 37, source: localDiagnostics.diag_proxy.results[0].source, results: localDiagnostics.diag_proxy.results });
        assert.deepEqual(completeLog[1].data, { rows: localDiagnostics.diag_dns.results });
        assert.deepEqual(completeLog[2].data, { external_ip: '198.51.100.24', http_code: 204, time_ms: 61 });
        for (const [endpoint, tableId, columns] of [
            ['diag_proxy', 'ps-proxy-body', ['source', 'http_code', 'time_ms', 'status']],
            ['diag_dns', 'ps-dns-body', ['source', 'target', 'ip', 'status']]
        ]) {
            const rows = await evaluate(`[...document.querySelectorAll('#${tableId} tr')].map(row=>[...row.cells].map(cell=>cell.textContent.trim()))`);
            assert.deepEqual(rows, localDiagnostics[endpoint].results.map(row => columns.map(key => String(row[key]) + (key === 'time_ms' ? ' ms' : ''))));
        }
        assert.deepEqual(await evaluate(`[...document.querySelectorAll('#ps-e2e-ip,#ps-e2e-http,#ps-e2e-time,#ps-e2e-status')].map(el=>el.textContent)`), ['198.51.100.24', '204', '61 ms', 'OK']);
        assert.equal(await evaluate(`[...document.querySelectorAll('#ps-chain-content .ps-chain-line')].filter(el=>['chain-client','chain-singbox','chain-stubby','chain-upstream-0'].includes(el.id)).every(el=>el.classList.contains('ps-chain-ok'))`), true);
        const nativeDeadlines = await evaluate('window.fixtureXHR.filter(request=>request.url.startsWith("/testapi/diag_"))');
        assert.deepEqual(nativeDeadlines.map(request => request.url), order.map(endpoint => '/testapi/' + endpoint));
        nativeDeadlines.forEach(request => assert.ok(Number.isSafeInteger(request.timeout) && request.timeout > 0, 'each native local diagnostic XHR has a finite operation deadline'));
        assert.ok(nativeDeadlines[1].timeout > nativeDeadlines[0].timeout && nativeDeadlines[1].timeout > nativeDeadlines[2].timeout, 'serial DNS lookups retain their separate longer budget');
        localReport.deadlines = nativeDeadlines;
        await screenshot('diagnostics-run-all-complete', 1440);

        const originBeforeDiagnosticsReload = await evaluate('performance.timeOrigin');
        const postsBeforeDiagnosticsReload = frontendPosts.length;
        await cdp.call('Page.reload', {}, sessionId);
        await wait(`performance.timeOrigin !== ${originBeforeDiagnosticsReload}`, true);
        await wait('document.readyState', 'complete');
        assert.deepEqual(await assertDiagnosticLog(), completeLog, 'a real page refresh restores the full log without running tests');
        assert.equal(frontendPosts.length, postsBeforeDiagnosticsReload);
        await exportDiagnosticLog(completeLog);

        // A failed result and a typed application error both allow the remaining
        // local tests to run; the error cannot turn an empty DNS result into OK.
        const failedProxy = { results: [{ source: 'sing-box mixed (:2080)', http_code: 503, time_ms: 12, status: 'FAIL' }] };
        const dnsError = { success: false, error: 'Fixture DNS unavailable <literal>', details: '<img src=x onerror=fixtureInjection()>\ncomplete local DNS diagnostics', results: [] };
        queueFixtureReply('/testapi/diag_proxy', failedProxy);
        queueFixtureReply('/testapi/diag_dns', dnsError);
        queueFixtureReply('/testapi/diag_e2e', localDiagnostics.diag_e2e);
        const postsBeforeMixed = frontendPosts.length;
        await evaluate('document.getElementById("ps-run-all").click()');
        await wait(diagnosticControls(false), true, 5000);
        const mixedLog = await assertDiagnosticLog();
        assert.deepEqual(mixedLog.map(entry => entry.test), order.map(endpoint => localNames[endpoint]));
        assert.equal(mixedLog[0].status, 'FAIL');
        assert.notEqual(mixedLog[1].status, 'OK', 'an application error is never an empty successful DNS test');
        assert.ok(mixedLog[1].error.includes(dnsError.error));
        assert.equal(mixedLog[2].status, 'OK', 'Run All continues to E2E after both FAIL and ERROR');
        assert.deepEqual(frontendPosts.slice(postsBeforeMixed), order.map(endpoint => '/testapi/' + endpoint));
        localReport.mixed = await exportDiagnosticLog(mixedLog);

        const singleDiagnostic = async (endpoint, data, options = {}) => {
            const postsBefore = frontendPosts.length;
            const plan = queueFixtureReply('/testapi/' + endpoint, data, { ...options, hold: true });
            await evaluate(`document.getElementById(${JSON.stringify(localButtons[endpoint])}).click()`);
            await waitFixture(() => plan.request, endpoint + ' single request');
            assert.equal(await evaluate(diagnosticControls(true)), true);
            assert.deepEqual(await assertDiagnosticLog(), [], 'a new single test discards the entire preceding run');
            plan.release();
            await wait(diagnosticControls(false), true);
            const entries = await assertDiagnosticLog();
            assert.equal(entries.length, 1, 'each terminal response appends exactly one entry');
            assert.equal(entries[0].test, localNames[endpoint]);
            assert.deepEqual(frontendPosts.slice(postsBefore), ['/testapi/' + endpoint], 'completion cannot replay a request or launch another runner');
            return entries[0];
        };
        const primeE2e = async () => {
            const entry = await singleDiagnostic('diag_e2e', localDiagnostics.diag_e2e);
            assert.equal(entry.status, 'OK');
            assert.equal(await evaluate('document.getElementById("ps-e2e-http").textContent'), '204');
            assert.equal(await evaluate('document.getElementById("ps-e2e-time").textContent'), '61 ms');
        };
        const assertClearedE2e = async () => {
            const fields = await evaluate(`({ip:document.getElementById('ps-e2e-ip').textContent,http:document.getElementById('ps-e2e-http').textContent,time:document.getElementById('ps-e2e-time').textContent,status:document.getElementById('ps-e2e-status').textContent})`);
            assert.notEqual(fields.ip, localDiagnostics.diag_e2e.external_ip, 'failed E2E cannot show a previous successful external IP');
            assert.ok(['', '\u2014'].includes(fields.http), 'failed E2E clears the previous HTTP status');
            assert.ok(['', '\u2014'].includes(fields.time), 'failed E2E clears the previous response time');
            assert.notEqual(fields.status, 'OK', 'failed E2E clears the previous OK verdict');
        };
        for (const endpoint of order) {
            for (const failure of [
                { name: 'application', data: { success: false, error: `Fixture ${endpoint} failed <literal>`, details: 'complete fixture diagnostic\n' + 'detail\n'.repeat(80) } },
                { name: 'schema', data: {} },
                { name: 'HTML session', data: null, raw: '<!doctype html><html><body>Fixture LuCI login</body></html>', contentType: 'text/html' }
            ]) {
                if (endpoint === 'diag_e2e') await primeE2e();
                const entry = await singleDiagnostic(endpoint, failure.data, failure);
                assert.notEqual(entry.status, 'OK', endpoint + ': ' + failure.name + ' cannot be successful');
                if (failure.name !== 'application') assert.equal(entry.status, 'ERROR', 'malformed/HTML replies are typed request errors');
                assert.ok(entry.error, 'a request/schema error keeps an explicit reason');
                if (failure.name === 'application') assert.ok(entry.error.includes(failure.data.error));
                if (endpoint === 'diag_e2e') await assertClearedE2e();
                localReport.errors.push({ endpoint, failure: failure.name, entry });
            }
        }
        for (const failure of [
            { name: 'HTTP 503', data: { error: 'Fixture E2E backend unavailable', details: 'complete HTTP failure' }, status: 503 },
            { name: 'invalid JSON', data: null, raw: '{broken fixture JSON' }
        ]) {
            await primeE2e();
            const entry = await singleDiagnostic('diag_e2e', failure.data, failure);
            assert.equal(entry.status, 'ERROR');
            assert.equal(entry.http_status, failure.status || 200);
            await assertClearedE2e();
            localReport.errors.push({ endpoint: 'diag_e2e', failure: failure.name, entry });
        }

        // Exercise one real native deadline without shortening production timers:
        // Proxy has a single curl budget; DNS deliberately has a much longer one.
        const timedOutProxy = queueFixtureReply('/testapi/diag_proxy', localDiagnostics.diag_proxy, { hold: true });
        const postsBeforeTimeout = frontendPosts.length;
        await evaluate('document.getElementById("ps-proxy-run").click()');
        await waitFixture(() => timedOutProxy.request, 'native Proxy timeout request');
        const proxyDeadline = await evaluate('window.fixtureXHR.at(-1).timeout');
        assert.ok(proxyDeadline > 0 && proxyDeadline <= 30000, 'native Proxy deadline must fit its single-curl budget');
        await wait(diagnosticControls(false), true, proxyDeadline + 4000);
        const timedOutLog = await assertDiagnosticLog();
        assert.equal(timedOutLog.length, 1);
        assert.equal(timedOutLog[0].status, 'ERROR');
        assert.equal(timedOutLog[0].http_status, 0);
        assert.match(timedOutLog[0].error, /timed out|timeout/i);
        timedOutProxy.release();
        await new Promise(resolve => setTimeout(resolve, 150));
        assert.deepEqual(await assertDiagnosticLog(), timedOutLog, 'late timeout/load completion cannot append twice');
        assert.deepEqual(frontendPosts.slice(postsBeforeTimeout), ['/testapi/diag_proxy'], 'a timed-out diagnostic request is never replayed');
        localReport.timeout = timedOutLog[0];

        // Navigating away from a held operation cannot let its eventual reply
        // append a ghost completion to the refreshed page's session-scoped log.
        const abandoned = queueFixtureReply('/testapi/diag_dns', localDiagnostics.diag_dns, { hold: true });
        await evaluate('document.getElementById("ps-dns-run").click()');
        await waitFixture(() => abandoned.request, 'abandoned DNS request');
        const originBeforeAbandon = await evaluate('performance.timeOrigin');
        await cdp.call('Page.navigate', { url: base + '/diagnostics-form' }, sessionId);
        await wait(`performance.timeOrigin !== ${originBeforeAbandon}`, true);
        await wait('document.readyState', 'complete');
        abandoned.release();
        await new Promise(resolve => setTimeout(resolve, 150));
        assert.deepEqual(await assertDiagnosticLog(), []);
        const postsBeforeManualObservation = frontendPosts.length;
        await evaluate('document.getElementById("ps-leak-run").click()');
        await wait('document.getElementById("ps-leak-status").textContent', 'OBSERVATIONS COLLECTED');
        assert.deepEqual(frontendPosts.slice(postsBeforeManualObservation), ['/testapi/dns-start', '/testapi/dns-results'], 'manual external observation stays separate after local runs and failures');
        assert.equal(await evaluate('window.probeURLs.length'), 6);
        const finalObservation = await assertDiagnosticLog();
        assert.equal(finalObservation.length, 1);
        assert.equal(finalObservation[0].test, 'External DNS Observation (browser)');
        assert.equal(finalObservation[0].data.probes_completed, 6);
        localReport.manualObservation = await exportDiagnosticLog(finalObservation);
        fs.writeFileSync(path.join(artifacts, 'diagnostics-local.json'), JSON.stringify(localReport, null, 2));
        console.log('PASS real local Diagnostics: progressive Proxy → 500ms → DNS → 500ms → E2E, partial/full Blob export+refresh mirror, FAIL/error continuation, typed schema/HTML failures, cleared stale E2E fields, native deadlines and separate external observation');
        }
        if (!diagnosticsOnly && !copyOnly && !themeOnly) {
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
                    localApplyUncertain = true;
                    await evaluate('document.getElementById("ps-apply-btn").click()');
                    await wait('!!document.querySelector("#ps-apply-status .ps-restart-retry")', true);
                    const gap = await evaluate(`(() => {const status=document.getElementById('ps-apply-status'),button=status.querySelector('.ps-restart-retry'),range=document.createRange();range.selectNodeContents(status.firstChild);return button.getBoundingClientRect().left-range.getBoundingClientRect().right;})()`);
                    assert.ok(gap >= 8, 'Retry verification must be spaced from the preceding error text');
                    assert.equal(await evaluate('document.getElementById("ps-apply-btn").disabled'), true);
                    assert.equal(await evaluate('document.getElementById("ps-file-input").disabled'), true);
                    localApplyUncertain = false;
                    await cdp.call('Page.navigate', { url: base + '/local-update-form?case=same' }, sessionId);
                    await wait('document.readyState', 'complete');
                    await evaluate(`(() => {const transfer=new DataTransfer();transfer.items.add(new File(['archive'],'luci-app-podkop-tweaker-v${appVersion}.tar.gz'));const input=document.getElementById('ps-file-input');input.files=transfer.files;input.dispatchEvent(new Event('change'));})()`);
                    await wait('document.getElementById("ps-file-input").disabled', false);
                    await evaluate('document.getElementById("ps-apply-btn").click()');
                    await wait('document.getElementById("ps-apply-status").textContent', 'Waiting for LuCI and operation confirmation...');
                    assert.equal(await evaluate('document.getElementById("ps-file-input").disabled'), true);
                    const id = localApplyRequests.at(-1).params.restart_id;
                    assert.match(id, /^[a-f0-9]{32}$/);
                    await wait('location.search.includes("_pt_reload=")', true);
                    await wait('document.readyState', 'complete');
                    assert.ok(resourceVersions.includes(assetBaseVersion + '-' + id), 'reinstall refreshes equal-version assets');
                }
            }
            console.log('PASS real Local Update form: Update/Reinstall/older actions, multipart+CSRF, explicit reinstall flag, failure recovery and success lock');
        }
        if (!focused || reliabilityOnly) {
            typographyReadFailure = appearanceReadFailure = true;
            await cdp.call('Page.navigate', { url: base + '/appearance-form' }, sessionId);
            await wait('document.getElementById("ps-argon-retry")?.style.display', 'inline-block');
            await wait('document.getElementById("ps-appearance-retry")?.style.display', 'inline-block');
            const postsBeforeReadGates = frontendPosts.length;
            await evaluate(`(() => {for(const id of ['ps-argon-save','ps-argon-reset','ps-argon-reinject','ps-appearance-save','ps-appearance-reset','ps-colors-reset']){const el=document.getElementById(id);if(!el.disabled)throw new Error(id+' must wait for a typed GET');el.dispatchEvent(new MouseEvent('click',{bubbles:true}));}})()`);
            assert.equal(await evaluate('document.getElementById("ps-argon-css-status").textContent'), 'CSS status unknown');
            assert.equal(frontendPosts.length, postsBeforeReadGates, 'failed native Typography read cannot POST defaults');
            typographyReadFailure = appearanceReadFailure = false;
            await evaluate('document.getElementById("ps-argon-retry").click();document.getElementById("ps-appearance-retry").click()');
            await wait('document.getElementById("ps-argon-save").disabled', false);
            await wait('document.getElementById("ps-appearance-save").disabled', false);
            assert.equal(await evaluate('document.getElementById("ps-font-size").value'), '17');
            assert.equal(await evaluate('document.documentElement.style.fontSize'), '', 'typed retry is not a global preview event');

            fragmentReadFailure = outboundReadFailure = true;
            await cdp.call('Page.navigate', { url: base + '/copy-form?view=singbox' }, sessionId);
            await wait('document.getElementById("ps-wrapper-btn")?.textContent', 'Enable Wrapper');
            await evaluate('document.getElementById("ps-wrapper-btn").click()');
            await wait('document.getElementById("ps-wrapper-retry").style.display', 'inline-block');
            await evaluate(`document.getElementById('ps-wrapper-confirm').dispatchEvent(new MouseEvent('click',{bubbles:true}))`);
            assert.equal(await evaluate('document.getElementById("ps-wrapper-confirm").disabled'), true);
            assert.equal(frontendPosts.length, postsBeforeReadGates, 'failed native Fragment read cannot enable defaults');
            fragmentReadFailure = false;
            await evaluate('document.getElementById("ps-wrapper-retry").click()');
            await wait('document.getElementById("ps-wrapper-confirm").disabled', false);
            assert.equal(await evaluate('document.getElementById("ps-wrap-fragment").checked'), true);
            assert.equal(await evaluate('document.getElementById("ps-wrap-record-fragment").checked'), false);
            assert.equal(await evaluate('document.getElementById("ps-wrap-fallback-delay").value'), '900ms');
            await escape('ps-wrapper-modal');
            await evaluate('document.getElementById("ps-patch-btn").click()');
            await wait('document.getElementById("ps-patch-status").textContent.includes("jq enumeration failed")', true);
            assert.equal(await evaluate('document.getElementById("ps-patch-list").textContent.includes("No TLS")'), false);
            assert.equal(await evaluate('document.getElementById("ps-patch-status").querySelector("pre").textContent'), '<script>literal jq stderr</script>');
            await evaluate(`document.getElementById('ps-patch-apply').dispatchEvent(new MouseEvent('click',{bubbles:true}))`);
            assert.equal(frontendPosts.length, postsBeforeReadGates, 'failed enumeration cannot patch stale outbounds');
            outboundReadFailure = false;
            await evaluate('document.getElementById("ps-patch-retry").click()');
            await wait('document.getElementById("ps-patch-list").textContent', 'No TLS outbounds found.');
            assert.equal(await evaluate('document.getElementById("ps-patch-apply").disabled'), true);
            await escape('ps-patch-modal');
            console.log('PASS native typed-read gates: Typography/Fragment failed GET and explicit retry, no forged/default POST, plaintext outbound failure vs explicit count-zero empty');

            const editorError = async () => {
                await wait('document.getElementById("ps-error-btn").style.display', 'inline-block');
                await evaluate('document.getElementById("ps-error-btn").click()');
                const error = await evaluate(`({text:document.getElementById('ps-error-details').textContent,literal:document.getElementById('ps-error-details').childElementCount===0})`);
                assert.equal(error.literal, true, 'native editor diagnostics stay literal text');
                await escape('ps-error-modal');
                return error.text;
            };
            const autostartReport = [];
            for (const [view, name] of [['config', 'podkop'], ['stubby', 'stubby']]) {
                const readURL = '/copyapi/' + name + '_autostart', toggleURL = readURL + '_toggle';
                for (const failure of [
                    { name: 'missing enabled', data: {} },
                    { name: 'string enabled', data: { enabled: 'false' } },
                    { name: 'error with enabled', data: { error: 'Fixture boot-link read failed', enabled: false, details: '<script>literal read diagnostics</script>' } },
                    { name: 'HTTP session', data: null, status: 403, raw: '<html>Fixture LuCI login</html>', contentType: 'text/html' }
                ]) {
                    const read = queueFixtureReply(readURL, failure.data, { ...failure, hold: true });
                    await navigateFixture(base + '/copy-form?view=' + view);
                    await wait('document.getElementById("ps-config-editor")?.disabled', false);
                    await waitFixture(() => read.request, name + ' autostart failed read');
                    read.release();
                    await wait('document.getElementById("ps-error-btn").style.display', 'inline-block');
                    assert.equal(await evaluate('document.getElementById("ps-autostart-btn").textContent'), 'Autostart: Unknown');
                    assert.equal(await evaluate('document.getElementById("ps-autostart-btn").disabled'), true);
                    const forged = await evaluate(`(() => {const count=window.fixtureXHR.filter(request=>request.method==='POST').length;document.getElementById('ps-autostart-btn').dispatchEvent(new MouseEvent('click',{bubbles:true}));return window.fixtureXHR.filter(request=>request.method==='POST').length-count;})()`);
                    assert.equal(forged, 0, 'a forged click cannot mutate autostart after an untyped read');
                    const details = await editorError();
                    if (failure.data && failure.data.error) {
                        assert.ok(details.includes(failure.data.error));
                        assert.ok(details.includes(failure.data.details));
                    }
                    autostartReport.push({ name, scenario: failure.name, state: 'Unknown' });
                }
                for (const enabled of [true, false]) {
                    fixtureAutostart[name] = enabled;
                    await navigateFixture(base + '/copy-form?view=' + view);
                    await wait('document.getElementById("ps-autostart-btn")?.textContent', 'Autostart: ' + (enabled ? 'ON' : 'OFF'));
                    await wait('document.getElementById("ps-config-editor").disabled', false);
                    const update = queueFixtureReply(toggleURL, undefined, { hold: true });
                    const before = fixtureCalls.length;
                    await evaluate('document.getElementById("ps-autostart-btn").click()');
                    await waitFixture(() => update.request, name + ' autostart toggle');
                    assert.equal(await evaluate('document.getElementById("ps-autostart-btn").disabled'), true);
                    assert.deepEqual(update.request.fields, { token: 'browser-token', action: enabled ? 'disable' : 'enable' });
                    update.release();
                    await wait('document.getElementById("ps-autostart-btn").textContent', 'Autostart: ' + (enabled ? 'OFF' : 'ON'));
                    assert.equal(await evaluate('document.getElementById("ps-autostart-btn").disabled'), false);
                    assert.equal(fixtureAutostart[name], !enabled);
                    assert.deepEqual(fixtureCalls.slice(before).filter(call => call.endpoint === readURL || call.endpoint === toggleURL).map(call => [call.method, call.endpoint]), [['POST', toggleURL], ['GET', readURL]], 'checked autostart mutation is followed by one read-only factual readback');
                }

                // A checked POST error is still reported when factual readback
                // succeeds; the error's enabled=false is not a new OFF fact.
                fixtureAutostart[name] = true;
                await navigateFixture(base + '/copy-form?view=' + view);
                await wait('document.getElementById("ps-autostart-btn")?.textContent', 'Autostart: ON');
                await wait('document.getElementById("ps-config-editor").disabled', false);
                const commandError = { success: false, error: 'Fixture autostart command failed', details: '<img src=x onerror=fixtureInjection()>\nfull boot-link command stderr', enabled: false };
                const failedUpdate = queueFixtureReply(toggleURL, commandError, { hold: true });
                const postsBeforeAutostartError = frontendPosts.length;
                await evaluate('document.getElementById("ps-autostart-btn").click()');
                await waitFixture(() => failedUpdate.request, name + ' checked autostart error');
                failedUpdate.release();
                await wait('document.getElementById("ps-autostart-btn").textContent', 'Autostart: ON');
                const commandDetails = await editorError();
                assert.ok(commandDetails.includes(commandError.error));
                assert.ok(commandDetails.includes(commandError.details));
                assert.deepEqual(frontendPosts.slice(postsBeforeAutostartError), [toggleURL], 'autostart command errors never trigger a second POST');

                const readbackError = { error: 'Fixture autostart readback failed', details: '<script>literal readback output</script>' };
                queueFixtureReply(readURL, readbackError);
                queueFixtureReply(toggleURL, { success: true, enabled: false }, { effect() { fixtureAutostart[name] = false; } });
                const postsBeforeReadbackError = frontendPosts.length;
                await evaluate('document.getElementById("ps-autostart-btn").click()');
                await wait('document.getElementById("ps-autostart-btn").title.includes("readback failed")', true);
                assert.equal(await evaluate('document.getElementById("ps-autostart-btn").textContent'), 'Autostart: Unknown');
                assert.equal(await evaluate('document.getElementById("ps-autostart-btn").disabled'), true);
                const readbackDetails = await editorError();
                assert.ok(readbackDetails.includes(readbackError.error));
                assert.ok(readbackDetails.includes(readbackError.details));
                assert.deepEqual(frontendPosts.slice(postsBeforeReadbackError), [toggleURL]);
                autostartReport.push({ name, scenario: 'boolean ON/OFF, checked POST error and failed factual readback' });
                fixtureAutostart[name] = false;
            }
            console.log('PASS native Podkop/Stubby autostart: typed ON/OFF, Unknown/error/HTML gates, forged-click suppression, checked mutation and factual re-read without POST replay');

            const originalStubbyProcess = fixtureStatus('stubby');
            const stubbyActions = [
                { name: 'Template', endpoint: '/copyapi/apply_recommended_stubby', open: 'ps-params-btn', modal: 'ps-params-modal', apply: 'ps-apply-template-btn', status: 'ps-apply-template-status', reload: true },
                { name: 'Init fix', endpoint: '/copyapi/stubby_init_fix', open: 'ps-initfix-btn', modal: 'ps-initfix-modal', apply: 'ps-initfix-apply', status: 'ps-initfix-apply-status', reload: false }
            ];
            const stubbyReport = [];
            const loadStubby = async () => {
                // Use the real Undo action before navigation if a preceding
                // partial Template result deliberately preserved a dirty draft.
                await evaluate(`(() => {const undo=document.getElementById('ps-config-undo'),save=document.getElementById('ps-config-save');if(undo&&!undo.disabled&&save&&!save.disabled){window.confirm=()=>true;undo.click();}})()`);
                fixtureStubbyConfig = initialStubbyConfig;
                fixtureProcesses.stubby = { running: true, pid: '456', instance: '456:' + (++fixtureStartTime) };
                await navigateFixture(base + '/copy-form?view=stubby');
                await wait('document.getElementById("ps-config-editor")?.value', initialStubbyConfig);
                await wait('document.getElementById("ps-config-editor").disabled', false);
                await wait('document.getElementById("ps-status-text").textContent.includes("Running")', true);
                await wait('document.getElementById("ps-initfix-status").textContent', 'Running as root');
                await wait('document.getElementById("ps-autostart-btn").textContent', 'Autostart: OFF');
                await evaluate('window.confirm=()=>true');
            };
            const openStubbyAction = async action => {
                await evaluate(`document.getElementById(${JSON.stringify(action.open)}).click()`);
                await wait(`document.getElementById(${JSON.stringify(action.modal)}).style.display`, 'flex');
            };
            const applyStubbyAction = async action => {
                await openStubbyAction(action);
                await evaluate(`document.getElementById(${JSON.stringify(action.apply)}).click()`);
            };
            const stubbyFailureFrames = async (action, message, details) => {
                await wait(`document.getElementById(${JSON.stringify(action.status)}).textContent.includes(${JSON.stringify(message)})`, true);
                for (const id of [action.status, 'ps-stubby-action-status']) {
                    const frame = await evaluate(`(() => {const el=document.getElementById(${JSON.stringify(id)}),pre=el.querySelector('pre');return {message:el.textContent,details:pre&&pre.textContent,literal:!!pre&&pre.childElementCount===0};})()`);
                    assert.ok(frame.message.includes(message));
                    assert.equal(frame.details, message + '\n\n' + details, 'both page and current modal keep the exact contextual message plus verbatim complete response diagnostics');
                    assert.equal(frame.literal, true);
                }
            };
            for (const action of stubbyActions) {
                for (const outcome of ['rejected', 'applied restart failure', 'applied unknown']) {
                    await loadStubby();
                    const details = '<img src=x onerror=fixtureInjection()>\n' + 'complete Stubby diagnostic\n'.repeat(600) + 'last diagnostic line';
                    const response = { success: false, error: 'Fixture ' + action.name + ' ' + outcome, details,
                        ...(outcome !== 'rejected' ? { applied: true } : {}), ...(outcome === 'applied unknown' ? { unknown: true } : {}) };
                    const draft = initialStubbyConfig + "    option tls_min_version '1.3'\n";
                    if (action.reload && outcome !== 'rejected') {
                        await evaluate(`document.getElementById('ps-config-editor').value=${JSON.stringify(draft)};document.getElementById('ps-config-editor').dispatchEvent(new Event('input'))`);
                    }
                    const plan = queueFixtureReply(action.endpoint, response, { hold: true, effect() {
                        if (action.reload && response.applied) fixtureStubbyConfig = "config stubby 'global'\n    option log_level '4'\n";
                    } });
                    const before = frontendPosts.length;
                    await applyStubbyAction(action);
                    await waitFixture(() => plan.request, action.name + ' ' + outcome);
                    assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.apply)}).disabled`), true);
                    assert.deepEqual(plan.request.fields, { token: 'browser-token' });
                    plan.release();
                    const appliedMessage = action.reload ? 'Template applied to disk.' : 'Init script fix applied to disk.';
                    const expectedMessage = response.unknown ? appliedMessage + ' Finishing result unknown. Reload the page to verify before another operation. ' + response.error :
                        response.applied ? appliedMessage + ' Restart failed or is unverified. ' + response.error : response.error;
                    await stubbyFailureFrames(action, expectedMessage, details);
                    const status = await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`);
                    if (response.applied) assert.match(status, /applied to disk/i, 'actual disk application remains distinct from service completion');
                    if (response.unknown) assert.match(status, /result unknown/i);
                    assert.doesNotMatch(status, /new Stubby instance is running|Stubby restarted/);
                    if (action.reload && response.applied) {
                        await wait('document.getElementById("ps-config-editor").disabled', false);
                        assert.equal(await evaluate('document.getElementById("ps-config-editor").value'), draft, 'partial Template readback preserves the unsaved draft');
                        assert.equal(await evaluate('document.getElementById("ps-config-save").disabled'), false);
                    }
                    assert.deepEqual(frontendPosts.slice(before), [action.endpoint], 'partial/unknown Stubby results cannot replay a mutation');
                    await escape(action.modal);
                    await openStubbyAction(action);
                    assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.apply)}).disabled`), response.unknown === true);
                    if (response.unknown) {
                        const forged = await evaluate(`(() => {const count=window.fixtureXHR.filter(request=>request.method==='POST').length;document.getElementById(${JSON.stringify(action.apply)}).dispatchEvent(new MouseEvent('click',{bubbles:true}));return window.fixtureXHR.filter(request=>request.method==='POST').length-count;})()`);
                        assert.equal(forged, 0, 'unknown Stubby result requires verification before another operation');
                    }
                    stubbyReport.push({ action: action.name, outcome, detailsLength: details.length });
                    await escape(action.modal);
                }

                // The page owns completion of a sent operation; a later modal
                // opening owns its own text and controls until explicitly reopened.
                await loadStubby();
                const staleError = { success: false, error: 'Fixture earlier opening completed', details: '<script>complete earlier-opening diagnostics</script>' };
                const stale = queueFixtureReply(action.endpoint, staleError, { hold: true });
                const beforeStale = frontendPosts.length;
                await applyStubbyAction(action);
                await waitFixture(() => stale.request, action.name + ' held older opening');
                await escape(action.modal);
                await openStubbyAction(action);
                const newOpening = await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`);
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.apply)}).disabled`), true);
                stale.release();
                await wait('document.getElementById("ps-stubby-action-status").textContent.includes("earlier opening completed")', true);
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), newOpening, 'an old callback cannot replace the reopened modal presentation');
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.modal)}).style.display`), 'flex');
                const staleFrame = await evaluate(`(() => {const pre=document.querySelector('#ps-stubby-action-status pre');return {text:pre.textContent,children:pre.childElementCount};})()`);
                assert.equal(staleFrame.text, staleError.error + '\n\n' + staleError.details, 'the external page keeps the exact earlier-operation message plus verbatim complete diagnostics');
                assert.equal(staleFrame.children, 0, 'earlier-operation diagnostics remain literal text');
                await escape(action.modal);
                await openStubbyAction(action);
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.apply)}).disabled`), false, 'a fresh opening sees the released operation gate');
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), '');
                assert.deepEqual(frontendPosts.slice(beforeStale), [action.endpoint]);
                await escape(action.modal);

                await loadStubby();
                const beforeProcess = fixtureStatus('stubby');
                const ack = { success: true, applied: true, restarting: true, verification_required: true,
                    previous_running: true, previous_identity_known: true, previous_instance: beforeProcess.instance };
                const oldObservation = queueFixtureReply('/copyapi/stubby_service_status', beforeProcess, { hold: true });
                const applied = queueFixtureReply(action.endpoint, ack, { hold: true, effect() {
                    if (action.reload) fixtureStubbyConfig = "config stubby 'global'\n    option log_level '4'\n";
                } });
                const beforeRestartProof = frontendPosts.length;
                await applyStubbyAction(action);
                await waitFixture(() => applied.request, action.name + ' checked restart ACK');
                applied.release();
                await waitFixture(() => oldObservation.request, action.name + ' prior process observation');
                assert.match(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), /Verifying Stubby restart/);
                oldObservation.release();
                await new Promise(resolve => setTimeout(resolve, 100));
                assert.doesNotMatch(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), /new Stubby instance is running|Stubby restarted/, 'an old running process cannot confirm a restart');
                fixtureProcesses.stubby = { running: true, pid: '456', instance: '456:' + (++fixtureStartTime) };
                await wait('document.getElementById("ps-stubby-action-status").textContent.includes("A new Stubby instance is running.")', true, 5000);
                assert.notEqual(fixtureStatus('stubby').instance, beforeProcess.instance);
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.apply)}).disabled`), true);
                if (action.reload) await wait('document.getElementById("ps-config-editor").value', fixtureStubbyConfig);
                assert.deepEqual(frontendPosts.slice(beforeRestartProof), [action.endpoint], 'restart verification only performs factual GETs');
                await escape(action.modal);
                await openStubbyAction(action);
                assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), '');
                if (action.reload) {
                    await new Promise(resolve => setTimeout(resolve, 2300));
                    assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.modal)}).style.display`), 'flex', 'an earlier Template delayed-close timer cannot hide a new opening');
                    assert.equal(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), '');
                }
                stubbyReport.push({ action: action.name, outcome: 'old instance unconfirmed → new process confirmed; reopened presentation retained' });
                await escape(action.modal);

                await loadStubby();
                const noRestart = queueFixtureReply(action.endpoint, { success: true, applied: true }, { hold: true });
                await applyStubbyAction(action);
                await waitFixture(() => noRestart.request, action.name + ' response without restart evidence');
                noRestart.release();
                await wait(`document.getElementById(${JSON.stringify(action.status)}).textContent.includes('Restart is unconfirmed.')`, true);
                assert.doesNotMatch(await evaluate(`document.getElementById(${JSON.stringify(action.status)}).textContent`), /new Stubby instance is running|Stubby restarted/);
                await escape(action.modal);
            }

            await loadStubby();
            const beforeAlreadyFixed = fixtureStatus('stubby');
            const alreadyFixedCalls = fixtureCalls.length;
            const alreadyFixed = queueFixtureReply('/copyapi/stubby_init_fix', { success: true, message: 'Already fixed' }, { hold: true });
            await applyStubbyAction(stubbyActions[1]);
            await waitFixture(() => alreadyFixed.request, 'Already fixed no-op');
            alreadyFixed.release();
            await wait('document.getElementById("ps-initfix-apply-status").textContent.includes("Already fixed")', true);
            assert.match(await evaluate('document.getElementById("ps-initfix-apply-status").textContent'), /No restart was requested/);
            assert.deepEqual(fixtureStatus('stubby'), beforeAlreadyFixed);
            await new Promise(resolve => setTimeout(resolve, 2300));
            assert.ok(fixtureCalls.slice(alreadyFixedCalls).filter(call => call.endpoint === '/copyapi/stubby_service_status').length <= 1, 'Already fixed may refresh status, but does not start restart polling');
            await escape('ps-initfix-modal');
            fixtureStubbyConfig = initialStubbyConfig;
            fixtureProcesses.stubby = originalStubbyProcess;
            fs.writeFileSync(path.join(artifacts, 'stubby-autostart.json'), JSON.stringify({ autostart: autostartReport, stubby: stubbyReport }, null, 2));
            console.log('PASS native Stubby Template/Init Fix: complete literal diagnostics, applied/unknown facts, preserved draft, stale callback and delayed-close guards, old/new restart identity proof and Already fixed without invented restart');

            await cdp.call('Page.navigate', { url: base + '/copy-form?view=subscriptions' }, sessionId);
            await wait('document.readyState', 'complete');
            await wait('!!document.getElementById("ps-opt-save")', true);
            await wait('document.getElementById("ps-auto-status").textContent.includes("Expected cron entry found")', true);
            await evaluate('window.confirm=()=>true;document.getElementById("ps-log-display-count").value="15";document.getElementById("ps-log-settings-save").click()');
            await wait('document.getElementById("ps-log-settings-status").textContent', 'Saved');
            assert.equal(subscriptionSettings.auto_update_interval, 4);
            assert.equal(subscriptionSettings.auto_update_start, '01:30');
            assert.equal(subscriptionSettings.auto_update_on_restart, true);
            assert.deepEqual(Object.keys(subscriptionRequests.at(-1).fields).sort(), ['log_display_count', 'log_only', 'token']);
            subscriptionFailure = true;
            await evaluate('document.getElementById("ps-subs-update-all").click()');
            await wait('document.getElementById("ps-global-status").textContent.includes("HTTP error: 403")', true);
            assert.equal(await evaluate('document.getElementById("ps-subs-update-all").disabled'), false);
            brokenSchedule = true;
            await evaluate('document.getElementById("ps-subs-refresh").click()');
            await wait('document.getElementById("ps-auto-status").textContent.includes("Missing or different cron entry")', true);
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, sessionId);
            assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true);
            await screenshot('subscriptions-auto-status-mobile', 390);
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
            const text = "config section 'main'\n\toption user_domains_text '" + 'пример.рф\n'.repeat(14000) + "'\n";
            for (const name of ['config', 'stubby', 'singbox']) {
                await cdp.call('Page.navigate', { url: base + '/copy-form?view=' + name }, sessionId);
                await wait('document.getElementById("ps-config-editor")?.disabled', false);
                const content = name === 'singbox' ? JSON.stringify({ outbounds: [{ type: 'direct', tag: 'direct' }], route: { rules: [{ domain: Array.from({ length: 14000 }, (_, i) => 'домен' + i + '.рф'), outbound: 'direct' }] } }) : text;
                await evaluate(`document.getElementById('ps-config-editor').value=${JSON.stringify(content)};document.getElementById('ps-config-editor').dispatchEvent(new Event('input'));document.getElementById('ps-config-save').click()`);
                await wait('document.getElementById("ps-config-editor").disabled', false);
                assert.equal(contentRequests.at(-1).fields.content_file, content);
                assert.equal(contentRequests.at(-1).endpoint, name === 'config' ? 'save_config' : name === 'stubby' ? 'save_stubby_config' : 'save_singbox_config');
                assert.equal(await evaluate('document.getElementById("ps-config-save").disabled'), true);
            }
            for (const bundle of [true, false]) {
                await cdp.call('Page.navigate', { url: base + '/copy-form?view=import-export' }, sessionId);
                await wait('document.readyState', 'complete');
                const content = bundle ? JSON.stringify({ format: 'podkop-tweaker-bundle', version: 1, items: { podkop: { content: text }, stubby: { content: "config stubby 'global'" } } }) : text;
                await evaluate(`(() => {const transfer=new DataTransfer();transfer.items.add(new File([${JSON.stringify(content)}],'input.txt'));const input=document.getElementById('ps-import-file');input.files=transfer.files;input.dispatchEvent(new Event('change'));document.getElementById('ps-import-open').click();})()`);
                await wait('document.getElementById("ps-import-modal").style.display', 'flex');
                if (bundle) await evaluate('document.querySelector("#ps-import-review-list input[value=stubby]").checked=false');
                await evaluate('document.getElementById("ps-import-confirm").click()');
                await wait('document.getElementById("ps-import-close").style.display', '');
                assert.equal(contentRequests.at(-1).fields.content_file, content);
                assert.equal(contentRequests.at(-1).endpoint, bundle ? 'import_bundle' : 'import_config');
                if (bundle) assert.equal(contentRequests.at(-1).fields.items, 'podkop');
            }
            console.log('PASS real reliability forms: isolated log preference, HTTP failure recovery, actual scheduler facts/mobile, large UTF-8 editor saves and config/bundle imports');
            subscriptionSettings.log_display_count = 10;
            brokenSchedule = false;
        }
        if (!focused || copyOnly) {
            await cdp.call('Page.navigate', { url: base + '/cache-prime' }, sessionId);
            await wait('window.__ptOldAsset', true);
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
                assert.equal(await evaluate('window.__ptOldAsset === true'), false, 'ordinary tab URLs must not reuse the stale same-version JS cache');
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
                await escape('ps-error-modal');
                await evaluate(`document.getElementById('ps-config-diff').click()`);
                const expectedDiff = await evaluate('document.getElementById("ps-diff-body").innerText');
                assert.equal(await copy('[data-pt-copy-for="ps-diff-body"]'), expectedDiff);
                await escape('ps-diff-modal');
                assert.equal(await evaluate('document.getElementById("ps-config-editor").value'), text, 'Esc does not discard editor changes');
                assert.equal(await evaluate('document.getElementById("ps-config-save").disabled'), false);
                if (name === 'stubby') {
                    await evaluate('document.getElementById("ps-params-btn").click()');
                    const help = await evaluate('document.getElementById("ps-params-modal").innerText');
                    assert.ok(help.includes("log_level '3'"));
                    for (const level of ['0 Emergency', '1 Alert', '2 Critical', '3 Error', '4 Warning', '5 Notice', '6 Info', '7 Debug']) assert.ok(help.includes(level));
                    assert.ok(help.includes('Local DNSSEC off') && help.includes('dot.sb'));
                    assert.ok(help.includes('Available upstreams are used round-robin.'));
                    assert.ok(!help.includes('Podkop block sections') && !help.includes('getdns handles upstream failures'));
                    await screenshot('stubby-template-guidance', 1440);
                    await evaluate('document.getElementById("ps-initfix-btn").click()');
                    assert.equal(await copy('[data-pt-copy-for="ps-initfix-cmd"]'), await evaluate('document.getElementById("ps-initfix-cmd").textContent'));
                    await escape('ps-initfix-modal');
                    assert.equal(await evaluate('document.getElementById("ps-params-modal").style.display'), 'flex', 'Esc closes only the front overlay');
                    await escape('ps-params-modal');
                }
                if (name === 'singbox') {
                    await evaluate('document.getElementById("ps-patch-btn").click()');
                    await wait('document.getElementById("ps-patch-modal").style.display', 'flex');
                    await escape('ps-patch-modal');
                    await wait('document.getElementById("ps-wrapper-btn").textContent', 'Enable Wrapper');
                    await evaluate('document.getElementById("ps-wrapper-btn").click()');
                    await wait('document.getElementById("ps-wrapper-modal").style.display', 'flex');
                    await escape('ps-wrapper-modal');
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
            await escape('ps-full-log-modal');
            await evaluate('document.querySelector(".ps-sub-btn-attach").click();document.getElementById("ps-sub-url").focus()');
            await escape('ps-sub-modal');

            await cdp.call('Page.navigate', { url: base + '/copy-form?view=import-export' }, sessionId);
            await wait('document.readyState', 'complete');
            await evaluate('document.getElementById("ps-export-open").click()');
            await escape('ps-export-modal');
            await evaluate(`(() => {const transfer=new DataTransfer();transfer.items.add(new File(["config section 'main'\\n"],'input.txt'));const input=document.getElementById('ps-import-file');input.files=transfer.files;input.dispatchEvent(new Event('change'));document.getElementById('ps-import-open').click();})()`);
            await wait('document.getElementById("ps-import-modal").style.display', 'flex');
            const beforeCancel = contentRequests.length;
            await escape('ps-import-modal');
            await evaluate('document.getElementById("ps-import-confirm").click()');
            assert.equal(contentRequests.length, beforeCancel, 'Esc clears pending import without applying it');
            await evaluate('document.getElementById("ps-error-modal").style.display="flex"');
            await escape('ps-error-modal');
            console.log('PASS modal Esc: all editors/error/diff, Stubby template/init, sing-box patch/wrapper, subscriptions/history and import/export; top overlay, cleanup and dirty preservation');

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
        if (!focused || themeOnly) fs.writeFileSync(path.join(artifacts, 'computed-colors.json'), JSON.stringify(reports, null, 2));
        assert.equal(heldFixtureReplies.size, 0, 'all controlled HTTP replies must finish before fixture shutdown');
        for (const [endpoint, queue] of fixtureReplyQueues) assert.equal(queue.length, 0, endpoint + ': every planned fixture reply must be consumed');
        console.log(copyOnly ? 'Native clipboard checks: PASS' : updateOnly ? 'Native Local Update checks: PASS' : diagnosticsOnly ? 'Native Diagnostics checks: PASS (progressive local Run All, errors/deadlines/log export, separate external DNS and Podkop navigation)' : reliabilityOnly ? 'Native reliability checks: PASS (typed autostart, Stubby result/modal/restart proof, mobile, multipart and scheduling)' : `Native browser theme checks: PASS (${reports.length} scheme/profile scenarios + Argon 3 live modes${themeOnly ? '' : ' + real forms'}; artifacts in ${path.relative(root, artifacts)})`);
    } finally {
        for (const release of [...heldFixtureReplies]) release();
        if (cdp) { await cdp.call('Browser.close').catch(() => {}); cdp.close(); }
        child.kill();
        await browserClosed;
        await new Promise(resolve => server.close(resolve));
    }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
