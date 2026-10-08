// theme_browser_spec.js | v3.0.0 | 08.10.2026 | Native status color controls and scheme transitions
// node tests/theme_browser_spec.js --browser <installed Chromium/Edge executable>
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

const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/appearance' || url.pathname === '/api/typography') {
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
        for (const [scenario, s, profile] of Object.entries(scenarios).flatMap(([name, settings]) => ['soft', 'contrast'].map(profile => [name, settings, profile]))) {
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
        fs.writeFileSync(path.join(artifacts, 'computed-colors.json'), JSON.stringify(reports, null, 2));
        console.log(`Native browser theme checks: PASS (${reports.length} scheme/profile scenarios + appearance form; screenshots in ROOT/tmp/theme-smoke)`);
    } finally {
        if (cdp) { await cdp.call('Browser.close').catch(() => {}); cdp.close(); }
        child.kill();
        await new Promise(resolve => server.close(resolve));
    }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
