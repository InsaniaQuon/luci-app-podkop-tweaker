// theme_browser_spec.js | v4.11.0 | 19.10.2026 | Compact Stubby toolbar, clear fix action and opt-in technical details with retained ST1 checks
// node tests/theme_browser_spec.js --browser <installed Chromium/Edge executable>
// Add --theme-only for schemes/live Argon modes, or a focused form flag below.
// --output-dir .test_tmp/<run> isolates generated files/profile from old runs.
// --argon-css <local cascade.css> uses real CSS in the Argon 3 mode fixtures.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { createHash } = require('node:crypto');
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
const browserSources = [
    'usr/lib/lua/luci/controller/podkop-tweaker.lua',
    'www/luci-static/resources/podkop-tweaker/common.js',
    'www/luci-static/resources/podkop-tweaker/common.css',
    ...['argon', 'config', 'diagnostics', 'import-export', 'singbox', 'stubby', 'subscriptions', 'update'].map(name => 'usr/lib/lua/luci/view/podkop-tweaker/' + name + '.htm')
];
const sourceHashes = () => Object.fromEntries(browserSources.map(file => [file, createHash('sha256').update(fs.readFileSync(path.join(repo, file))).digest('hex')]));
const initialSourceHashes = sourceHashes();

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
const browserRequestObserver = `window.fixtureXHR=[];window.fixtureXHRDone=[];(()=>{const open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(method,url){this.fixtureRequest={method,url:String(url)};return open.apply(this,arguments);};XMLHttpRequest.prototype.send=function(){window.fixtureXHR.push({...this.fixtureRequest,timeout:this.timeout});this.addEventListener('loadend',()=>window.fixtureXHRDone.push({...this.fixtureRequest,status:this.status}),{once:true});return send.apply(this,arguments);};})();`;
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

const copyLogLines = Array.from({ length: 15 }, (_, i) => [`12:${String(i).padStart(2, '0')} 09.10.2026|manual|updated=1|unchanged=0|failed=0`, `  main-${i}: updated`, `    detail ${i}: <script>plain text</script>`]).flat();
const journalIds = { requested: '1'.repeat(32), failed: '2'.repeat(32), unknown: '3'.repeat(32), changing: '4'.repeat(32), malformed: '5'.repeat(32) };
const journalCounters = {
    updated: '<b data-fixture-injected="updated">2</b>',
    unchanged: '<i data-fixture-injected="unchanged">3</i>',
    failed: '<img data-fixture-injected="failed" src=x onerror="window.fixtureJournalInjected=true">'
};
const journalMetadataHTML = '<svg data-fixture-injected="metadata" onload="window.fixtureJournalInjected=true">';
const malformedJournalHeader = '10:04 19.10.2026|manual|updated=' + journalCounters.updated + '|unchanged=' + journalCounters.unchanged + '|failed=' + journalCounters.failed +
    '|id=' + journalMetadataHTML + '|state=finished|service=' + journalMetadataHTML + '|skipped=' + journalMetadataHTML + '|outcome=ok';
const journalLastFinished = { ts: '10:01 19.10.2026', updated: 1, unchanged: 2, failed: 0, id: journalIds.requested, state: 'finished', service: 'requested', skipped: 0, outcome: 'ok' };
const journalPending = { ts: '10:05 19.10.2026', updated: 1, unchanged: 0, failed: 0, id: journalIds.changing, state: 'pending', service: 'pending', skipped: 0, outcome: 'pending' };
const journalFinished = { ...journalPending, unchanged: 3, state: 'finished', service: 'requested', skipped: 1, outcome: 'partial' };
function subscriptionJournalLines(finished = false, malformed = malformedJournalHeader) {
    // Six distinct operations make Full Log available with the real limit 5.
    // Separate reads supply one current block for the same changing operation
    // ID. These snapshots do not require client-side merging or suppression.
    return [
        '10:00 19.10.2026|auto|updated=0|unchanged=2|failed=0',
        '    journal-legacy: <span data-fixture-injected="detail">literal old history</span>',
        '10:01 19.10.2026|auto|updated=1|unchanged=2|failed=0|id=' + journalIds.requested + '|state=finished|service=requested|skipped=0|outcome=ok',
        '  journal-requested:',
        '    completed-node: updated',
        '  service:',
        '    podkop: requested',
        '10:02 19.10.2026|manual|updated=1|unchanged=0|failed=0|id=' + journalIds.failed + '|state=finished|service=failed|skipped=0|outcome=partial',
        '    journal-failed',
        '10:03 19.10.2026|auto|updated=1|unchanged=0|failed=0|id=' + journalIds.unknown + '|state=finished|service=unknown|skipped=0|outcome=partial',
        '    journal-unknown',
        malformed,
        '    journal-malformed',
        finished ? '10:05 19.10.2026|auto|updated=1|unchanged=3|failed=0|id=' + journalIds.changing + '|state=finished|service=requested|skipped=1|outcome=partial' :
            '10:05 19.10.2026|auto|updated=1|unchanged=0|failed=0|id=' + journalIds.changing + '|state=pending|service=pending|skipped=0|outcome=pending',
        '    journal-changing',
        '    node: updated',
        finished ? '    one skipped slot in the finished snapshot' : '    collection has not finished'
    ];
}
const fixtureTLSOutbounds = { outbound_count: 2, outbounds: [
    { tag: 'fixture-vless', type: 'vless', server: 'vless.fixture.test', tls_enabled: true, has_fragment: false },
    { tag: 'fixture-trojan', type: 'trojan', server: 'trojan.fixture.test', tls_enabled: true, has_fragment: true }
] };
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
function fixtureInitCheck(options = {}) {
    const process = options.process || fixtureStatus('stubby'), uid = options.uid ?? 0, user = options.user || 'stubby';
    const present = process.running === true, root = present && uid === 0, port = options.port || 53;
    return { check_version: 2, status: root ? 'fixed' : 'unknown', init: { state: 'literal', user },
        runtime: { state: present ? root ? 'root' : 'user' : 'stopped', process_count: present ? 1 : 0,
            processes: present ? [{ pid: process.pid, euid: uid, instance: process.instance }] : [] },
        listeners: { state: present ? 'observed' : 'none', count: present ? 2 : 0,
            entries: present ? ['tcp', 'udp'].map(protocol => ({ protocol, address: '127.0.0.53', port, pid: process.pid })) : [] },
        config: { state: 'uci', listen_count: 1, listen_addresses: ['127.0.0.53@' + port] },
        repair: { available: user === 'stubby', reason: user === 'stubby' ? 'Optional root-mode workaround; non-root operation is not itself an error' : 'Init already declares root' } };
}
function fixtureRestart(name) {
    const key = name === 'stubby' ? 'stubby' : 'singbox', before = fixtureStatus(key), pid = key === 'stubby' ? '456' : '123';
    fixtureProcesses[key] = { running: true, pid, instance: pid + ':' + (++fixtureStartTime) };
    return { success: true, restarting: true, verification_required: true, previous_running: before.running,
        previous_identity_known: true, ...(before.instance ? { previous_instance: before.instance } : {}) };
}
function fixtureAutoStatus(overrides = {}) {
    const expected = '30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update';
    return {
        cron: { enabled: true, matches: !brokenSchedule, running: !brokenSchedule, expected, actual: brokenSchedule ? [] : [expected] },
        launcher: { exists: true, matches: !brokenSchedule, executable: !brokenSchedule },
        hotplug: { enabled: true, exists: true, matches: !brokenSchedule, executable: !brokenSchedule },
        last_auto: { ts: '12:00 09.10.2026', updated: 0, unchanged: 2, failed: 1, legacy: true },
        ...overrides
    };
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
                    if ((fixtureReplyQueues.get(url.pathname) || []).length) { fixtureResponse(req, res, fields); return; }
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
            if (endpoint === 'stubby_init_check') { fixtureResponse(req, res, null, () => fixtureInitCheck()); return; }
            if (endpoint === 'wrapper_status') { fixtureResponse(req, res, null, { installed: fixtureWrapperInstalled, stale: false }); return; }
            if (endpoint === 'fragment_settings') {
                res.end(JSON.stringify(fragmentReadFailure ? { success: false, error: 'Cannot read current Fragment settings' } : { fragment: true, record_fragment: false, fallback_delay: '900ms', settings_source: 'uci', config_missing: false }));
                return;
            }
            if (endpoint === 'singbox_outbounds') {
                fixtureResponse(req, res, null, outboundReadFailure ? { error: 'jq enumeration failed', details: '<script>literal jq stderr</script>' } : { outbound_count: 0, outbounds: {} });
                return;
            }
            if (['service_status', 'singbox_service_status', 'stubby_service_status'].includes(endpoint)) {
                fixtureResponse(req, res, null, () => fixtureStatus(endpoint === 'stubby_service_status' ? 'stubby' : 'singbox')); return;
            }
            if (endpoint === 'read_update_log') { fixtureResponse(req, res, null, { lines: copyLogLines }); return; }
            if (endpoint === 'auto_update_status') { fixtureResponse(req, res, null, () => fixtureAutoStatus()); return; }
             const response = endpoint === 'subscription_state' ? { sections: [{ name: 'main', proxy_config_type: 'url', slots: [{ index: 0, proxy: { name: 'Example', server: 'example.test', protocol: 'VLESS', security: 'tls' } }] }] } : endpoint === 'settings_read' ? subscriptionSettings : { running: false, status: 'fixed' };
            if (endpoint === 'subscription_state') fixtureResponse(req, res, null, response);
            else res.end(JSON.stringify(response));
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
            close() { return new Promise(resolve => { if (ws.readyState === WebSocket.CLOSED) resolve(); else { ws.addEventListener('close', resolve, { once: true }); ws.close(); } }); }
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
    await new Promise(resolve => setTimeout(resolve, 2000));
    const preflightHashes = sourceHashes();
    fs.writeFileSync(path.join(artifacts, 'source-hashes.json'), JSON.stringify({ before: initialSourceHashes, preflight: preflightHashes }, null, 2));
    assert.deepEqual(preflightHashes, initialSourceHashes, 'BLOCKER: production sources changed during preflight; wait for the UI owner before the final browser run');
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const child = spawn(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--remote-debugging-port=0', `--user-data-dir=${path.join(artifacts, 'profile')}`], { stdio: ['ignore', 'ignore', 'pipe'] });
    const browserClosed = new Promise(resolve => child.once('close', resolve));
    let cdp, privateBrowserPids = [], runFailure = null;
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
        // Observe the production DOM/cascade, including closed disclosures. No
        // status renderer, transport callback, watcher or palette is replaced.
        const subscriptionDOM = `(() => {
            const root=getComputedStyle(document.documentElement),colors={};
            for(const [role,token] of Object.entries({success:'--ps-success',warning:'--ps-warning',error:'--ps-error',muted:'--ps-text-muted',dim:'--ps-text-dim',text:'--ps-text'})){
                const probe=document.createElement('span');probe.style.color=root.getPropertyValue(token);colors[role]=probe.style.color;
            }
            const withoutButtons=el=>{const copy=el.cloneNode(true);copy.querySelectorAll('button').forEach(button=>button.remove());return copy.textContent;};
            const read=el=>({
                text:el.innerText,raw:withoutButtons(el),color:getComputedStyle(el).color,
                details:[...el.querySelectorAll('details')].map(detail=>({open:detail.open,summary:withoutButtons(detail.querySelector('summary')),summaryColor:getComputedStyle(detail.querySelector('summary')).color,
                    body:[...detail.querySelectorAll('pre,.ps-error-details')].map(body=>body.textContent).join('\\n'),literal:[...detail.querySelectorAll('pre,.ps-error-details')].every(body=>body.childElementCount===0)})),
                leaves:[...el.querySelectorAll('*')].filter(node=>node.childElementCount===0&&!node.closest('button,svg,pre,details:not([open])')).map(node=>({text:node.textContent,color:getComputedStyle(node).color}))
            });
            const events=id=>[...document.querySelectorAll('#'+id+' .ps-log-event')].map(el=>({...read(el),
                summary:el.querySelector('.ps-log-summary').textContent,
                stats:el.querySelector('.ps-log-stats').textContent,statsChildren:el.querySelector('.ps-log-stats').childElementCount,
                lines:[...el.querySelectorAll('.ps-log-detail-line')].filter(line=>!line.closest('details')).map(line=>line.textContent),
                updatedLines:[...el.querySelectorAll('.ps-log-detail-line')].filter(line=>line.textContent.endsWith(': updated')).map(line=>({text:line.textContent,color:getComputedStyle(line).color})),
                literal:[...el.querySelectorAll('.ps-log-detail-line')].filter(line=>!line.closest('details')).every(line=>line.childElementCount===0)
            }));
            const autoStatus=()=>{const el=document.getElementById('ps-auto-status'),css=getComputedStyle(el);return {...read(el),
                visible:css.display!=='none'&&css.visibility!=='hidden'&&el.getClientRects().length>0,
                headings:[...el.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(node=>node.textContent),tables:el.querySelectorAll('table').length,
                notes:[...el.querySelectorAll('.ps-auto-status-note')].map(node=>node.textContent),
                items:[...el.children].map(node=>({...read(node),tag:node.tagName}))};};
            return {read,events,colors,autoStatus};
        })()`;
        const autoReplyCountExpression = `window.fixtureXHRDone.filter(request=>new URL(request.url,location.href).pathname==='/copyapi/auto_update_status').length`;
        const autoReplyCount = () => evaluate(autoReplyCountExpression);
        const waitAutoReplies = count => wait(autoReplyCountExpression, count);
        const autoStatusSnapshot = async () => evaluate(`(() => {const dom=${subscriptionDOM};return {...dom.autoStatus(),colors:dom.colors,injected:!!document.querySelector('[data-fixture-injected]')};})()`);
        const assertHiddenAutoStatus = widget => {
            assert.equal(widget.visible, false, 'healthy/disabled setup has no visible status widget');
            assert.equal(widget.raw.trim(), '', 'healthy recovery clears old problem text, complete Details and completed-result duplicates');
            assert.equal(widget.details.length, 0);
            assert.equal(widget.items.length, 0);
            assert.deepEqual(widget.headings, []);
            assert.deepEqual(widget.notes, [], 'healthy setup has no normal status footnote');
            assert.equal(widget.tables, 0, 'Actual Status has no normal facts table');
        };
        const assertNeutralPending = widget => {
            assert.equal(widget.visible, true);
            assert.equal(widget.items.length, 1, 'one newer pending observation produces one concise notification');
            assert.equal(widget.details.length, 0, 'valid pending metadata is not a diagnostic problem');
            assert.match(widget.text, /pending|not recorded/i);
            assert.ok(widget.text.trim().length <= 220, 'the pending notification is concise');
            assert.doesNotMatch(widget.text, /\b(?:is|currently|still) (?:active|running|working)|\bin progress\b|\brunning now\b|restart confirmed/i, 'a pending journal record makes no active-work/readiness claim');
            assert.doesNotMatch(widget.raw, /[a-f0-9]{32}|updated=|unchanged=|failed=|Expected entry|Last (?:finished|automatic result)/i);
            const neutral = [widget.colors.muted, widget.colors.dim, widget.colors.text];
            assert.ok(neutral.includes(widget.items[0].color), 'the native pending notification has an actual neutral computed color');
            assert.ok(widget.items[0].leaves.every(leaf=>neutral.includes(leaf.color)), 'pending text cannot inherit warning/error/success coloring');
            assert.ok(widget.notes.every(text=>/pending|not recorded/i.test(text)), 'ps-auto-status-note is allowed for the conditional neutral pending message, not a normal status footnote');
            assert.deepEqual(widget.headings, []); assert.equal(widget.tables, 0);
        };
        const journalSnapshot = async () => evaluate(`(() => {
            const dom=${subscriptionDOM};
            return {recent:dom.events('ps-log-wrap'),full:dom.events('ps-full-log-body'),colors:dom.colors,
                auto:{...dom.autoStatus(),colors:dom.colors},
                injected:!!document.querySelector('[data-fixture-injected]')||window.fixtureJournalInjected===true};
        })()`);
        const noticeSnapshot = async id => evaluate(`(() => {const dom=${subscriptionDOM};return {...dom.read(document.getElementById(${JSON.stringify(id)})),colors:dom.colors};})()`);
        const journalEvent = (events, name) => {
            const matches = events.filter(event => event.lines.some(line => line.trim() === 'journal-' + name || line.trim().startsWith('journal-' + name + ':')));
            assert.equal(matches.length, 1, name + ': exactly one displayed operation, including after a pending → finished refresh');
            return matches[0];
        };
        const assertCompactNormal = event => {
            assert.equal(event.details.length, 0, 'normal results need no diagnostic disclosure or hidden JSON wall');
            assert.doesNotMatch(event.raw, /[a-f0-9]{32}|\bOperation:|\bOutcome:\s*OK|handler ended|handler\/service outcome unknown|restart.*(?:unconfirmed|readiness)|podkop: requested|skipped\s*=\s*0|\b0 skipped\b/i, 'routine history keeps the timestamp/mode/counters/section/proxy mask');
            assert.doesNotMatch(event.text, /(?:^|\n)\s*Finished(?:\s|—|:|$)/i, 'normal history has no synthetic Finished label; literal proxy/section text remains intact');
        };
        const assertProblemDetails = (event, facts) => {
            assert.equal(event.details.length, 1, 'one compact disclosure holds complete problem diagnostics');
            const detail = event.details[0];
            assert.equal(detail.open, false, 'problem Details are collapsed initially');
            assert.match(detail.summary, /details/i);
            assert.equal(detail.literal, true, 'diagnostic metadata stays plaintext');
            for (const fact of facts) {
                assert.ok(detail.body.includes(fact), 'expanded Details retain ' + fact);
                if (/^[a-f0-9]{32}$/.test(fact) || fact.includes('|')) assert.equal(event.text.includes(fact), false, 'closed Details do not expose internal metadata in the visible source');
            }
            return detail;
        };
        const assertUnknownJournal = (event, header) => {
            assert.match(event.text, /unknown|invalid|incomplete/i, 'malformed metadata cannot establish a lifecycle result');
            assertProblemDetails(event, [header]);
            assert.equal(event.lines.some(line => /^(?:Finished|Pending|Service:|Outcome: OK)/.test(line)), false, 'invalid metadata supplies no inferred service or success verdict');
        };
        const assertJournalSnapshot = (snapshot, finished, full = true) => {
            assert.equal(snapshot.injected, false, 'HTML-shaped journal fields never create elements or execute handlers');
            assert.ok(snapshot.colors.success && snapshot.colors.warning && snapshot.colors.error, 'native browser resolves distinct live palette tokens');
            assert.equal(snapshot.recent.length, 5, 'the real limit 5 applies to operations');
            if (full) assert.equal(snapshot.full.length, 6, 'Full Log retains all six operations');
            for (const events of [snapshot.recent, ...(full ? [snapshot.full] : [])]) {
                for (const event of events) {
                    assert.equal(event.literal, true, 'lifecycle/header/details are text-only sinks');
                    assert.equal(event.statsChildren, 0, 'slot counters stay literal text');
                }
                const requested = journalEvent(events, 'requested'), failed = journalEvent(events, 'failed'), unknown = journalEvent(events, 'unknown');
                assertCompactNormal(requested);
                assert.ok(requested.summary.includes(journalLastFinished.ts));
                assert.match(requested.summary, /auto.*updated=1.*unchanged=2.*failed=0/);
                assert.ok(requested.lines.includes('  journal-requested:'));
                for (const [event, service, id, role] of [[failed, /restart failed/i, journalIds.failed, 'error'], [unknown, /unknown/i, journalIds.unknown, 'warning']]) {
                    assert.ok(event.stats.includes('failed=0'), 'service failures remain visible even with no failed slots');
                    assert.match(event.text, service, 'the service problem stays visible outside collapsed Details');
                    assertProblemDetails(event, [id, 'partial']);
                    assert.ok(event.leaves.some(leaf => service.test(leaf.text) && leaf.color === snapshot.colors[role]), 'service verdict has the computed ' + role + ' color even at failed=0');
                }
                const malformed = journalEvent(events, 'malformed');
                for (const [key, value] of Object.entries(journalCounters)) assert.ok(malformed.stats.includes(key + '=' + value), 'HTML-shaped ' + key + ' count is displayed verbatim');
                assertUnknownJournal(malformed, malformedJournalHeader);
                const changing = journalEvent(events, 'changing');
                assert.match(changing.text, finished ? /partial|skipped/i : /pending|not recorded/i);
                assert.doesNotMatch(changing.text, /[a-f0-9]{32}|(?:^|\n)\s*Finished\b|\bOutcome:\s*OK|skipped=0/i);
                if (finished) assertProblemDetails(changing, [journalIds.changing, 'partial']);
                else {
                    assert.equal(changing.details.length, 0, 'a pending observation is neutral history, not an error disclosure');
                    const pendingLabels = changing.leaves.filter(leaf => /pending/i.test(leaf.text));
                    assert.ok(pendingLabels.length > 0);
                    assert.ok(pendingLabels.every(leaf => [snapshot.colors.muted, snapshot.colors.dim, snapshot.colors.text].includes(leaf.color)), 'pending lifecycle labels are genuinely neutral in the native cascade');
                }
                assert.ok(changing.lines.includes('    node: updated'), 'the literal updated detail is retained while pending and after the finished snapshot arrives');
                const updated = changing.updatedLines.filter(line => line.text === '    node: updated');
                assert.equal(updated.length, 1, 'the actual updated detail has one rendered text source in this server block');
                const completed = requested.updatedLines.find(line => line.text === '    completed-node: updated');
                assert.ok(completed, 'a finished updated detail provides a real production-rendered color control');
                assert.equal(completed.color, snapshot.colors.success, 'the finished control actually renders the active success color');
                if (!finished) assert.ok([snapshot.colors.muted, snapshot.colors.dim, snapshot.colors.text].includes(updated[0].color), 'a real updated=1 pending block retains node: updated as neutral, not a completion verdict');
            }
            assert.equal(snapshot.recent.some(event => event.lines.some(line => line.startsWith('    journal-legacy:'))), false, 'recent history excludes only the oldest operation');
            if (full) {
                const legacy = journalEvent(snapshot.full, 'legacy');
                assertCompactNormal(legacy);
                assert.ok(legacy.lines.includes('    journal-legacy: <span data-fixture-injected="detail">literal old history</span>'));
            }
        };
        const exerciseSubscriptionJournal = async ({ copyDisplayed = null, schedulerChecks = false } = {}) => {
            const oldCount = subscriptionSettings.log_display_count, oldBroken = brokenSchedule;
            const postsBefore = frontendPosts.length, requestsBefore = subscriptionRequests.length;
            const processesBefore = JSON.parse(JSON.stringify(fixtureProcesses));
            const report = {};
            subscriptionSettings.log_display_count = 5;
            brokenSchedule = false;
            const autoPending = fixtureAutoStatus({ last_auto: journalLastFinished, last_auto_pending: journalPending });
            const autoFinished = fixtureAutoStatus({ last_auto: journalFinished });
            const initialLog = queueFixtureReply('/copyapi/read_update_log', { lines: subscriptionJournalLines() }, { hold: true });
            const initialAuto = queueFixtureReply('/copyapi/auto_update_status', autoPending, { hold: true });
            const copyJournal = async id => {
                const before = await evaluate(`(() => {
                    const source=document.getElementById(${JSON.stringify(id)}),input=document.getElementById('ps-opt-start');
                    const active=${id === 'ps-full-log-body' ? "document.getElementById('ps-full-log-close')" : 'input'};
                    active.focus({preventScroll:true});
                    const selection=getSelection();
                    if(active===input)input.setSelectionRange(1,4,'backward');
                    else {const text=source.querySelector('.ps-log-stats').firstChild,range=document.createRange();range.setStart(text,1);range.setEnd(text,8);selection.removeAllRanges();selection.addRange(range);}
                    source.scrollTop=23;
                    return {text:source.innerText,focus:document.activeElement.id,value:input.value,start:input.selectionStart,end:input.selectionEnd,direction:input.selectionDirection,
                        range:selection.toString(),anchor:selection.anchorOffset,extent:selection.focusOffset,scroll:source.scrollTop,x:scrollX,y:scrollY};
                })()`);
                const copied = await copyDisplayed('[data-pt-copy-for="' + id + '"]');
                assert.equal(copied, before.text, 'Copy reads the exact currently displayed normal/expanded journal source');
                const after = await evaluate(`(() => {const source=document.getElementById(${JSON.stringify(id)}),input=document.getElementById('ps-opt-start'),selection=getSelection();return {
                    text:source.innerText,focus:document.activeElement.id,value:input.value,start:input.selectionStart,end:input.selectionEnd,direction:input.selectionDirection,
                    range:selection.toString(),anchor:selection.anchorOffset,extent:selection.focusOffset,scroll:source.scrollTop,x:scrollX,y:scrollY};})()`);
                assert.deepEqual(after, before, 'journal Copy preserves the source, focus, input/DOM selection and scroll');
                assert.equal(await evaluate('document.querySelectorAll(".ps-copy-fallback").length'), 0, 'the intercepted HTTP copy leaves no temporary textarea');
                return copied;
            };
            const expandProblems = async (id, finished) => {
                for (const [name, facts] of [['failed', [journalIds.failed, 'failed', 'partial']], ['unknown', [journalIds.unknown, 'unknown', 'partial']], ['malformed', [malformedJournalHeader]], ...(finished ? [['changing', [journalIds.changing, 'partial']]] : [])]) {
                    const target = `Array.from(document.querySelectorAll('#${id} .ps-log-event')).find(el=>el.textContent.includes(${JSON.stringify('journal-' + name)}))`;
                    await evaluate(`(${target}).querySelector('details summary').click()`);
                    await wait(`(${target}).querySelector('details').open`, true);
                    const snapshot = await journalSnapshot(), event = journalEvent(id === 'ps-full-log-body' ? snapshot.full : snapshot.recent, name);
                    for (const fact of facts) assert.ok(event.text.includes(fact), name + ': expanding Details exposes complete problem metadata');
                    assert.equal(event.details[0].literal, true);
                    if (copyDisplayed) {
                        const copied = await copyJournal(id);
                        for (const fact of facts) assert.ok(copied.includes(fact), 'expanded problem metadata is present in the copied displayed source');
                    }
                    await evaluate(`(${target}).querySelector('details summary').click()`);
                    await wait(`(${target}).querySelector('details').open`, false);
                }
            };
            try {
                await navigateFixture(base + '/copy-form?view=subscriptions');
                await wait('document.getElementById("ps-log-display-count")?.value', '5');
                await wait('!!document.getElementById("ps-opt-save")', true);
                await waitFixture(() => initialLog.request && initialAuto.request, 'initial mixed subscription journal/status reads');
                assertHiddenAutoStatus(await autoStatusSnapshot());
                initialLog.release(); initialAuto.release();
                await wait('document.querySelectorAll("#ps-log-wrap .ps-log-event").length', 5);
                await waitAutoReplies(1);
                assert.deepEqual(await evaluate('[...document.getElementById("ps-log-display-count").options].map(option=>option.value)'), ['5', '10', '15', '20', '25'], 'native fixtures use actual supported log limits');
                assertJournalSnapshot(await journalSnapshot(), false, false);
                if (copyDisplayed) await copyJournal('ps-log-wrap');
                await expandProblems('ps-log-wrap', false);
                const callsBeforeFull = fixtureCalls.length;
                await evaluate('document.getElementById("ps-full-log-btn").click()');
                await wait('document.getElementById("ps-full-log-modal").style.display', 'flex');
                report.pending = await journalSnapshot();
                assertJournalSnapshot(report.pending, false);
                assertNeutralPending(report.pending.auto);
                assert.equal(report.pending.auto.raw.includes(journalLastFinished.ts), false, 'the completed automatic result remains in the journal, not the setup widget');
                assertCompactNormal(journalEvent(report.pending.full, 'requested'));
                assert.equal(fixtureCalls.length, callsBeforeFull, 'opening Full Log uses the already-loaded snapshot');
                if (copyDisplayed) await copyJournal('ps-full-log-body');
                await expandProblems('ps-full-log-body', false);

                const refresh = async (lines, automatic, fixtureGeneration = null) => {
                    // Unique local fixture cache keys allow genuinely concurrent
                    // XHR bodies: Chromium serializes identical unfinished URLs.
                    // Only bootstrap URLs change; production runners and their
                    // generation guards receive actual native HTTP completions.
                    if (fixtureGeneration) await evaluate(`PT.urls.read_log='/copyapi/read_update_log?fixture_generation='+${JSON.stringify(fixtureGeneration)};PT.urls.auto_status='/copyapi/auto_update_status?fixture_generation='+${JSON.stringify(fixtureGeneration)}`);
                    const before = await journalSnapshot(), xhrCount = await evaluate('window.fixtureXHR.length'), autoDone = await autoReplyCount();
                    const log = queueFixtureReply('/copyapi/read_update_log', { lines }, { hold: true });
                    const auto = queueFixtureReply('/copyapi/auto_update_status', automatic, { hold: true });
                    await evaluate('document.getElementById("ps-subs-refresh").click()');
                    await waitFixture(() => log.request && auto.request, 'Refresh Sections re-reads journal and scheduler facts');
                    assert.deepEqual(await journalSnapshot(), before, 'pending read-only refreshes retain the current recent/full/scheduler snapshot');
                    const requests = await evaluate(`window.fixtureXHR.slice(${xhrCount}).map(request=>[request.method,new URL(request.url,location.href).pathname]).sort((a,b)=>a[1].localeCompare(b[1]))`);
                    assert.deepEqual(requests, ['auto_update_status', 'read_update_log', 'subscription_state'].map(endpoint => ['GET', '/copyapi/' + endpoint]), 'Refresh Sections requests only fresh read-only facts, with no service-status polling');
                    return { log, auto, autoDone };
                };
                const completion = await refresh(subscriptionJournalLines(true), autoFinished);
                completion.log.release();
                await wait('document.getElementById("ps-full-log-body").textContent.includes("one skipped slot in the finished snapshot")', true);
                assert.equal(await evaluate('document.getElementById("ps-full-log-modal").style.display'), 'flex', 'refresh also updates an already-open Full Log');
                assertJournalSnapshot(await journalSnapshot(), true);
                completion.auto.release();
                await waitAutoReplies(completion.autoDone + 1);
                report.finished = await journalSnapshot();
                assertHiddenAutoStatus(report.finished.auto);
                assertProblemDetails(journalEvent(report.finished.full, 'changing'), [journalIds.changing, 'outcome=partial', 'skipped=1']);
                if (copyDisplayed) await copyJournal('ps-full-log-body');
                await expandProblems('ps-full-log-body', true);

                const duplicateLines = subscriptionJournalLines(true).concat([
                    '10:06 19.10.2026|manual|updated=1|unchanged=0|failed=0|id=' + journalIds.changing + '|state=finished|service=requested|skipped=0|outcome=ok',
                    '    journal-duplicate-finished', '    duplicate-node: updated',
                    '10:07 19.10.2026|auto|updated=1|unchanged=0|failed=0|id=' + journalIds.changing + '|state=pending|service=pending|skipped=0|outcome=pending',
                    '    journal-duplicate-pending', '    duplicate-pending-node: updated'
                ]);
                const duplicates = await refresh(duplicateLines, autoFinished);
                duplicates.log.release(); duplicates.auto.release();
                await wait('document.querySelectorAll("#ps-full-log-body .ps-log-event").length', 8);
                await waitAutoReplies(duplicates.autoDone + 1);
                report.duplicates = await journalSnapshot();
                assert.equal(report.duplicates.recent.length, 5);
                for (const events of [report.duplicates.recent, report.duplicates.full]) {
                    for (const name of ['changing', 'duplicate-finished', 'duplicate-pending']) journalEvent(events, name);
                    assertCompactNormal(journalEvent(events, 'duplicate-finished'));
                    const pending = journalEvent(events, 'duplicate-pending');
                    assert.match(pending.text, /pending/i);
                    assert.ok([report.duplicates.colors.muted, report.duplicates.colors.dim, report.duplicates.colors.text].includes(pending.updatedLines[0].color));
                }
                assert.ok(report.duplicates.full[0].text.includes('journal-duplicate-pending'), 'server block order, not ID suppression, determines display order');
                if (copyDisplayed) await copyJournal('ps-full-log-body');
                const restoreDuplicates = await refresh(subscriptionJournalLines(true), autoFinished);
                restoreDuplicates.log.release(); restoreDuplicates.auto.release();
                await wait('document.querySelectorAll("#ps-full-log-body .ps-log-event").length', 6);
                await waitAutoReplies(restoreDuplicates.autoDone + 1);

                if (schedulerChecks) {
                    report.scheduler = [];
                    const legacy = { ts: '11:00 19.10.2026', updated: 0, unchanged: 2, failed: 0, legacy: true };
                    const cases = [
                        { name: 'legacy', record: legacy },
                        { name: 'failed with zero failed slots', record: { ...journalLastFinished, ts: '11:01 19.10.2026', service: 'failed', outcome: 'partial' } },
                        { name: 'unknown with zero failed slots', record: { ...journalLastFinished, ts: '11:02 19.10.2026', service: 'unknown', outcome: 'partial' } },
                        { name: 'unmarked old fields', record: { ts: '11:03 19.10.2026', updated: 0, unchanged: 2, failed: 0 } },
                        { name: 'malformed HTML metadata/counters', record: { ...journalLastFinished, ts: '11:04 19.10.2026', updated: journalCounters.updated, service: journalMetadataHTML } },
                        { name: 'pending cannot be last finished', record: { ...journalPending, ts: '11:05 19.10.2026' } }
                    ];
                    for (const test of cases) {
                        const next = await refresh(subscriptionJournalLines(true), fixtureAutoStatus({ last_auto: test.record }));
                        next.log.release(); next.auto.release();
                        await waitAutoReplies(next.autoDone + 1);
                        await wait(`document.getElementById('ps-full-log-body').textContent.includes(${JSON.stringify(malformedJournalHeader)})`, true);
                        const snapshot = await journalSnapshot();
                        assertHiddenAutoStatus(snapshot.auto);
                        assertJournalSnapshot(snapshot, true);
                        assert.equal(snapshot.injected, false);
                        report.scheduler.push({ name: test.name, suppliedLastAuto: test.record, auto: snapshot.auto });
                    }
                    const mistyped = await refresh(subscriptionJournalLines(true), fixtureAutoStatus({
                        cron: { enabled: 'true', matches: 1, running: 'false' }, launcher: { matches: true, executable: 'yes' }, hotplug: { enabled: 'false' }
                    }));
                    mistyped.log.release(); mistyped.auto.release();
                    await waitAutoReplies(mistyped.autoDone + 1);
                    const typedProblems = await autoStatusSnapshot();
                    assert.equal(typedProblems.visible, true);
                    assert.match(typedProblems.text, /Schedule:.*cannot confirm/i, 'an untyped cron mode is uncertainty, never disabled');
                    assert.match(typedProblems.text, /WAN.*cannot confirm/i, 'an untyped WAN mode is uncertainty, never disabled');
                    assert.doesNotMatch(typedProblems.text, /expected.*found|not required|disabled; no/i);
                    for (const item of typedProblems.items) {
                        assert.equal(item.color, typedProblems.colors.warning);
                        const detail = assertProblemDetails(item, []);
                        assert.equal(detail.summaryColor, typedProblems.colors.warning);
                    }
                    for (const fact of ['"enabled": "true"', '"matches": 1', '"running": "false"', '"executable": "yes"', '"enabled": "false"']) assert.ok(typedProblems.details.some(detail=>detail.body.includes(fact)), 'complete raw untyped setup facts remain in Details: ' + fact);
                    report.mistypedSetup = typedProblems;
                    for (const suffix of [
                        '|id=' + journalIds.malformed + '|state=finished|service=requested|skipped=0',
                        '|id=' + 'A'.repeat(32) + '|state=finished|service=requested|skipped=0|outcome=ok',
                        '|id=' + journalIds.malformed + '|state=finished|service=' + journalMetadataHTML + '|skipped=0|outcome=ok'
                    ]) {
                        const header = '10:04 19.10.2026|manual|updated=0|unchanged=0|failed=0' + suffix;
                        const next = await refresh(subscriptionJournalLines(true, header), autoFinished);
                        next.log.release(); next.auto.release();
                        await waitAutoReplies(next.autoDone + 1);
                        await wait(`document.getElementById('ps-full-log-body').textContent.includes(${JSON.stringify(header)})`, true);
                        const snapshot = await journalSnapshot();
                        assertUnknownJournal(journalEvent(snapshot.recent, 'malformed'), header);
                        assertUnknownJournal(journalEvent(snapshot.full, 'malformed'), header);
                        assert.equal(snapshot.injected, false);
                    }
                    const restored = await refresh(subscriptionJournalLines(true), autoFinished);
                    restored.log.release(); restored.auto.release();
                    await waitAutoReplies(restored.autoDone + 1);
                    await wait(`document.getElementById('ps-full-log-body').textContent.includes(${JSON.stringify(malformedJournalHeader)})`, true);
                }

                // A later authoritative refresh owns both open Full Log and the
                // setup feedback even when an earlier read completes last.
                const stale = await refresh(copyLogLines, fixtureAutoStatus({ cron: { enabled: true, matches: false, running: false, expected: 'earlier stale setup' }, last_auto: { ...journalLastFinished, ts: '09:00 19.10.2026' }, last_auto_pending: journalPending }), 'earlier');
                const current = await refresh(subscriptionJournalLines(true).concat(['    latest snapshot ownership']), autoFinished, 'current');
                current.log.release(); current.auto.release();
                await wait('document.getElementById("ps-full-log-body").textContent.includes("latest snapshot ownership")', true);
                await waitAutoReplies(current.autoDone + 1);
                const currentSnapshot = await journalSnapshot();
                assertHiddenAutoStatus(currentSnapshot.auto);
                stale.log.release(); stale.auto.release();
                await waitAutoReplies(current.autoDone + 2);
                assert.deepEqual(await journalSnapshot(), currentSnapshot, 'late earlier log/status responses cannot overwrite current/open Full Log snapshots');

                // IO errors retain a visibly qualified last-good snapshot in both
                // panels, rather than presenting a newly read empty journal.
                const beforeError = await journalSnapshot();
                const ioError = { error: 'Fixture journal close failed <literal>', details: '<img data-fixture-injected="io" src=x onerror="window.fixtureJournalInjected=true">\n' + 'complete journal IO diagnostics\n'.repeat(80) + 'last IO detail' };
                const failedRead = queueFixtureReply('/copyapi/read_update_log', ioError, { hold: true });
                const autoDoneBeforeError = await autoReplyCount();
                queueFixtureReply('/copyapi/auto_update_status', schedulerChecks ? fixtureAutoStatus({ cron: { ...fixtureAutoStatus().cron, error: 'Permission denied: mobile setup read <literal>\n' + 'complete mobile IO context '.repeat(40) }, last_auto: journalFinished }) : autoFinished);
                await evaluate('document.getElementById("ps-subs-refresh").click()');
                await waitFixture(() => failedRead.request, 'explicit journal IO failure'); failedRead.release();
                await wait('document.getElementById("ps-log-error").textContent.includes("Fixture journal close failed")', true);
                await waitAutoReplies(autoDoneBeforeError + 1);
                for (const id of ['ps-log-error', 'ps-full-log-error']) {
                    const error = await evaluate(`(() => {const el=document.getElementById(${JSON.stringify(id)}),pre=el.querySelector('pre');return {text:el.textContent,details:pre&&pre.textContent,literal:pre&&pre.childElementCount===0};})()`);
                    assert.ok(error.text.includes(ioError.error));
                    assert.match(error.text, /last successfully loaded snapshot/i);
                    assert.equal(error.details, ioError.details); assert.equal(error.literal, true);
                }
                const afterError = await journalSnapshot();
                assert.deepEqual(afterError.recent, beforeError.recent); assert.deepEqual(afterError.full, beforeError.full);
                assert.equal(afterError.injected, false);
                if (copyDisplayed) {
                    await copyJournal('ps-full-log-body');
                    assert.equal(await copyDisplayed('#ps-full-log-error .ps-copy-btn'), ioError.details, 'full IO diagnostics copy literally without writing the OS clipboard');
                }
                await escape('ps-full-log-modal');
                if (copyDisplayed) await copyJournal('ps-log-wrap');
                if (schedulerChecks) {
                    await cdp.call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, sessionId);
                    const mobile = await evaluate(`(() => {const el=document.getElementById('ps-auto-status'),r=el.getBoundingClientRect();return {overflow:document.documentElement.scrollWidth>innerWidth,left:r.left,right:r.right,viewport:innerWidth,issues:[...el.children].map(issue=>({text:issue.innerText,left:issue.getBoundingClientRect().left,right:issue.getBoundingClientRect().right})) };})()`);
                    assert.equal(mobile.overflow, false, 'actual scheduler facts and collapsed problem Details fit a 390px viewport');
                    assert.ok(mobile.left >= 0 && mobile.right <= mobile.viewport);
                    assert.ok(mobile.issues.length > 0);
                    for (const issue of mobile.issues) assert.ok(issue.left >= mobile.left && issue.right <= mobile.right + 1, 'compact setup problems stay inside their own panel');
                    assert.ok(mobile.issues.some(issue=>/cannot|error/i.test(issue.text)));
                    await screenshot('subscriptions-journal-mobile', 390);
                    report.mobile = mobile;
                    await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
                }
                const xhr = await evaluate('window.fixtureXHR');
                assert.equal(xhr.every(request => request.method === 'GET'), true, 'journal loading/pending/refresh/error recovery sends no mutation');
                assert.equal(xhr.some(request => /service_status/.test(request.url)), false, 'journal facts are not restart-polling evidence');
                assert.equal(frontendPosts.length, postsBefore);
                assert.equal(subscriptionRequests.length, requestsBefore);
                assert.deepEqual(fixtureProcesses, processesBefore);
                report.requests = xhr;
                return report;
            } catch (error) {
                fs.writeFileSync(path.join(artifacts, 'subscription-journal-failure.json'), JSON.stringify({ error: error.stack, report, snapshot: await journalSnapshot(), xhr: await evaluate('window.fixtureXHR') }, null, 2));
                throw error;
            } finally {
                subscriptionSettings.log_display_count = oldCount;
                brokenSchedule = oldBroken;
            }
        };
        const exerciseSubscriptionMutations = async ({ copyDisplayed = null } = {}) => {
            const beforeProcesses = JSON.parse(JSON.stringify(fixtureProcesses)), beforeSettings = { ...subscriptionSettings }, beforeBroken = brokenSchedule;
            const report = [];
            const proxy = { name: 'Native fixture proxy <literal>', link: 'vless://fixture@node.fixture.test:443?security=tls#Native', server: 'node.fixture.test', protocol: 'VLESS', security: 'tls' };
            const actions = [{ name: 'Update All', endpoint: '/copyapi/update_all_subs', ids: ['ps-global-status'] },
                { name: 'Attach', endpoint: '/copyapi/subscription_attach', ids: ['ps-slot-status-main-0', 'ps-global-status'], modal: true },
                { name: 'Slot Update', endpoint: '/copyapi/subscription_attach', ids: ['ps-slot-status-main-0'], direct: true }];
            const sectionState = action => ({ sections: [{ name: 'main', proxy_config_type: 'url', slots: [{ index: 0, proxy,
                ...(action.direct ? { subscription: { subscription_url: 'https://subscription.fixture.test/list', proxy_name: proxy.name } } : {}) }] }] });
            let operationNumber = 16;
            const responseFor = (action, kind) => {
                const previous = fixtureStatus('singbox');
                const restart = { success: true, restarting: true, command_result_known: true, command_exit_code: 0,
                    verification_required: true, previous_running: previous.running, previous_identity_known: true, previous_instance: previous.instance };
                const response = { success: true, applied: true, updated: 1, unchanged: action.name === 'Update All' ? 0 : false, failed: 0, skipped: 0,
                    operation_id: (++operationNumber).toString(16).padStart(32, '0'), service: 'requested', outcome: 'ok', restarted: true, restart,
                    journal: { recorded: true, finalized: true }, outcomes: [{ section: 'main', slot: 0, status: 'updated', proxy_name: proxy.name }] };
                if (kind === 'failure') Object.assign(response, { success: false, service: 'failed', outcome: 'partial', restarted: false,
                    error: 'Fixture service restart failed', details: '<img data-fixture-injected="mutation" src=x>\n' + 'complete checked restart output\n'.repeat(100) + 'last checked failure line',
                    restart: { ...restart, success: false, command_exit_code: 7, error: 'Fixture checked exit 7', details: 'complete restart stderr <literal>' } });
                if (kind === 'partial') Object.assign(response, { skipped: 1, partial: true, outcome: 'partial',
                    details: 'The association changed during download; one slot was skipped <literal>.' });
                if (kind === 'journal warning') response.journal = { recorded: true, finalized: false, unknown: true, error: 'Fixture journal finalization failed <literal>' };
                if (kind === 'unknown') Object.assign(response, { success: false, unknown: true, service: 'unknown', outcome: 'partial', restarted: false,
                    error: 'Fixture checked restart capture unknown', details: '<script>literal interrupted read</script>\nlast unknown capture line',
                    restart: { ...restart, success: false, unknown: true, command_result_known: false, command_exit_code: null,
                        errors: [{ stage: 'read', error: 'Interrupted system call', errno: 4 }] }, journal: { recorded: true, finalized: false, unknown: true } });
                if (kind === 'unchanged') {
                    Object.assign(response, { applied: false, updated: 0, unchanged: action.name === 'Update All' ? 1 : true, service: 'not_required', restarted: false,
                        outcomes: [{ section: 'main', slot: 0, status: 'unchanged' }] });
                    delete response.restart;
                }
                return response;
            };
            const load = async action => {
                fixtureProcesses.singbox = { running: true, pid: '123', instance: '123:' + (++fixtureStartTime) };
                queueFixtureReply('/copyapi/subscription_state', sectionState(action));
                await navigateFixture(base + '/copy-form?view=subscriptions');
                await wait('!!document.getElementById("ps-opt-save") && document.getElementById("ps-subs-content").style.display!=="none"', true);
                await evaluate('window.confirm=()=>true');
            };
            const send = async (action, response) => {
                const before = frontendPosts.length, plan = queueFixtureReply(action.endpoint, response, { hold: true });
                queueFixtureReply('/copyapi/subscription_state', sectionState(action));
                if (action.modal) {
                    if (await evaluate('document.getElementById("ps-sub-modal").style.display') !== 'flex') {
                        await evaluate('document.querySelector(".ps-sub-btn-attach").click()');
                        queueFixtureReply('/copyapi/subscription_fetch', { success: true, proxies: [proxy] });
                        await evaluate('document.getElementById("ps-sub-url").value="https://subscription.fixture.test/list";document.getElementById("ps-sub-fetch-btn").click()');
                        await wait('document.querySelectorAll("#ps-sub-proxy-list .ps-sub-proxy-item").length', 1);
                    }
                    await evaluate('document.querySelector("#ps-sub-proxy-list .ps-sub-proxy-item").click()');
                } else if (action.direct) {
                    queueFixtureReply('/copyapi/subscription_fetch', { success: true, proxies: [proxy] });
                    await evaluate('document.querySelector(".ps-sub-btn-update").click()');
                } else await evaluate('document.getElementById("ps-subs-update-all").click()');
                await waitFixture(() => plan.request, action.name + ' held mutation');
                assert.equal(plan.request.fields.token, 'browser-token');
                if (action.name !== 'Update All') {
                    assert.equal(plan.request.fields.section, 'main');
                    assert.equal(plan.request.fields.index, '0');
                    assert.equal(plan.request.fields.link, proxy.link);
                }
                return { plan, before };
            };
            const check = async (action, kind, response, options = {}) => {
                const role = options.role || (kind === 'success' ? 'success' : kind === 'failure' ? 'error' : kind === 'unchanged' ? 'muted' : 'warning');
                const modalProblem = action.modal && (options.modalProblem || ['failure', 'unknown'].includes(kind));
                const ids = [...action.ids, ...(modalProblem ? ['ps-sub-fetch-status'] : [])];
                const snapshots = [];
                for (const scheme of ['dark', 'light']) {
                    await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode',${JSON.stringify(scheme)})`);
                    await wait('document.documentElement.getAttribute("data-pt-dark")', String(scheme === 'dark'));
                    for (const id of ids) {
                        const snapshot = await noticeSnapshot(id);
                        assert.equal(snapshot.color, snapshot.colors[role], action.name + ' ' + kind + ': actual ' + scheme + ' notice color');
                        if (['success', 'unchanged'].includes(kind)) {
                            assertCompactNormal(snapshot);
                            assert.doesNotMatch(snapshot.raw, /Response:|operation_id|command_exit_code|Slot outcomes|Restart verification|\bjournal\b|\b0 skipped\b/i, 'successful/no-change results never render full technical payloads');
                            if (kind === 'success') assert.match(snapshot.text, /confirmed|new.*(?:instance|process)/i);
                        } else {
                            const detail = assertProblemDetails(snapshot, [response.operation_id, JSON.stringify(response, null, 2)]);
                            assert.equal(detail.summaryColor, snapshot.colors[role], action.name + ' ' + kind + ': disclosure summary must not inherit forced error CSS');
                            if (response.details) assert.ok(detail.body.includes(response.details));
                            if (kind === 'failure') {
                                assert.match(snapshot.text, /failed|partially applied|partial result/i);
                                assert.ok(detail.body.includes('"failed": 0'), 'service failure does not invent slot failures');
                                assert.ok(detail.body.includes('"command_exit_code": 7'));
                            }
                            if (kind === 'unknown') assert.ok(detail.body.includes('"errno": 4'));
                            if (options.uncertain) {
                                assert.match(snapshot.text, /unknown|invalid|unconfirmed/i, 'untyped metadata is explicit uncertainty');
                                assert.doesNotMatch(snapshot.text, /Update complete:|No proxy changes:|Association saved; proxy link unchanged|Restart confirmed/i, 'untyped metadata cannot produce a clean success/no-change result');
                            }
                            if (options.journalFailure) {
                                assert.match(snapshot.text, /journal|log|record|finaliz/i, 'a known journal failure stays visible with zero failed slots');
                                assert.ok(detail.body.includes('"failed": 0'));
                            }
                        }
                        assert.equal(await evaluate('!!document.querySelector("[data-fixture-injected]")'), false);
                        snapshots.push({ id, scheme, ...snapshot });
                    }
                }
                await evaluate('document.getElementById("ps-theme-context").setAttribute("data-mode","dark")');
                await wait('document.documentElement.getAttribute("data-pt-dark")', 'true');
                if (!['success', 'unchanged'].includes(kind)) {
                    const id = modalProblem ? 'ps-sub-fetch-status' : ids[0];
                    await evaluate(`document.querySelector('#${id} summary').click()`);
                    await wait(`document.querySelector('#${id} details').open`, true);
                    const expanded = await noticeSnapshot(id);
                    assert.ok(expanded.text.includes(response.operation_id), 'expanded mutation Details expose correlation facts');
                    if (copyDisplayed) {
                        const body = await evaluate(`document.querySelector('#${id} pre').textContent`);
                        await wait(`!!document.querySelector('#${id} .ps-copy-tools .ps-copy-btn')`, true);
                        assert.equal(await copyDisplayed('#' + id + ' .ps-copy-tools .ps-copy-btn'), body, 'expanded mutation diagnostics copy the complete literal source');
                        assert.equal(await evaluate(`document.querySelector('#${id} details').open`), true, 'Copy never toggles the disclosure');
                    }
                    await evaluate(`document.querySelector('#${id} summary').click()`);
                    await wait(`document.querySelector('#${id} details').open`, false);
                }
                report.push({ action: action.name, kind, response, snapshots });
            };
            const finish = async (action, response, sent) => {
                const checkedRestart = response.success && response.service === 'requested';
                const oldProcess = fixtureStatus('singbox');
                const oldObservation = checkedRestart ? queueFixtureReply('/copyapi/service_status', oldProcess, { hold: true }) : null;
                sent.plan.release();
                if (oldObservation) {
                    await waitFixture(() => oldObservation.request, action.name + ' read-only old process observation');
                    if (response.outcome === 'ok' && response.journal.finalized) for (const id of action.ids) {
                        const verifying = await noticeSnapshot(id);
                        assert.equal(verifying.details.length, 0, 'ordinary in-flight restart verification is compact');
                        assert.doesNotMatch(verifying.raw, /operation_id|command_exit_code|Response:/);
                        assert.doesNotMatch(verifying.text, /\b(?:restart|transition) confirmed\b|new.*instance.*running/i, 'a checked exit alone is not process proof');
                    }
                    oldObservation.release();
                    await new Promise(resolve => setTimeout(resolve, 100));
                    for (const id of action.ids) assert.doesNotMatch((await noticeSnapshot(id)).text, /\b(?:restart|transition) confirmed\b|new.*instance.*running/i, 'old PID:start-time cannot confirm restart');
                    fixtureProcesses.singbox = { running: true, pid: '123', instance: '123:' + (++fixtureStartTime) };
                    assert.notEqual(fixtureStatus('singbox').instance, response.restart.previous_instance);
                }
                if (response.unknown) await wait('document.getElementById("ps-global-status").textContent.includes("unknown")', true);
                else await wait('document.getElementById("ps-subs-update-all").disabled', false, 7000);
                await waitFixture(() => !(fixtureReplyQueues.get('/copyapi/subscription_state') || []).length, action.name + ' current-state readback');
                const expected = [...(action.direct || action.modal && sent.plan.request !== undefined && frontendPosts[sent.before] === '/copyapi/subscription_fetch' ? ['/copyapi/subscription_fetch'] : []), action.endpoint];
                assert.deepEqual(frontendPosts.slice(sent.before), expected, action.name + ': one admitted mutation and no automatic replay');
            };
            try {
                brokenSchedule = false;
                for (const action of actions) {
                    await load(action);
                    const failed = responseFor(action, 'failure'), failure = await send(action, failed);
                    await finish(action, failed, failure); await check(action, 'failure', failed);
                    const success = responseFor(action, 'success'), sent = await send(action, success);
                    await finish(action, success, sent); await check(action, 'success', success);
                    for (const id of action.ids) assert.equal((await noticeSnapshot(id)).details.length, 0, 'failure → success removes the old error disclosure and resets its computed color');
                }
                for (const [action, kinds] of [[actions[0], ['unchanged', 'partial', 'journal warning', 'unknown']], [actions[1], ['unchanged', 'partial', 'unknown']]]) {
                    for (const kind of kinds) {
                        await load(action);
                        const response = responseFor(action, kind), sent = await send(action, response);
                        await finish(action, response, sent); await check(action, kind, response);
                        if (kind === 'unknown') {
                            const before = frontendPosts.length;
                            await evaluate('document.getElementById("ps-subs-update-all").dispatchEvent(new MouseEvent("click",{bubbles:true}))');
                            assert.equal(frontendPosts.length, before, 'uncertain mutation cannot be replayed through a forged click');
                        }
                    }
                }
                // These replies have otherwise valid no-change counters and
                // journal facts. Only the malformed metadata distinguishes them
                // from the compact neutral result exercised above.
                const malformedMetadata = [
                    { name: 'invalid outcome enum', fields: { outcome: 'unexpected <svg data-fixture-injected="outcome">' } },
                    { name: 'invalid outcome number', fields: { outcome: 0 } },
                    { name: 'invalid outcome null', fields: { outcome: null } },
                    { name: 'invalid unknown string', fields: { unknown: 'false' } },
                    { name: 'invalid unknown number', fields: { unknown: 0 } },
                    { name: 'invalid unknown null', fields: { unknown: null } }
                ];
                for (const action of actions) for (const test of malformedMetadata) {
                    await load(action);
                    const response = Object.assign(responseFor(action, 'unchanged'), test.fields);
                    const sent = await send(action, response);
                    assert.equal(await evaluate('document.getElementById("ps-subs-update-all").disabled'), true, 'the admitted mutation owns its gate while awaiting the reply');
                    sent.plan.release();
                    await wait(`!!document.querySelector('#${action.ids[0]} details')`, true);
                    await waitFixture(() => !(fixtureReplyQueues.get('/copyapi/subscription_state') || []).length, test.name + ': factual current-state refresh');
                    await check(action, test.name, response, { uncertain: true, modalProblem: action.modal });
                    assert.equal(await evaluate('document.getElementById("ps-subs-update-all").disabled'), true, 'invalid mutation metadata cannot reopen the mutation gate');
                    const gate = await evaluate(`Array.from(document.querySelectorAll('#ps-subs-content [data-section="main"][data-index="0"]')).map(button=>button.disabled)`);
                    assert.ok(gate.length > 0 && gate.every(Boolean), 'the affected slot retains its uncertainty gate after readback');
                    const beforeReplay = frontendPosts.length, browserPosts = await evaluate('window.fixtureXHR.filter(request=>request.method==="POST").length');
                    await evaluate(`document.getElementById('ps-subs-update-all').dispatchEvent(new MouseEvent('click',{bubbles:true}));
                        const update=document.querySelector('.ps-sub-btn-update');if(update)update.dispatchEvent(new MouseEvent('click',{bubbles:true}));
                        const proxy=document.querySelector('#ps-sub-proxy-list .ps-sub-proxy-item');if(proxy)proxy.dispatchEvent(new MouseEvent('click',{bubbles:true}));`);
                    await new Promise(resolve => setTimeout(resolve, 100));
                    assert.equal(await evaluate('window.fixtureXHR.filter(request=>request.method==="POST").length'), browserPosts, 'forged controls cannot replay an uncertain mutation or refetch its subscription');
                    assert.equal(frontendPosts.length, beforeReplay, 'the local API receives no replay');
                    assert.equal(await evaluate('window.fixtureXHR.some(request=>/service_status/.test(request.url))'), false, 'malformed no-change metadata cannot start a fabricated restart verification');
                }
                for (const action of actions) for (const phase of ['recording', 'finalization']) {
                    await load(action);
                    const response = responseFor(action, phase === 'recording' ? 'unchanged' : 'success');
                    Object.assign(response, { success: false, applied: true, outcome: 'partial', unknown: false,
                        error: 'Cannot ' + (phase === 'recording' ? 'write' : 'finalize') + ' subscription update log',
                        details: 'Permission denied: /etc/config/pt-update.log\n' + 'complete ' + phase + ' diagnostics <literal>\n'.repeat(60) + 'last journal ' + phase + ' detail',
                        journal: { recorded: phase !== 'recording', finalized: false, unknown: false,
                            error: 'Journal ' + phase + ' failed <literal>', details: 'Permission denied: journal ' + phase + '\nlast private journal fact' } });
                    const sent = await send(action, response);
                    await finish(action, response, sent);
                    await check(action, 'known journal ' + phase + ' failure', response, { role: 'error', modalProblem: action.modal, journalFailure: true });
                    assert.equal(response.failed, 0, 'journal failures remain separate from the slot failure counter');
                    assert.equal(await evaluate('document.getElementById("ps-subs-update-all").disabled'), false, 'a known failure releases only its completed operation gate');
                    assert.equal(await evaluate('window.fixtureXHR.some(request=>/service_status/.test(request.url))'), false, 'a failed journal result does not authorize another restart');
                }
                return report;
            } catch (error) {
                const snapshots = {};
                for (const id of ['ps-global-status', 'ps-slot-status-main-0', 'ps-sub-fetch-status']) snapshots[id] = await noticeSnapshot(id).catch(() => null);
                fs.writeFileSync(path.join(artifacts, 'subscription-mutations-failure.json'), JSON.stringify({ error: error.stack, report, snapshots }, null, 2));
                throw error;
            } finally {
                Object.assign(fixtureProcesses, beforeProcesses); Object.assign(subscriptionSettings, beforeSettings); brokenSchedule = beforeBroken;
            }
        };
        const exerciseAutoSetupFailures = async () => {
            const report = [], postsBefore = frontendPosts.length, processesBefore = JSON.parse(JSON.stringify(fixtureProcesses)), beforeBroken = brokenSchedule;
            const settingsBefore = { ...subscriptionSettings };
            let expectedReads = 1;
            const sources = [{ key: 'cron', label: 'Schedule', path: '/etc/crontabs/root' },
                { key: 'launcher', label: 'Launcher', path: '/usr/bin/pt-auto-update' },
                { key: 'hotplug', label: 'WAN trigger', path: '/etc/hotplug.d/iface/99-pt-subs' }];
            const setupContext = response => JSON.parse(JSON.stringify({ cron: response.cron, launcher: response.launcher, hotplug: response.hotplug }));
            const parseContext = body => {
                for (const marker of ['Context:\n', 'Component:\n']) {
                    const index = body.lastIndexOf(marker);
                    if (index >= 0) {
                        const context = body.slice(index + marker.length), receipt = context.indexOf('\n\nHTTP status:');
                        return JSON.parse(receipt < 0 ? context : context.slice(0, receipt));
                    }
                }
                return JSON.parse(body);
            };
            const mode = (cron, wan) => {
                const response = fixtureAutoStatus({ last_auto: journalLastFinished });
                response.cron.enabled = cron;
                response.hotplug.enabled = wan;
                if (!cron) { delete response.cron.expected; Object.assign(response.cron, { matches: true, running: false, actual: [] }); }
                if (!wan) Object.assign(response.hotplug, { exists: false, matches: false, executable: false });
                if (!cron && !wan) Object.assign(response.launcher, { exists: false, matches: false, executable: false });
                return response;
            };
            const refresh = async response => {
                const before = await autoReplyCount(), current = await autoStatusSnapshot();
                const plan = queueFixtureReply('/copyapi/auto_update_status', response, { hold: true });
                await evaluate('document.getElementById("ps-subs-refresh").click()');
                await waitFixture(() => plan.request, 'held read-only auto-setup response');
                assert.deepEqual(await autoStatusSnapshot(), current, 'an in-flight read retains the current hidden/problem presentation');
                plan.release(); expectedReads++; await waitAutoReplies(before + 1);
                return autoStatusSnapshot();
            };
            const assertProblem = async (response, expected) => {
                const observed = [], expectedContext = expected.context || setupContext(response);
                for (const scheme of ['dark', 'light']) {
                    await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode',${JSON.stringify(scheme)})`);
                    await wait('document.documentElement.getAttribute("data-pt-dark")', String(scheme === 'dark'));
                    const widget = await autoStatusSnapshot();
                    assert.equal(widget.visible, true, 'an actual setup problem or uncertainty is visible');
                    assert.deepEqual(widget.headings, []); assert.equal(widget.tables, 0);
                    assert.equal(widget.injected, false);
                    assert.equal(widget.items.length, expected.problems.length, 'only actual required setup problems are displayed');
                    const used = new Set();
                    for (const problem of expected.problems) {
                        const index = widget.items.findIndex((item, index) => !used.has(index) && problem.label.test(item.text));
                        assert.ok(index >= 0, 'the concise issue identifies ' + problem.label);
                        used.add(index);
                        const item = widget.items[index], detail = assertProblemDetails(item, []);
                        assert.ok(item.text.trim().length <= 260, 'problem feedback is a concise issue plus collapsed Details');
                        assert.match(item.text, problem.message);
                        assert.equal(item.color, widget.colors[problem.role], 'actual ' + scheme + ' issue color');
                        assert.equal(detail.summaryColor, widget.colors[problem.role], 'actual ' + scheme + ' Details summary color');
                        assert.deepEqual(parseContext(detail.body), expectedContext, 'complete setup/pending context is retained without coercion or truncation');
                        assert.doesNotMatch(item.text, /Expected .* found|Last (?:finished|automatic result)|Actual Auto.Update Status/i);
                        if (problem.error) assert.ok(detail.body.includes(problem.error), 'complete native Permission Denied text, including final lines, remains literal');
                        const target = `document.getElementById('ps-auto-status').children[${index}]`;
                        await evaluate(`(${target}).querySelector('summary').click()`);
                        await wait(`(${target}).querySelector('details').open`, true);
                        const expanded = await evaluate(`(${target}).innerText`);
                        assert.ok(expanded.includes(JSON.stringify(expectedContext, null, 2)), 'expanding actual Details exposes every raw context field');
                        if (problem.error) assert.ok(expanded.includes(problem.error));
                        await evaluate(`(${target}).querySelector('summary').click()`);
                        await wait(`(${target}).querySelector('details').open`, false);
                    }
                    observed.push({ scheme, widget });
                }
                return observed;
            };
            try {
                brokenSchedule = false;
                const healthy = mode(true, true);
                queueFixtureReply('/copyapi/auto_update_status', healthy);
                await navigateFixture(base + '/copy-form?view=subscriptions');
                await waitAutoReplies(1);
                await wait('!!document.getElementById("ps-opt-save")', true);
                assertHiddenAutoStatus(await autoStatusSnapshot());
                const wanNoDaemonFact = mode(false, true); delete wanNoDaemonFact.cron.running;
                const disabledUnusedFacts = mode(false, false); delete disabledUnusedFacts.cron.running; delete disabledUnusedFacts.launcher;
                for (const [name, response] of [
                    ['healthy enabled cron + WAN', healthy],
                    ['both disabled, absent launcher and crond stopped', mode(false, false)],
                    ['both disabled, unused launcher and daemon facts absent', disabledUnusedFacts],
                    ['WAN only, crond stopped and not required', mode(false, true)],
                    ['WAN only, unused daemon fact absent', wanNoDaemonFact],
                    ['cron only, absent disabled WAN hook', mode(true, false)],
                    ['completed partial automatic result is history only', { ...healthy, last_auto: journalFinished }],
                    ['completed service failure is history only', { ...healthy, last_auto: { ...journalLastFinished, service: 'failed', outcome: 'partial' } }],
                    ['legacy automatic result is history only', { ...healthy, last_auto: { ts: '11:00 19.10.2026', updated: 0, unchanged: 2, failed: 1, legacy: true } }]
                ]) {
                    const widget = await refresh(response); assertHiddenAutoStatus(widget);
                    assert.equal(widget.raw.includes(healthy.cron.expected), false, 'healthy setup never renders the raw expected cron entry');
                    report.push({ name, response, widget });
                }
                const cases = [], warning = (name, response, label, message) => cases.push({ name, response, problems: [{ label, message, role: 'warning' }] });
                let response = mode(true, true); Object.assign(response.cron, { matches: false, actual: [] });
                warning('enabled cron entry missing', response, /schedule/i, /missing|different/i);
                response = mode(true, true); response.cron.running = false;
                warning('required cron daemon stopped', response, /cron daemon/i, /not detected|not running|cannot confirm/i);
                for (const key of ['launcher', 'hotplug']) for (const fault of ['absent', 'changed', 'not executable']) {
                    response = mode(true, true);
                    Object.assign(response[key], fault === 'absent' ? { exists: false, matches: false, executable: false } : fault === 'changed' ? { matches: false } : { executable: false });
                    warning('required ' + key + ' ' + fault, response, key === 'launcher' ? /launcher/i : /WAN/i, /missing|changed|not executable/i);
                }
                response = mode(false, false); Object.assign(response.cron, { matches: false, actual: [healthy.cron.expected] });
                warning('disabled scheduling retains an own job', response, /schedule/i, /disabled.*(?:entry|trigger)|unexpected cron/i);
                response = mode(false, false); Object.assign(response.hotplug, { exists: true, matches: true, executable: true });
                warning('disabled WAN retains an own hook', response, /WAN/i, /disabled.*hook|hook.*trigger/i);
                for (const [key, field, label] of [['cron', 'enabled', /schedule/i], ['hotplug', 'enabled', /WAN/i], ['cron', 'running', /cron daemon/i], ['launcher', 'executable', /launcher/i]]) {
                    response = mode(true, true); delete response[key][field];
                    warning('missing required ' + key + '.' + field, response, label, /cannot confirm|unknown/i);
                }
                for (const [key, label] of [['cron', /schedule/i], ['hotplug', /WAN/i], ['launcher', /launcher/i]]) {
                    response = mode(true, true); delete response[key];
                    warning('missing required ' + key + ' component', response, label, /cannot confirm|unknown/i);
                }
                response = mode(true, true); response.cron.running = 'false';
                warning('untyped required daemon fact is unknown', response, /cron daemon/i, /cannot confirm|unknown/i);
                response = mode(true, true);
                Object.assign(response.cron, { error: 'Permission denied: crontab read with independent daemon facts', running: false });
                cases.push({ name: 'crontab IO failure retains separately typed absent daemon', response, problems: [
                    { label: /schedule/i, message: /cannot read/i, role: 'error', error: response.cron.error },
                    { label: /cron daemon/i, message: /not detected|cannot confirm/i, role: 'warning' }
                ] });
                for (const source of sources) for (const test of [
                    { name: 'IO permission failure', role: 'error', error: 'Permission denied: ' + source.path + '\n<svg data-fixture-injected="auto-io">literal read evidence</svg>\n' +
                        ('complete ' + source.key + ' IO diagnostic\n').repeat(80) + 'last Permission Denied ' + source.key + ' detail' },
                    { name: 'invalid boolean error', role: 'warning', error: false },
                    { name: 'invalid numeric error', role: 'warning', error: 0 },
                    { name: 'invalid null error', role: 'warning', error: null },
                    { name: 'invalid object error', role: 'warning', error: { message: 'Permission denied <img data-fixture-injected="auto-type">', errno: 13 } },
                    { name: 'invalid array error', role: 'warning', error: ['Permission denied', 13] }
                ]) {
                    const response = mode(true, true);
                    response[source.key] = { ...response[source.key], error: test.error };
                    if (test.role === 'error') {
                        response[source.key].matches = false;
                        if (source.key !== 'cron') Object.assign(response[source.key], { exists: false, executable: false });
                    }
                    cases.push({ name: source.key + ' ' + test.name, response, problems: [{ label: new RegExp(source.label, 'i'), message: test.role === 'error' ? /cannot read/i : /cannot confirm|unknown/i,
                        role: test.role, error: typeof test.error === 'string' ? test.error : null }] });
                }
                for (const test of cases) {
                    await refresh(test.response);
                    const observed = await assertProblem(test.response, test);
                    const recovered = await refresh(healthy); assertHiddenAutoStatus(recovered);
                    report.push({ name: test.name, response: test.response, observed, recovered });
                }
                const pendingCases = [
                    { name: 'valid newer pending', finished: journalLastFinished, pending: journalPending },
                    { name: 'file-ordered pending in the same minute', finished: journalLastFinished, pending: { ...journalPending, ts: journalLastFinished.ts } },
                    { name: 'pending after legacy history', finished: { ts: '10:00 19.10.2026', updated: 0, unchanged: 2, failed: 0, legacy: true }, pending: journalPending },
                    { name: 'pending without a finished record', finished: null, pending: journalPending },
                    { name: 'malformed pending counter', finished: journalLastFinished, pending: { ...journalPending, updated: journalCounters.updated }, warning: true },
                    { name: 'malformed pending state', finished: journalLastFinished, pending: { ...journalPending, state: 'finished' }, warning: true },
                    { name: 'malformed pending service', finished: journalLastFinished, pending: { ...journalPending, service: 'requested' }, warning: true },
                    { name: 'malformed pending ID', finished: journalLastFinished, pending: { ...journalPending, id: 'A'.repeat(32) }, warning: true },
                    { name: 'pending conflicts with finished ID', finished: journalLastFinished, pending: { ...journalPending, id: journalLastFinished.id }, warning: true },
                    { name: 'finished identity unknown for pending comparison', finished: { ...journalLastFinished, id: false }, pending: journalPending, warning: true }
                ];
                for (const test of pendingCases) {
                    const response = { ...healthy, last_auto: test.finished, last_auto_pending: test.pending };
                    const widget = await refresh(response);
                    let observed;
                    if (test.warning) observed = await assertProblem(response, { context: { last_auto: test.finished, last_auto_pending: test.pending },
                        problems: [{ label: /automatic update/i, message: /unknown|invalid|cannot confirm|conflict/i, role: 'warning' }] });
                    else { assertNeutralPending(widget); observed = widget; }
                    assertHiddenAutoStatus(await refresh(healthy));
                    report.push({ name: test.name, response, observed });
                }
                // A real Save Options ACK must trigger the existing factual GET,
                // while recovery uses Refresh Sections and never repairs/replays.
                const brokenWan = mode(true, true); Object.assign(brokenWan.hotplug, { exists: false, matches: false, executable: false });
                const afterSave = queueFixtureReply('/copyapi/auto_update_status', brokenWan, { hold: true }), autoBeforeSave = await autoReplyCount();
                await evaluate('document.getElementById("ps-theme-context").setAttribute("data-mode","dark")');
                await wait('document.documentElement.getAttribute("data-pt-dark")', 'true');
                await evaluate('document.getElementById("ps-opt-cron").checked=true;document.getElementById("ps-opt-interval").value="4";document.getElementById("ps-opt-start").value="01:30";document.getElementById("ps-opt-restart").checked=true;document.getElementById("ps-opt-save").click()');
                await waitFixture(() => afterSave.request, 'Save Options refreshes actual setup'); afterSave.release();
                expectedReads++;
                await waitAutoReplies(autoBeforeSave + 1);
                const savedProblem = await assertProblem(brokenWan, { problems: [{ label: /WAN/i, message: /missing|changed|not executable/i, role: 'warning' }] });
                const recovered = await refresh(healthy); assertHiddenAutoStatus(recovered);
                const xhr = await evaluate('window.fixtureXHR');
                assert.equal(xhr.filter(request=>new URL(request.url, base).pathname==='/copyapi/auto_update_status').length, expectedReads, 'only page load and explicit Refresh/Save actions read setup; no periodic auto-setup polling');
                assert.deepEqual(xhr.filter(request=>request.method==='POST').map(request=>request.url), ['/copyapi/settings_save'], 'only the explicit Save Options action mutates; setup/pending reads never repair or replay');
                assert.deepEqual(frontendPosts.slice(postsBefore), ['/copyapi/settings_save']);
                assert.deepEqual(fixtureProcesses, processesBefore);
                return { cases: report, afterSave: savedProblem, recovered, requests: xhr };
            } catch (error) {
                fs.writeFileSync(path.join(artifacts, 'auto-setup-failure.json'), JSON.stringify({ error: error.stack, report, snapshot: await autoStatusSnapshot(), xhr: await evaluate('window.fixtureXHR') }, null, 2));
                throw error;
            } finally {
                brokenSchedule = beforeBroken; Object.assign(subscriptionSettings, settingsBefore);
            }
        };
        const exerciseAutoSetupHTTP = async ({ copyDisplayed = null } = {}) => {
            const report = [], postsBefore = frontendPosts.length, processesBefore = JSON.parse(JSON.stringify(fixtureProcesses)), beforeBroken = brokenSchedule;
            let expectedReads = 1, currentCase = null;
            const observeTerminal = async spec => evaluate(`(() => {
                if(window.fixtureSetupObserver)window.fixtureSetupObserver.disconnect();
                window.fixtureSetupTerminals=[];
                const spec=${JSON.stringify(spec)},el=document.getElementById('ps-auto-status');
                window.fixtureSetupObserver=new MutationObserver(()=>{
                    const bodies=[...el.querySelectorAll('pre,.ps-error-details')].map(body=>body.textContent).join('\\n');
                    const hidden=getComputedStyle(el).display==='none'&&el.textContent.trim()==='';
                    if(spec.hidden?hidden:bodies.includes(spec.raw))window.fixtureSetupTerminals.push({hidden,bodies});
                });
                window.fixtureSetupObserver.observe(el,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['style']});
            })()`);
            const stopObserving = async () => {
                await new Promise(resolve => setTimeout(resolve, 150));
                return evaluate('window.fixtureSetupObserver.disconnect();window.fixtureSetupTerminals');
            };
            const request = async (data, options = {}) => {
                const before = await autoReplyCount(), current = await autoStatusSnapshot(), xhrBefore = await evaluate('window.fixtureXHR.length');
                const plan = queueFixtureReply('/copyapi/auto_update_status', data, { ...options, hold: true });
                await evaluate('document.getElementById("ps-subs-refresh").click()');
                await waitFixture(() => plan.request, 'actual setup HTTP request');
                assert.deepEqual(await autoStatusSnapshot(), current, 'an unfinished current HTTP read cannot erase the prior hidden/problem snapshot');
                assert.equal(await evaluate(`window.fixtureXHR.slice(${xhrBefore}).filter(request=>new URL(request.url,location.href).pathname==='/copyapi/auto_update_status').length`), 1);
                plan.release(); expectedReads++; await waitAutoReplies(before + 1);
                return plan;
            };
            try {
                brokenSchedule = false;
                const healthy = fixtureAutoStatus({ last_auto: journalLastFinished });
                const disabled = fixtureAutoStatus({
                    cron: { enabled: false, matches: true, running: false, actual: [] },
                    launcher: { exists: false, matches: false, executable: false },
                    hotplug: { enabled: false, exists: false, matches: false, executable: false }, last_auto: journalLastFinished
                });
                queueFixtureReply('/copyapi/auto_update_status', healthy);
                await navigateFixture(base + '/copy-form?view=subscriptions');
                await waitAutoReplies(1); await wait('!!document.getElementById("ps-opt-save")', true);
                assertHiddenAutoStatus(await autoStatusSnapshot());
                if (copyDisplayed) await evaluate(`(() => {
                    // Observe the actual native setter without replacing Copy.
                    // textarea.value canonicalizes CRLF to LF on readback, so
                    // retain both the exact source argument and native value.
                    const descriptor=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value');
                    window.fixtureTextAreaValueDescriptor=descriptor;window.fixtureCopyAssignments=[];
                    Object.defineProperty(HTMLTextAreaElement.prototype,'value',{...descriptor,set(value){
                        descriptor.set.call(this,value);
                        if(this.classList.contains('ps-copy-fallback'))window.fixtureCopyAssignments.push({source:String(value),nativeValue:descriptor.get.call(this)});
                    }});
                })()`);
                const payload503 = { success: false, error: 'Cannot read setup <literal HTTP 503 error>',
                    details: 'Permission denied: /etc/crontabs/root\n<script data-fixture-injected="http-json">window.fixtureSetupHTTPExecuted=true</script>\n' +
                        'complete HTTP 503 read diagnostics\n'.repeat(90) + 'last HTTP 503 diagnostic', errno: 13, stage: 'open',
                    context: { cron: disabled.cron, launcher: disabled.launcher, hotplug: disabled.hotplug } };
                const htmlBody = status => '<!doctype html>\r\n<html><body><h1>LuCI session response ' + status + '</h1>\r\n' +
                    '<script data-fixture-injected="http-html-' + status + '">window.fixtureSetupHTTPExecuted=true</script>\r\n' +
                    '<form action="/cgi-bin/luci" method="post">Log in</form>\r\n' + 'complete literal session diagnostic\r\n'.repeat(90) + 'last HTML ' + status + ' detail</body></html>\r\n';
                const cases = [
                    { name: 'HTTP 503 JSON preserves error/details/errno and raw spacing', status: 503, role: 'error', data: payload503, raw: ' \n' + JSON.stringify(payload503, null, 3) + '\n\n', contentType: 'application/json' },
                    { name: 'HTTP 403 HTML remains complete literal data', status: 403, role: 'error', raw: htmlBody(403), contentType: 'text/html' },
                    { name: 'HTTP 200 malformed JSON is uncertainty', status: 200, role: 'warning', raw: ' {"cron":\n<script data-fixture-injected="http-invalid">window.fixtureSetupHTTPExecuted=true</script>\n' + 'malformed body detail\n'.repeat(90) + 'last invalid JSON detail', contentType: 'application/json' },
                    { name: 'HTTP 200 HTML is uncertainty', status: 200, role: 'warning', raw: htmlBody(200), contentType: 'text/html' },
                    { name: 'HTTP 200 JSON array cannot establish disabled setup', status: 200, role: 'warning', raw: ' \n[ { "enabled": false, "marker": "<script>literal array body</script>" } ]\n', contentType: 'application/json' },
                    { name: 'HTTP 503 with otherwise healthy disabled facts is still an error', status: 503, role: 'error', data: disabled, raw: '\n' + JSON.stringify(disabled, null, 3) + '\n', contentType: 'application/json' }
                ];
                for (const [index, test] of cases.entries()) {
                    currentCase = test;
                    await observeTerminal({ raw: test.raw });
                    await request(test.data, { status: test.status, raw: test.raw, contentType: test.contentType });
                    const completions = await stopObserving();
                    assert.equal(completions.length, 1, 'one native XHR response produces one terminal diagnostic render, without duplicate completion');
                    const observed = [];
                    for (const scheme of ['dark', 'light']) {
                        await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode',${JSON.stringify(scheme)})`);
                        await wait('document.documentElement.getAttribute("data-pt-dark")', String(scheme === 'dark'));
                        const widget = await autoStatusSnapshot(), detail = assertProblemDetails(widget, [test.raw]);
                        assert.equal(widget.visible, true, 'a current failed/invalid HTTP read cannot hide or establish disabled setup');
                        assert.equal(widget.color, widget.colors[test.role], 'actual ' + scheme + ' HTTP diagnostic color');
                        assert.equal(detail.summaryColor, widget.colors[test.role], 'actual ' + scheme + ' HTTP summary color');
                        assert.match(detail.body, new RegExp('(?:Request status|HTTP(?: status)?|Status)[: ]+' + test.status, 'i'), 'the actual HTTP status remains in complete diagnostic context');
                        assert.doesNotMatch(widget.text, /disabled|not required|expected .*found|Current setup does not guarantee|Cron and WAN share|Last (?:finished|automatic result)/i, 'failed reads do not report normal setup facts or a normal footnote');
                        assert.deepEqual(widget.headings, []); assert.equal(widget.tables, 0); assert.deepEqual(widget.notes, []);
                        assert.equal(widget.injected, false);
                        assert.equal(await evaluate('window.fixtureSetupHTTPExecuted===true'), false);
                        assert.equal(await evaluate('document.querySelectorAll("#ps-auto-status script").length'), 0, 'literal script markers never become DOM scripts');
                        if (test.data === payload503) {
                            assert.ok(detail.body.includes(payload503.error));
                            assert.ok(detail.body.includes('last HTTP 503 diagnostic'));
                            assert.ok(detail.body.includes('"errno": 13'));
                            assert.ok(detail.body.includes('"stage": "open"'));
                        }
                        await evaluate('document.querySelector("#ps-auto-status summary").click()');
                        await wait('document.querySelector("#ps-auto-status details").open', true);
                        const expanded = await autoStatusSnapshot();
                        assert.ok(expanded.details[0].body.includes(test.raw), 'expanded native Details retain every response byte, including CRLF and final whitespace');
                        assert.ok(expanded.text.replace(/\r\n?/g, '\n').includes(test.raw.replace(/\r\n?/g, '\n').trim()), 'visible Details display the complete literal body regardless of innerText CRLF serialization; textContent and the native Copy input are checked byte-exact separately');
                        assert.equal(expanded.details[0].literal, true);
                        let copyEvidence = null;
                        if (copyDisplayed) {
                            await wait('!!document.querySelector("#ps-auto-status .ps-copy-tools .ps-copy-btn")', true);
                            const source = await evaluate('document.querySelector("#ps-auto-status pre").textContent');
                            assert.equal(source, detail.body, 'Copy source is the complete status/body/error context observed before expansion');
                            const assignmentsBefore = await evaluate('window.fixtureCopyAssignments.length');
                            const copied = await copyDisplayed('#ps-auto-status .ps-copy-tools .ps-copy-btn');
                            const assignments = await evaluate(`window.fixtureCopyAssignments.slice(${assignmentsBefore})`);
                            assert.equal(assignments.length, 1, 'one native HTTP fallback Copy assigns its source once');
                            assert.equal(assignments[0].source, source, 'the real native textarea setter receives the byte-exact complete HTTP diagnostic source/context');
                            assert.equal(copied, assignments[0].nativeValue, 'the intercepted copy event reads the actual native textarea value');
                            assert.equal(copied, source.replace(/\r\n?/g, '\n'), 'only native textarea line-ending canonicalization is permitted; no body/context content is lost');
                            copyEvidence = { source, assignment: assignments[0], intercepted: copied };
                            assert.equal(await evaluate('document.querySelector("#ps-auto-status details").open'), true, 'Copy never toggles HTTP Details');
                            assert.equal(await evaluate('document.querySelectorAll(".ps-copy-fallback").length'), 0);
                        }
                        await evaluate('document.querySelector("#ps-auto-status summary").click()');
                        await wait('document.querySelector("#ps-auto-status details").open', false);
                        observed.push({ scheme, widget, expanded, copy: copyEvidence });
                    }
                    await observeTerminal({ hidden: true });
                    await request(index % 2 ? healthy : disabled);
                    const recovered = await autoStatusSnapshot(), recoveryCompletions = await stopObserving();
                    assertHiddenAutoStatus(recovered);
                    assert.equal(recoveryCompletions.length, 1, 'one successful current retry clears the old diagnostic exactly once');
                    report.push({ name: test.name, status: test.status, contentType: test.contentType, raw: test.raw, observed, completions, recovered, recoveryCompletions });
                }
                // The retained fixture_generation mechanism also covers late
                // non-200 responses through the new page-local GET boundary.
                currentCase = { name: 'stale HTTP 503 after newer healthy HTTP 200' };
                const beforeRace = await autoReplyCount();
                await observeTerminal({ raw: cases[0].raw });
                const older = queueFixtureReply('/copyapi/auto_update_status', payload503, { status: 503, raw: cases[0].raw, hold: true });
                await evaluate("PT.urls.auto_status='/copyapi/auto_update_status?fixture_generation=http-earlier';document.getElementById('ps-subs-refresh').click()");
                await waitFixture(() => older.request, 'earlier held HTTP 503');
                const newer = queueFixtureReply('/copyapi/auto_update_status', healthy, { hold: true });
                await evaluate("PT.urls.auto_status='/copyapi/auto_update_status?fixture_generation=http-current';document.getElementById('ps-subs-refresh').click()");
                await waitFixture(() => newer.request, 'later healthy setup read');
                newer.release(); expectedReads++; await waitAutoReplies(beforeRace + 1);
                const current = await autoStatusSnapshot(); assertHiddenAutoStatus(current);
                older.release(); expectedReads++; await waitAutoReplies(beforeRace + 2);
                assert.deepEqual(await autoStatusSnapshot(), current, 'a stale HTTP error cannot restore old Details over the later healthy hidden widget');
                assert.deepEqual(await stopObserving(), [], 'the stale HTTP error never renders a terminal diagnostic');
                const xhr = await evaluate('window.fixtureXHR'), done = await evaluate('window.fixtureXHRDone');
                const setupReads = xhr.filter(request=>new URL(request.url, base).pathname==='/copyapi/auto_update_status');
                assert.equal(setupReads.length, expectedReads, 'HTTP failures and retries do not duplicate setup GETs or add polling');
                assert.ok(setupReads.every(request=>request.method==='GET'&&request.timeout===30000), 'the actual page-local read retains its finite native GET deadline');
                assert.ok(xhr.every(request=>request.method==='GET'), 'setup HTTP failure/inspection/recovery sends no mutation');
                assert.equal(frontendPosts.length, postsBefore);
                assert.deepEqual(fixtureProcesses, processesBefore);
                return { cases: report, race: { current, final: await autoStatusSnapshot() }, requests: xhr, completions: done };
            } catch (error) {
                fs.writeFileSync(path.join(artifacts, 'auto-setup-http-failure.json'), JSON.stringify({ error: error.stack, currentCase, report, snapshot: await autoStatusSnapshot(), renders: await evaluate('window.fixtureSetupTerminals'), xhr: await evaluate('window.fixtureXHR'), done: await evaluate('window.fixtureXHRDone') }, null, 2));
                throw error;
            } finally {
                await evaluate("if(window.fixtureSetupObserver)window.fixtureSetupObserver.disconnect();if(window.fixtureTextAreaValueDescriptor){Object.defineProperty(HTMLTextAreaElement.prototype,'value',window.fixtureTextAreaValueDescriptor);delete window.fixtureTextAreaValueDescriptor;}").catch(() => {});
                brokenSchedule = beforeBroken;
            }
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

            // A count-zero fixture hides three actions and cannot reproduce the
            // reported footer clipping. Use two real typed TLS rows instead.
            const fragmentPosts = frontendPosts.length, fragmentProcesses = JSON.parse(JSON.stringify(fixtureProcesses));
            const fragmentGeometry = [], fragmentButtons = ['ps-patch-select-all', 'ps-patch-apply', 'ps-patch-remove', 'ps-patch-retry', 'ps-patch-close'];
            const fragmentScope = [], fragmentWidths = [1440, 768, 390, 320];
            const grownFragmentActions = new Set();
            queueFixtureReply('/copyapi/wrapper_status', { installed: true, stale: true });
            queueFixtureReply('/copyapi/singbox_outbounds', fixtureTLSOutbounds);
            await navigateFixture(base + '/copy-form?view=singbox');
            await wait('document.getElementById("ps-wrapper-btn")?.textContent', 'Reinstall Wrapper');
            assert.match(await evaluate('document.getElementById("ps-wrapper-status").textContent'), /outdated or missing/i, 'stale wrapper evidence does not establish that every wrapper hook was lost');
            await evaluate('document.getElementById("ps-patch-btn").click()');
            await wait('document.querySelectorAll("#ps-patch-list .ps-patch-cb").length', 2);
            assert.deepEqual(await evaluate('[...document.querySelectorAll("#ps-patch-list .ps-patch-cb")].map(el=>el.getAttribute("data-tag"))'), fixtureTLSOutbounds.outbounds.map(row => row.tag));
            for (const row of fixtureTLSOutbounds.outbounds) assert.ok((await evaluate('document.getElementById("ps-patch-list").textContent')).includes(row.server));
            const fragmentLayout = async (state, width, enlarged, lateTheme = false, scheme = 'dark') => {
                await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode',${JSON.stringify(scheme)})`);
                await wait('document.documentElement.getAttribute("data-pt-dark")', String(scheme === 'dark'));
                await cdp.call('Emulation.setDeviceMetricsOverride', { width, height: width === 1440 ? 1100 : 844, deviceScaleFactor: 1, mobile: false }, sessionId);
                await evaluate(`(() => {
                    const modal=document.getElementById('ps-patch-modal'),card=modal.querySelector('.ps-modal-content');
                    // Stress typography only; the production footer owns every
                    // wrapping, width, placement and overflow rule under test.
                    document.documentElement.style.fontSize=${enlarged ? "'20px'" : "''"};
                    card.style.fontSize=${enlarged ? "'20px'" : "''"};
                    ${JSON.stringify(fragmentButtons)}.forEach(id=>document.getElementById(id).style.fontSize=${enlarged ? "'20px'" : "''"});
                    document.getElementById('ps-patch-status').style.fontSize=${enlarged ? "'16px'" : "''"};
                    card.scrollTop=card.scrollHeight;
                })()`);
                const geometry = await evaluate(`(() => {
                    const modal=document.getElementById('ps-patch-modal'),card=modal.querySelector('.ps-modal-content'),status=document.getElementById('ps-patch-status'),actions=modal.querySelector('.ps-patch-actions');
                    const rect=el=>{const r=el.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
                    const content=el=>{const r=el.getBoundingClientRect(),c=getComputedStyle(el),n=key=>parseFloat(c[key])||0;return {
                        left:r.left+n('borderLeftWidth')+n('paddingLeft'),right:r.left+n('borderLeftWidth')+el.clientWidth-n('paddingRight'),
                        top:r.top+n('borderTopWidth')+n('paddingTop'),bottom:r.top+n('borderTopWidth')+el.clientHeight-n('paddingBottom')};};
                    // Native max-content clones measure text + actual font/box
                    // styling without the live row's growth/wrapping constraints.
                    const measure=document.createElement('div');measure.setAttribute('data-fixture-intrinsic','true');
                    measure.style.cssText='position:fixed;left:-10000px;top:0;visibility:hidden;display:flex;align-items:flex-start;width:max-content;max-width:none';modal.appendChild(measure);
                    let buttons;
                    try {buttons=${JSON.stringify(fragmentButtons)}.map(id=>{
                        const el=document.getElementById(id),css=getComputedStyle(el),clone=el.cloneNode(true);clone.removeAttribute('id');
                        for(const [key,value] of Object.entries({display:'inline-block',position:'static',flex:'none',width:'max-content','min-width':'0','max-width':'none',height:'auto','min-height':'0','max-height':'none',margin:'0',transform:'none','white-space':'nowrap',font:css.font,'letter-spacing':css.letterSpacing,'word-spacing':css.wordSpacing,'text-transform':css.textTransform,padding:css.padding,border:css.border,'box-sizing':css.boxSizing}))clone.style.setProperty(key,value,'important');
                        measure.appendChild(clone);const natural=rect(clone);clone.remove();
                        const r=el.getBoundingClientRect(),range=document.createRange();range.selectNodeContents(el);
                        if(!el.disabled)el.focus({preventScroll:true});
                        return {id,...rect(el),natural:{width:natural.width,height:natural.height},content:content(el),
                            textRects:[...range.getClientRects()].map(r=>({left:r.left,right:r.right,top:r.top,bottom:r.bottom})),
                            scrollWidth:el.scrollWidth,clientWidth:el.clientWidth,scrollHeight:el.scrollHeight,clientHeight:el.clientHeight,
                            overflow:css.overflow,textOverflow:css.textOverflow,whiteSpace:css.whiteSpace,
                            visible:css.display!=='none'&&css.visibility!=='hidden',disabled:el.disabled,focusable:document.activeElement===el,
                            hit:el.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)),font:parseFloat(css.fontSize)};
                    });}finally{measure.remove();}
                    const rows=[];for(const button of buttons){const center=button.top+button.height/2;let row=rows.find(row=>Math.abs(row.center-center)<=1);if(!row){row={center,buttons:[]};rows.push(row);}row.buttons.push(button.id);}
                    return {card:rect(card),cardContent:content(card),actions:{...rect(actions),content:content(actions)},table:rect(modal.querySelector('table')),warning:rect(modal.querySelector('.ps-warning-box')),
                        rows,buttons,status:{...rect(status),text:status.textContent},dark:document.documentElement.getAttribute('data-pt-dark'),scrollWidth:card.scrollWidth,clientWidth:card.clientWidth,viewport:innerWidth,measurementClones:modal.querySelectorAll('[data-fixture-intrinsic]').length};
                })()`);
                fragmentGeometry.push({ state, width, enlarged, lateTheme, scheme, ...geometry });
                fs.writeFileSync(path.join(artifacts, 'fragment-footer.json'), JSON.stringify(fragmentGeometry, null, 2));
                const label = `Patch Fragment ${scheme}, ${state}, ${width}px${enlarged ? ', enlarged font' : ''}${lateTheme ? ', late important theme margins' : ''}`;
                const near = (actual, expected, message) => assert.ok(Math.abs(actual - expected) <= 1, label + ': ' + message + ' (' + actual + ' vs ' + expected + ')');
                assert.equal(geometry.dark, String(scheme === 'dark'), label + ': production scheme detection follows the requested fixture mode');
                assert.ok(geometry.card.left >= 0 && geometry.card.right <= geometry.viewport + 1, label + ': card stays within the viewport');
                assert.ok(geometry.scrollWidth <= geometry.clientWidth + 1, label + ': the card has no clipped horizontal content');
                assert.equal(geometry.buttons.length, 5);
                assert.equal(geometry.measurementClones, 0, 'intrinsic probes are removed before assertions/teardown');
                near(geometry.actions.content.left, geometry.cardContent.left, 'actions start at the actual card content edge');
                near(geometry.actions.content.right, geometry.cardContent.right, 'actions span the card content width');
                near(geometry.actions.content.left, geometry.warning.left, 'actions align with the warning outer left');
                near(geometry.actions.content.left, geometry.table.left, 'actions align with the table outer left');
                for (const button of geometry.buttons) {
                    assert.ok(button.visible && button.width > 0 && button.height > 0, label + ': all five actions are rendered, including ' + button.id);
                    assert.ok(button.left >= geometry.card.left && button.right <= geometry.card.right, label + ': button bounds inside the card: ' + JSON.stringify(button));
                    assert.ok(button.top >= geometry.card.top && button.bottom <= geometry.card.bottom, label + ': scrolling the footer into view exposes every action: ' + JSON.stringify(button));
                    assert.equal(button.hit, true, label + ': ' + button.id + ' is not clipped or covered');
                    assert.notEqual(button.textOverflow, 'ellipsis', label + ': button labels are not ellipsized');
                    assert.ok(button.scrollWidth <= button.clientWidth + 1 && button.scrollHeight <= button.clientHeight + 1, label + ': complete label fits the usable button box');
                    assert.ok(button.textRects.length > 0, label + ': the actual label has a rendered text range');
                    for (const text of button.textRects) {
                        assert.ok(text.left >= button.content.left - 1 && text.right <= button.content.right + 1, label + ': label width stays inside button padding');
                        assert.ok(text.top >= button.top - 1 && text.bottom <= button.bottom + 1, label + ': label height is not clipped');
                    }
                    if (state === 'ready') {
                        assert.equal(button.disabled, false, label + ': all five ready controls remain usable');
                        assert.equal(button.focusable, true, label + ': the actual native control accepts keyboard focus');
                    }
                    if (enlarged) {
                        assert.equal(button.font, 20, label + ': enlargement applies to the actual button, not only its parent');
                        const normal = fragmentGeometry.find(run=>run.scheme===scheme&&run.state===state&&run.width===width&&!run.enlarged&&run.lateTheme===lateTheme);
                        if (normal) assert.ok(button.font > normal.buttons.find(value=>value.id===button.id).font + 1, label + ': actual computed button font increased');
                    }
                }
                assert.deepEqual(geometry.rows.flatMap(row=>row.buttons), fragmentButtons, label + ': adaptive rows retain action/Close order');
                for (const row of geometry.rows) {
                    const buttons = row.buttons.map(id=>geometry.buttons.find(button=>button.id===id)), actions = buttons.filter(button=>button.id!=='ps-patch-close');
                    if (actions.length) near(actions[0].left, geometry.actions.content.left, 'first action in every wrapped row is flush left');
                    near(buttons.at(-1).right, geometry.actions.content.right, 'last control in every row fills the right edge');
                    for (let index = 1; index < buttons.length; index++) near(buttons[index].left - buttons[index - 1].right, 8, 'neighbor gap is fixed at 8 CSS px');
                    if (actions.length && buttons.every(button=>button.natural.width <= geometry.actions.width)) {
                        const free = geometry.actions.content.right - geometry.actions.content.left - buttons.reduce((sum,button)=>sum+button.natural.width,0) - 8*(buttons.length-1);
                        for (const button of actions) {
                            const added = button.width - button.natural.width;
                            assert.ok(added >= -1, label + ': intrinsic action text/box width is not shrunk');
                            near(added, free/actions.length, 'all actions in a row share equal added width beyond their own intrinsic text width');
                            if (state === 'ready' && added > 1) grownFragmentActions.add(button.id);
                        }
                    }
                    const close = buttons.find(button=>button.id==='ps-patch-close');
                    if (close) { near(close.width, close.natural.width, 'Close keeps its compact natural width, including an alone wrapped row'); near(close.height, close.natural.height, 'Close retains a compact natural height'); }
                }
                if (lateTheme && state === 'ready') {
                    const baseline = fragmentGeometry.find(run=>run.scheme===scheme&&run.state===state&&run.width===width&&run.enlarged===enlarged&&!run.lateTheme);
                    assert.ok(baseline);
                    for (const button of geometry.buttons) {
                        const original = baseline.buttons.find(value=>value.id===button.id);
                        for (const key of ['left','right','top','bottom']) near(button[key], original[key], 'late important theme margins do not alter Patch alignment/gaps/wrapping');
                    }
                }
                if (geometry.status.text) {
                    assert.ok(geometry.status.top >= Math.max(...geometry.buttons.map(button => button.bottom)) - 1, label + ': status/error text occupies a separate row below all actions');
                    assert.ok(geometry.status.left >= geometry.card.left && geometry.status.right <= geometry.card.right, label + ': long diagnostics wrap within the card');
                }
            };
            const wrapperScope = async lateTheme => {
                await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
                await evaluate("document.documentElement.style.fontSize='';document.getElementById('ps-wrapper-modal').style.display='flex'");
                const scope = await evaluate(`(() => {const modal=document.getElementById('ps-wrapper-modal'),footer=modal.querySelector('.ps-modal-footer'),rect=el=>{const r=el.getBoundingClientRect();return {left:r.left,right:r.right,width:r.width};};return {footer:rect(footer),justify:getComputedStyle(footer).justifyContent,buttons:[...footer.querySelectorAll('.btn')].filter(button=>getComputedStyle(button).display!=='none').map(button=>{const css=getComputedStyle(button);return {id:button.id,...rect(button),grow:css.flexGrow,margins:['marginTop','marginRight','marginBottom','marginLeft'].map(key=>parseFloat(css[key]))};}),lateStyleAfterCommon:!!document.getElementById('fixture-late-footer-margins')&&!!(document.querySelector('link[href^="/common.css"]').compareDocumentPosition(document.getElementById('fixture-late-footer-margins'))&Node.DOCUMENT_POSITION_FOLLOWING)};})()`);
                fragmentScope.push({ lateTheme, ...scope });
                fs.writeFileSync(path.join(artifacts, 'fragment-footer-scope.json'), JSON.stringify(fragmentScope, null, 2));
                assert.equal(scope.justify, 'flex-end', 'untargeted real Wrapper footer retains its flex-end layout');
                assert.equal(scope.buttons.length, 2);
                for (const button of scope.buttons) {
                    assert.equal(button.grow, '0', 'Wrapper controls do not inherit Patch growth');
                    if (lateTheme) assert.deepEqual(button.margins, [4, 9, 6, 13], 'untargeted Wrapper keeps the later theme important margins');
                    else assert.deepEqual(button.margins, [0, 0, 0, 0]);
                }
                assert.ok(scope.buttons[0].left > scope.footer.left + 20, 'untargeted controls stay a compact right-aligned group');
                if (lateTheme) {
                    assert.equal(scope.lateStyleAfterCommon, true, 'the theme margin fixture actually follows common.css');
                    for (const button of scope.buttons) assert.ok(Math.abs(button.width-fragmentScope[0].buttons.find(value=>value.id===button.id).width)<=1, 'untargeted controls retain their natural compact width');
                }
                await escape('ps-wrapper-modal');
            };
            await wrapperScope(false);
            for (const scheme of ['light', 'dark']) for (const width of fragmentWidths) for (const enlarged of [false, true]) await fragmentLayout('ready', width, enlarged, false, scheme);
            await evaluate(`(() => {const style=document.createElement('style');style.id='fixture-late-footer-margins';style.textContent='.ps-modal .ps-modal-footer .btn{margin:4px 9px 6px 13px!important}';document.head.appendChild(style);})()`);
            await wrapperScope(true);
            for (const scheme of ['light', 'dark']) for (const width of fragmentWidths) for (const enlarged of [false, true]) await fragmentLayout('ready', width, enlarged, true, scheme);
            const fragmentError = { error: 'Fixture outbounds read failed: ' + 'long-native-read-diagnostic-'.repeat(8) + '<literal>', details: '<script>literal outbound read stderr</script>\n' + 'complete outbound diagnostics '.repeat(30) };
            const fragmentRead = queueFixtureReply('/copyapi/singbox_outbounds', fragmentError, { hold: true });
            await evaluate('document.getElementById("ps-patch-retry").click()');
            await waitFixture(() => fragmentRead.request, 'Fragment footer loading status');
            for (const scheme of ['light', 'dark']) await fragmentLayout('loading', 390, true, true, scheme);
            fragmentRead.release();
            await wait('document.getElementById("ps-patch-status").textContent.includes("Fixture outbounds read failed")', true);
            assert.equal(await evaluate('document.querySelector("#ps-patch-status pre").textContent'), fragmentError.details);
            assert.equal(await evaluate('document.querySelector("#ps-patch-status pre").childElementCount'), 0);
            for (const scheme of ['light', 'dark']) for (const width of fragmentWidths) for (const enlarged of [false, true]) await fragmentLayout('failed read', width, enlarged, true, scheme);
            assert.deepEqual([...grownFragmentActions].sort(), fragmentButtons.slice(0, 4).sort(), 'all four actions are observed gaining intrinsic-based width');
            assert.ok(fragmentGeometry.some(run=>run.rows.some(row=>row.buttons.length===1&&row.buttons[0]==='ps-patch-close')), 'the matrix actually exercises Close alone on a wrapped row');
            await evaluate('document.querySelector("#ps-patch-status details").open=true');
            for (const scheme of ['light', 'dark']) {
                await fragmentLayout('expanded error', 390, true, true, scheme);
                await screenshot('fragment-footer-mobile-enlarged-' + scheme, 390);
            }
            assert.deepEqual([...new Set(fragmentGeometry.map(run=>run.scheme))].sort(), ['dark', 'light'], 'geometry receipts explicitly cover both production color schemes');
            await escape('ps-patch-modal');
            await evaluate("document.getElementById('fixture-late-footer-margins').remove();document.documentElement.style.fontSize=''");
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
            assert.equal(frontendPosts.length, fragmentPosts, 'Fragment layout/read retries and stale-wrapper presentation send no mutation');
            assert.deepEqual(fixtureProcesses, fragmentProcesses, 'layout checks never change fixture service facts');
            fs.writeFileSync(path.join(artifacts, 'fragment-footer.json'), JSON.stringify(fragmentGeometry, null, 2));
            console.log('PASS native adaptive Patch Fragment: explicit light/dark schemes, two TLS outbounds/all five controls, left/right edge alignment per wrapped row, fixed 8px gaps, equal intrinsic-based added width, natural right-aligned Close including alone rows, unclipped labels at 1440/768/390/320px and actual enlarged button fonts; late important theme margins isolated from Patch and retained by Wrapper; own status/error row and no mutation');

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
            const st1Report = [], st1Posts = frontendPosts.length;
            const observedProcess = { running: true, pid: '456', instance: '456:100' };
            const st1Cases = [
                { name: 'verified root', data: fixtureInitCheck({ process: observedProcess, user: 'root' }), label: 'Init user: root', repair: false },
                ...[53, 5353].map(port => ({ name: 'working non-root port ' + port, data: fixtureInitCheck({ process: observedProcess, uid: 453, port }), label: 'Init user: stubby', repair: true })),
                { name: 'root init but stopped', data: fixtureInitCheck({ process: { running: false }, user: 'root' }), label: 'Init user: root', repair: false },
                { name: 'partial socket read', data: { ...fixtureInitCheck({ process: observedProcess, user: 'root' }), listeners: { state: 'unknown', error: '<script>literal socket diagnostic</script>\n' + 'complete socket details '.repeat(500) } }, label: 'Init user: root', repair: false },
                { name: 'UID unavailable', data: { ...fixtureInitCheck({ process: observedProcess, user: 'root' }), status: 'unknown', runtime: { state: 'unknown', error: 'UID read failed <literal>' }, listeners: { state: 'unknown', error: 'No stable process identity' } }, label: 'Init user: root', repair: false },
                { name: 'legacy bare fixed is not UID proof', data: { status: 'fixed' }, unknown: true, repair: false },
                { name: 'HTTP full body', data: { error: 'Init observation unavailable', details: 'complete native IO detail '.repeat(500), errno: 13 }, status: 503, unknown: true, repair: false }
            ];
            for (const item of st1Cases) {
                fixtureProcesses.stubby = item.data.runtime && item.data.runtime.state === 'stopped' ? { running: false } : { ...observedProcess };
                queueFixtureReply('/copyapi/stubby_init_check', item.data, { status: item.status || 200 });
                await navigateFixture(base + '/copy-form?view=stubby');
                await wait('document.getElementById("ps-config-editor")?.value', fixtureStubbyConfig);
                await wait('document.getElementById("ps-initfix-status").textContent==="Init check: Unknown"||document.getElementById("ps-initfix-status").textContent===' + JSON.stringify(item.label || '__no_label__'), true);
                await wait('document.getElementById("ps-status-text").textContent.startsWith("Running")||document.getElementById("ps-status-text").textContent==="Stopped"', true);
                for (const scheme of ['light', 'dark']) {
                    await evaluate(`document.getElementById('ps-theme-context').setAttribute('data-mode',${JSON.stringify(scheme)})`);
                    await wait('document.documentElement.getAttribute("data-pt-dark")', String(scheme === 'dark'));
                    for (const width of [1440, 768, 390, 320]) for (const enlarged of [false, true]) {
                        await cdp.call('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
                        await evaluate(`['ps-params-btn','ps-initfix-btn','ps-initfix-status'].forEach(id=>document.getElementById(id).style.fontSize=${enlarged ? "'20px'" : "''"})`);
                        const snapshot = await evaluate(`(() => {const label=document.getElementById('ps-initfix-status'),main=document.getElementById('cbi-podkop-tweaker'),card=main.querySelector('.cbi-section'),pre=document.getElementById('ps-initfix-check-details'),toolbar=document.getElementById('ps-initfix-btn').parentElement;return {label:label.textContent,main:main.innerText,facts:document.getElementById('ps-initfix-facts').textContent,details:pre.textContent,literal:pre.childElementCount===0,width:card.clientWidth,scroll:card.scrollWidth,requests:window.fixtureXHR,diagnosticsOnMain:['ps-initfix-facts','ps-initfix-refresh','ps-initfix-check-details'].some(id=>main.contains(document.getElementById(id))),buttons:[...toolbar.querySelectorAll('button')].map(button=>{const r=button.getBoundingClientRect();return {text:button.textContent,font:parseFloat(getComputedStyle(button).fontSize),width:r.width,scroll:button.scrollWidth,client:button.clientWidth};})};})()`);
                        if (item.unknown) assert.equal(snapshot.label, 'Init check: Unknown'); else assert.equal(snapshot.label, item.label);
                        assert.equal(snapshot.literal, true);
                        assert.ok(snapshot.scroll <= snapshot.width + 1, item.name + ': facts/details stay inside the real mobile card');
                        assert.equal(snapshot.diagnosticsOnMain, false, 'no standalone diagnostic block or refresh control on the editor');
                        assert.deepEqual(snapshot.buttons.map(button=>button.text), ['Template', 'Fix Init Script'], 'restore the original two-button toolbar');
                        assert.doesNotMatch(snapshot.main, /Init declaration:|Processes:|effective UID|Listeners observed:|Refresh observations/);
                        assert.equal((snapshot.main.match(/PID 456\b/g)||[]).length, fixtureProcesses.stubby.running ? 1 : 0, 'ordinary service PID appears once, never in a duplicate diagnostic row');
                        for (const button of snapshot.buttons) { assert.ok(button.scroll <= button.client + 1, 'full action label fits'); if (enlarged) assert.equal(button.font, 20); }
                        if (item.data.listeners?.state === 'unknown') assert.ok(snapshot.details.includes('literal socket diagnostic') || snapshot.details.includes('No stable process identity'));
                        if (item.status) { assert.ok(snapshot.details.includes('HTTP 503')); assert.ok(snapshot.details.includes('"errno":13')); assert.ok(snapshot.details.includes(item.data.details)); }
                        if (item.name.startsWith('working non-root')) { assert.doesNotMatch(snapshot.label, /Needs fix|root/); assert.match(snapshot.facts, /effective UID 453/); }
                        assert.equal(snapshot.requests.filter(request => request.url.endsWith('/stubby_init_check')).length, 1, 'one manual page-load observation, no setup polling');
                        if (item.name === 'verified root' && !enlarged && (width === 1440 || width === 390)) await screenshot('stubby-compact-' + scheme + '-' + width, width);
                        await evaluate('document.getElementById("ps-initfix-btn").click()');
                        assert.equal(await evaluate('document.querySelector("#ps-initfix-modal h3").textContent'), 'Fix Init Script');
                        assert.equal(await evaluate('document.getElementById("ps-initfix-apply").textContent'), 'Apply Fix');
                        assert.match(await evaluate('document.getElementById("ps-initfix-modal").innerText'), /changes the user in \/etc\/init\.d\/stubby from stubby to root and requests a Stubby restart/);
                        assert.equal(await evaluate('document.getElementById("ps-initfix-technical").open'), false, 'technical disclosure defaults closed on every opening');
                        // Chromium can keep layout boxes below closed details;
                        // check actual visibility, not the existence of a box.
                        assert.equal(await evaluate('document.getElementById("ps-initfix-facts").checkVisibility()'), false, 'PID/UID/socket details are not visible until explicitly expanded');
                        assert.equal(await evaluate('document.getElementById("ps-initfix-apply").disabled'), !item.repair);
                        if (!item.repair) await evaluate('document.getElementById("ps-initfix-apply").dispatchEvent(new MouseEvent("click",{bubbles:true}))');
                        if (item.name === 'verified root' && scheme === 'dark' && width === 390 && !enlarged) await screenshot('stubby-fix-compact-dialog', width);
                        await evaluate('document.getElementById("ps-initfix-technical").open=true');
                        assert.equal(await evaluate('document.getElementById("ps-initfix-facts").checkVisibility()'), true, 'technical data stays available on demand');
                        const modalFits = await evaluate('document.querySelector("#ps-initfix-modal .ps-modal-content").scrollWidth<=document.querySelector("#ps-initfix-modal .ps-modal-content").clientWidth+1');
                        assert.equal(modalFits, true, 'expanded diagnostics stay contained');
                        await escape('ps-initfix-modal');
                        st1Report.push({ name: item.name, scheme, width, enlarged, label: snapshot.label, facts: snapshot.facts, literal: snapshot.literal, compact: !snapshot.diagnosticsOnMain });
                    }
                }
            }
            assert.equal(frontendPosts.length, st1Posts, 'ST1 observations/forged disabled actions never mutate');
            fixtureProcesses.stubby = { ...observedProcess };
            await navigateFixture(base + '/copy-form?view=stubby');
            await wait('document.getElementById("ps-initfix-status").textContent', 'Init user: stubby');
            queueFixtureReply('/copyapi/stubby_init_check', fixtureInitCheck({ process: { running: false }, user: 'root' }));
            await evaluate('document.getElementById("ps-initfix-btn").click();document.getElementById("ps-initfix-technical").open=true;document.getElementById("ps-initfix-refresh").click()');
            await wait('document.getElementById("ps-initfix-status").textContent', 'Init user: root');
            assert.match(await evaluate('document.getElementById("ps-initfix-facts").textContent'), /Read-only snapshot/);
            await escape('ps-initfix-modal');
            assert.equal(frontendPosts.length, st1Posts, 'explicit snapshot refresh is read-only');
            fs.writeFileSync(path.join(artifacts, 'stubby-st1.json'), JSON.stringify(st1Report, null, 2));
            fixtureProcesses.stubby = originalStubbyProcess;
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
            console.log('PASS compact Stubby: original two-button toolbar, one service PID, no duplicated runtime panel, clear Fix Init Script/Apply Fix action, opt-in technical details, retained typed ST1/root gates and literal complete diagnostics at 320/390/768/1440px with real enlarged fonts in light/dark');
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
                await wait('document.getElementById("ps-initfix-status").textContent', 'Init user: stubby');
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

            await navigateFixture(base + '/copy-form?view=subscriptions');
            await wait('!!document.getElementById("ps-opt-save")', true);
            await waitAutoReplies(1);
            assertHiddenAutoStatus(await autoStatusSnapshot());
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
            const autoBeforeBroken = await autoReplyCount();
            await evaluate('document.getElementById("ps-subs-refresh").click()');
            await waitAutoReplies(autoBeforeBroken + 1);
            const brokenWidget = await autoStatusSnapshot();
            assert.equal(brokenWidget.visible, true);
            for (const label of [/schedule/i, /cron daemon/i, /launcher/i, /WAN/i]) {
                const item = brokenWidget.items.find(item=>label.test(item.text));
                assert.ok(item, 'required broken setup fact remains actionable: ' + label);
                assert.equal(item.color, brokenWidget.colors.warning);
                assert.equal(assertProblemDetails(item, []).summaryColor, brokenWidget.colors.warning);
            }
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false }, sessionId);
            assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true);
            await screenshot('subscriptions-auto-status-mobile', 390);
            await cdp.call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1100, deviceScaleFactor: 1, mobile: false }, sessionId);
            const subscriptionJournal = await exerciseSubscriptionJournal({ schedulerChecks: true });
            fs.writeFileSync(path.join(artifacts, 'subscription-journal-reliability.json'), JSON.stringify(subscriptionJournal, null, 2));
            console.log('PASS native compact journal: legacy/finished mask, complete problem Details, failed/unknown at failed=0, neutral pending, duplicate IDs 1:1, current/open Full Log refresh, stale/IO retention and problem-only setup at 390px');
            const subscriptionMutations = await exerciseSubscriptionMutations();
            fs.writeFileSync(path.join(artifacts, 'subscription-mutations-reliability.json'), JSON.stringify(subscriptionMutations, null, 2));
            console.log('PASS native subscription mutations: compact success/old-new instance proof, typed invalid outcome/unknown uncertainty gates, known journal recording/finalization errors at failed=0, actual dark/light colors and complete raw Details/Copy without replay');
            const autoSetup = await exerciseAutoSetupFailures();
            fs.writeFileSync(path.join(artifacts, 'auto-setup-reliability.json'), JSON.stringify(autoSetup, null, 2));
            console.log('PASS native auto setup: healthy/disabled/WAN-only hidden, required/stale/unknown wiring actionable, full Permission Denied/context with actual colors, completed history excluded, neutral newer pending, malformed/conflicting pending Details, Save Options readback and recovery hides old problems');
            const autoHTTP = await exerciseAutoSetupHTTP();
            fs.writeFileSync(path.join(artifacts, 'auto-setup-http-reliability.json'), JSON.stringify(autoHTTP, null, 2));
            console.log('PASS native setup HTTP: actual 503 JSON error/details/errno, 403 HTML and invalid/HTML 200 retain complete literal bodies and typed colors; once-only render/retry, no disabled claim/mutation and stale HTTP error ignored');
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
                    const id=button.getAttribute('data-pt-copy-for'),details=button.closest('details');
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
                    assert.equal(await evaluate('document.getElementById("ps-initfix-technical").open'), false);
                    await evaluate('document.getElementById("ps-initfix-technical").open=true');
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
            const compactReadError = { error: 'Fixture compact init read failed', details: '<script>literal read output</script>\n' + 'complete compact read diagnostic '.repeat(500), errno: 13 };
            queueFixtureReply('/copyapi/stubby_init_check', compactReadError, { status: 503 });
            const compactPosts = frontendPosts.length;
            await navigateFixture(base + '/copy-form?view=stubby');
            await wait('document.getElementById("ps-initfix-status").textContent', 'Init check: Unknown');
            await evaluate('document.getElementById("ps-initfix-btn").click();document.getElementById("ps-initfix-technical").open=true');
            const compactDiagnostic = await evaluate('document.getElementById("ps-initfix-check-details").textContent');
            assert.ok(compactDiagnostic.includes('HTTP 503') && compactDiagnostic.includes('"errno":13') && compactDiagnostic.includes(compactReadError.details));
            assert.equal(await evaluate('document.getElementById("ps-initfix-check-details").childElementCount'), 0);
            assert.equal(await copy('[data-pt-copy-for="ps-initfix-check-details"]'), compactDiagnostic);
            assert.equal(await evaluate('document.getElementById("ps-initfix-technical").open'), true, 'Copy never toggles technical disclosure');
            await escape('ps-initfix-modal');
            await evaluate('document.getElementById("ps-initfix-btn").click()');
            assert.equal(await evaluate('document.getElementById("ps-initfix-technical").open'), false);
            await escape('ps-initfix-modal');
            assert.equal(frontendPosts.length, compactPosts, 'opening/copying read diagnostics never mutates');
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

            const journalCopies = await exerciseSubscriptionJournal({ copyDisplayed: copy });
            fs.writeFileSync(path.join(artifacts, 'subscription-journal-copy.json'), JSON.stringify(journalCopies, null, 2));
            const mutationCopies = await exerciseSubscriptionMutations({ copyDisplayed: copy });
            fs.writeFileSync(path.join(artifacts, 'subscription-mutations-copy.json'), JSON.stringify(mutationCopies, null, 2));
            const autoSetupCopies = await exerciseAutoSetupFailures();
            fs.writeFileSync(path.join(artifacts, 'auto-setup-copy.json'), JSON.stringify(autoSetupCopies, null, 2));
            const autoHTTPCopies = await exerciseAutoSetupHTTP({ copyDisplayed: copy });
            fs.writeFileSync(path.join(artifacts, 'auto-setup-http-copy.json'), JSON.stringify(autoHTTPCopies, null, 2));
            console.log('PASS native subscription Copy: exact compact/expanded problem recent/full sources and complete mutation diagnostics, current/duplicate/last-good snapshots, DOM/input selection + focus/scroll preserved; intercepted native copy events only');
            console.log('PASS native metadata/journal/auto-setup regressions: warning/error computed colors, exact raw typed/Permission Denied facts, mutation ownership and no automatic replay');
            console.log('PASS native setup HTTP Copy: byte-exact complete source/native setter input, actual LF-canonicalized fallback copy events, dark/light Details, recovery hidden and stale error ignored; no OS clipboard writes');

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
        console.log(copyOnly ? 'Native clipboard checks: PASS (including displayed subscription journal snapshots and IO diagnostics)' : updateOnly ? 'Native Local Update checks: PASS' : diagnosticsOnly ? 'Native Diagnostics checks: PASS (progressive local Run All, errors/deadlines/log export, separate external DNS and Podkop navigation)' : reliabilityOnly ? 'Native reliability checks: PASS (typed autostart, Stubby result/modal/restart proof, Fragment footer geometry, subscription journal, mobile, multipart and scheduling)' : `Native browser theme checks: PASS (${reports.length} scheme/profile scenarios + Argon 3 live modes${themeOnly ? '' : ' + real forms'}; artifacts in ${path.relative(root, artifacts)})`);
    } catch (error) {
        runFailure = error;
        fs.writeFileSync(path.join(artifacts, 'run-failure.json'), JSON.stringify({ error: error.stack }, null, 2));
        throw error;
    } finally {
        for (const release of [...heldFixtureReplies]) release();
        if (cdp) {
            const info = await cdp.call('SystemInfo.getProcessInfo').catch(() => null);
            privateBrowserPids = info ? info.processInfo.map(process => Number(process.id)) : [];
            await cdp.call('Browser.close').catch(() => {}); await cdp.close();
        }
        if (child.exitCode === null) child.kill();
        await browserClosed;
        await new Promise(resolve => server.close(resolve));
        const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
        for (let attempt = 0; attempt < 100 && privateBrowserPids.some(alive); attempt++) await new Promise(resolve => setTimeout(resolve, 50));
        const remainingPids = privateBrowserPids.filter(alive);
        const after = sourceHashes(), stable = JSON.stringify(after) === JSON.stringify(initialSourceHashes);
        fs.writeFileSync(path.join(artifacts, 'source-hashes.json'), JSON.stringify({ before: initialSourceHashes, preflight: preflightHashes, after, stable }, null, 2));
        fs.writeFileSync(path.join(artifacts, 'resource-closure.json'), JSON.stringify({ browserPid: child.pid, browserJoined: true, privateBrowserPids, remainingPids,
            serverClosed: !server.listening, heldReplies: heldFixtureReplies.size, queuedReplies: [...fixtureReplyQueues].filter(([, replies]) => replies.length).map(([endpoint, replies]) => ({ endpoint, count: replies.length })) }, null, 2));
        const closureErrors = [];
        if (remainingPids.length) closureErrors.push(new Error('Private Edge processes still running: ' + remainingPids.join(', ')));
        if (!stable) closureErrors.push(new Error('BLOCKER: production sources changed during this run; results are not final acceptance'));
        if (closureErrors.length) throw new AggregateError([...(runFailure ? [runFailure] : []), ...closureErrors], 'Browser verification failed; see run-failure/source-hashes/resource-closure receipts');
        console.log('Source hashes unchanged; private Edge processes joined, CDP and local server closed; artifacts: ' + path.relative(root, artifacts));
    }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
