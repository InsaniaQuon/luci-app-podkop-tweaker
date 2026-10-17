// frontend_theme_spec.js | v3.0.0 | 08.10.2026 | Status customization, tints and contrast metrics
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repo = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.js'), 'utf8');
const css = fs.readFileSync(path.join(repo, 'www/luci-static/resources/podkop-tweaker/common.css'), 'utf8');
const cssDefaults = Object.fromEntries([...css.matchAll(/(--ps-default-[\w-]+):\s*(#[\da-f]{6})/gi)].map(m => [m[1], m[2]]));

function run(options = {}) {
    const attrs = options.bootstrap === undefined ? {} : { 'data-darkmode': String(options.bootstrap) };
    if (options.argonMode !== undefined) attrs['data-argon-mode'] = options.argonMode;
    const observers = [];
    const stats = { callbacks: 0, mediaListeners: 0, loadListeners: 0, readyListeners: 0 };
    // Queue only mutations observable through the registered target/options.
    // Indiscriminate callbacks would hide missing attributeFilter entries and
    // would never expose feedback from the app's own data-pt-* writes.
    function notify(record) {
        for (const observer of observers) {
            if (observer.targets.some(({ target, options }) => {
                let node = record.target;
                while (node && node !== target && options.subtree) node = node.parentNode;
                return node === target && (record.type === 'childList' ? options.childList :
                    options.attributes && (!options.attributeFilter || options.attributeFilter.includes(record.attributeName)));
            })) observer.records.push(record);
        }
    }
    function flush() {
        let rounds = 0;
        while (observers.some(observer => observer.records.length)) {
            assert.ok(++rounds <= 20, 'theme observer must settle without data-pt-* feedback');
            for (const observer of observers) {
                if (!observer.records.length) continue;
                const records = observer.records.splice(0);
                stats.callbacks++;
                observer.fn(records, observer);
            }
        }
    }
    function element(attributes, parentNode) {
        return {
            parentNode,
            getAttribute: key => attributes[key] ?? null,
            setAttribute(key, value) {
                attributes[key] = String(value);
                notify({ type: 'attributes', target: this, attributeName: key });
            },
            removeAttribute(key) {
                if (!Object.hasOwn(attributes, key)) return;
                delete attributes[key];
                notify({ type: 'attributes', target: this, attributeName: key });
            }
        };
    }
    const style = { setProperty(key, value) { this[key] = value; } };
    const root = Object.assign(element(attrs), { style });
    const head = element({}, root), body = element({}, root);
    const meta = { 'data-theme': options.theme || '', 'data-mode': options.mode || '', ...(options.appearance || {}) };
    const context = element(meta, body);
    function makeLink(values) {
        const attributes = { rel: 'stylesheet', ...values };
        if (!attributes.disabled) delete attributes.disabled;
        const link = element(attributes, head);
        link.addEventListener = (event, fn) => { stats.loadListeners++; link[event] = fn; };
        Object.defineProperty(link, 'disabled', {
            get: () => Object.hasOwn(attributes, 'disabled'),
            set: value => value ? link.setAttribute('disabled', '') : link.removeAttribute('disabled')
        });
        return link;
    }
    const links = (options.links || []).map(makeLink);
    const state = { darkOS: !!options.darkOS, background: options.background || 'rgb(244, 245, 247)' };
    const mq = { matches: state.darkOS, listeners: [], addListener(fn) { stats.mediaListeners++; this.listeners.push(fn); } };
    if (!options.legacyMedia) mq.addEventListener = (event, fn) => mq.addListener(fn);
    class Observer {
        constructor(fn) { this.fn = fn; this.targets = []; this.records = []; observers.push(this); }
        observe(target, options) {
            this.targets = this.targets.filter(entry => entry.target !== target);
            this.targets.push({ target, options });
        }
    }
    const document = {
        documentElement: root, body, head,
        getElementById: id => id === 'ps-theme-context' && !options.noContext ? context : null,
        querySelectorAll: selector => selector === 'link[rel~="stylesheet"]' ? links.filter(link => link.getAttribute('rel').split(/\s+/).includes('stylesheet')) : [],
        querySelector: () => null,
        addEventListener(event) { if (event === 'DOMContentLoaded') stats.readyListeners++; }
    };
    const window = {
        PT: {}, MutationObserver: Observer,
        getComputedStyle: () => ({ backgroundColor: state.background, getPropertyValue: key => cssDefaults[key] || '' }),
        matchMedia(query) {
            if (query === '(prefers-color-scheme: dark)') { mq.matches = state.darkOS; return mq; }
            return { matches: query === 'all' };
        }
    };
    vm.runInNewContext(source, { window, document, MutationObserver: Observer });
    flush();
    return {
        attrs, style, links, stats, observers, PT: window.PT,
        os(dark) { state.darkOS = dark; mq.matches = dark; mq.listeners.forEach(fn => fn()); flush(); },
        rootAttr(key, value) { if (value === null) root.removeAttribute(key); else root.setAttribute(key, value); flush(); },
        bootstrap(dark) { this.rootAttr('data-darkmode', dark); },
        argon(mode) { this.rootAttr('data-argon-mode', mode); },
        mode(mode) { context.setAttribute('data-mode', mode); flush(); },
        theme(theme) { context.setAttribute('data-theme', theme); flush(); },
        addLink(values) { const link = makeLink(values); links.push(link); notify({ type: 'childList', target: head }); flush(); return link; },
        changed: flush
    };
}

let checks = 0;
function expect(options, dark, source) {
    const page = run(options);
    assert.equal(page.attrs['data-pt-dark'], String(dark));
    assert.equal(page.attrs['data-pt-scheme-source'], source);
    checks++;
    return page;
}

expect({ theme: 'argon', mode: 'dark', darkOS: false }, true, 'argon-config');
expect({ theme: 'argon', mode: 'light', darkOS: true }, false, 'argon-config');
const auto = expect({
    theme: 'argon', mode: 'normal', darkOS: true,
    links: [{ href: '/luci-static/argon/css/dark.css?v=2.4.8#cache', media: '(prefers-color-scheme: dark)' }]
}, true, 'argon-stylesheet');
auto.os(false);
assert.equal(auto.attrs['data-pt-dark'], 'false');
auto.os(true);
assert.equal(auto.attrs['data-pt-dark'], 'true');
checks += 2;
expect({ links: [{ href: 'http://router/luci-static/argon/css/dark.css?v=2.4.7' }] }, true, 'argon-stylesheet');
expect({ darkOS: true, links: [{ href: '/luci-static/argon/css/dark.css', media: '(prefers-color-scheme: dark)', disabled: true }] }, false, 'argon-stylesheet');
expect({ background: 'rgb(30, 30, 30)' }, true, 'page-colors'); // legacy inline dark CSS
expect({ background: 'rgb(255, 255, 255)', darkOS: true }, false, 'page-colors');
expect({ bootstrap: true, darkOS: false }, true, 'bootstrap');
const bootstrap = expect({ bootstrap: false, darkOS: true }, false, 'bootstrap');
bootstrap.bootstrap(true);
assert.equal(bootstrap.attrs['data-pt-dark'], 'true');
checks++;
const forced = run({ theme: 'argon', mode: 'light', darkOS: true });
forced.mode('dark');
assert.equal(forced.attrs['data-pt-dark'], 'true');
checks++;
const dynamic = run({ links: [{ href: '/luci-static/argon/css/dark.css', disabled: true }] });
dynamic.links[0].disabled = false;
dynamic.changed();
assert.equal(dynamic.attrs['data-pt-dark'], 'true');
checks++;

// The live Argon 3 marker overrides the server snapshot and stale legacy CSS,
// including normal mode when the page background still has the old palette.
expect({ theme: 'argon', mode: 'light', argonMode: 'dark' }, true, 'argon-mode');
expect({ theme: 'argon', mode: 'dark', argonMode: 'light', darkOS: true,
    links: [{ href: '/luci-static/argon/css/dark.css' }], background: 'rgb(30, 30, 30)' }, false, 'argon-mode');
expect({ theme: 'argon', mode: 'dark', argonMode: 'normal', background: 'rgb(30, 30, 30)' }, false, 'argon-mode');
expect({ theme: 'argon', mode: 'light', argonMode: 'normal', darkOS: true }, true, 'argon-mode');
expect({ noContext: true, argonMode: 'dark' }, true, 'argon-mode');
expect({ theme: 'bootstrap', argonMode: 'dark' }, true, 'argon-mode');
for (const argonMode of ['', 'Dark', 'LIGHT', 'auto', ' dark', 'dark ', 'normal\n', 'true', 'false', 'dark;light']) {
    expect({ theme: 'argon', mode: 'light', argonMode, darkOS: true }, false, 'argon-config');
    expect({ theme: 'argon', mode: 'dark', argonMode }, true, 'argon-config');
    expect({ argonMode }, false, 'page-colors');
}
expect({ argonMode: 'invalid', links: [{ href: '/luci-static/argon/css/dark.min.css?v=2.4.4' }] }, true, 'argon-stylesheet');
const live = expect({ theme: 'argon', mode: 'dark', argonMode: 'light', darkOS: true }, false, 'argon-mode');
function scheme(page, dark, source, message) {
    assert.equal(page.attrs['data-pt-dark'], String(dark), message);
    assert.equal(page.attrs['data-pt-scheme-source'], source, message);
    checks++;
}
live.argon('dark');
scheme(live, true, 'argon-mode', 'the root attribute mutation must actually reach its observer');
live.os(false);
scheme(live, true, 'argon-mode', 'forced dark ignores a light OS');
live.os(true);
scheme(live, true, 'argon-mode');
live.argon('light');
live.os(false);
live.os(true);
scheme(live, false, 'argon-mode', 'forced light ignores a dark OS');
live.argon('normal');
scheme(live, true, 'argon-mode');
live.os(false);
scheme(live, false, 'argon-mode', 'normal follows OS changes despite stale forced-dark context');
live.mode('light');
live.os(true);
scheme(live, true, 'argon-mode', 'changing the server snapshot cannot override the live mode');
live.theme('');
scheme(live, true, 'argon-mode', 'the live marker works without an Argon server marker');
live.argon('invalid');
scheme(live, false, 'page-colors', 'a malformed marker restores legacy detection');
live.theme('argon');
live.mode('dark');
live.argon('light');
live.argon(null);
scheme(live, true, 'argon-config', 'removing the live marker restores the server snapshot');
live.argon('normal');
live.bootstrap(false);
scheme(live, false, 'bootstrap', 'explicit Bootstrap mode retains priority');
live.argon('dark');
scheme(live, false, 'bootstrap');
live.bootstrap(true);
scheme(live, true, 'bootstrap');
live.bootstrap('invalid');
scheme(live, true, 'argon-mode', 'malformed Bootstrap flags cannot mask a valid Argon mode');
live.bootstrap(null);
scheme(live, true, 'argon-mode');
const legacyMedia = expect({ argonMode: 'normal', legacyMedia: true }, false, 'argon-mode');
legacyMedia.os(true);
scheme(legacyMedia, true, 'argon-mode', 'older matchMedia addListener remains supported');

// Idempotent detection registers one observer/listener set. App-owned root
// attributes and unrelated mutations must not schedule a refresh at all.
const before = { ...live.stats, observers: live.observers.length };
for (let i = 0; i < 3; i++) assert.equal(live.PT.detectScheme(), true);
live.changed();
assert.deepEqual({ ...live.stats, observers: live.observers.length }, before);
for (const [key, value] of Object.entries({ 'data-pt-dark': 'false', 'data-pt-scheme-source': 'test', 'data-pt-profile': 'contrast', class: 'unrelated' })) {
    live.rootAttr(key, value);
    assert.equal(live.stats.callbacks, before.callbacks, key + ' must be excluded from theme observation');
    checks++;
}
assert.equal(live.PT.detectScheme(), true);
scheme(live, true, 'argon-mode');
checks++;

// Legacy head-subtree signals must be observed through the same realistic
// delivery path: disabled, href, media, rel, inserted links and stylesheet load.
dynamic.links[0].setAttribute('media', '(prefers-color-scheme: dark)');
dynamic.changed();
scheme(dynamic, false, 'argon-stylesheet');
dynamic.links[0].setAttribute('media', 'all');
dynamic.changed();
scheme(dynamic, true, 'argon-stylesheet');
dynamic.links[0].setAttribute('href', '/luci-static/argon/css/cascade.css');
dynamic.changed();
scheme(dynamic, false, 'page-colors');
dynamic.links[0].setAttribute('href', '/luci-static/argon/css/dark.css?v=2.4.4');
dynamic.links[0].setAttribute('rel', 'alternate');
dynamic.changed();
scheme(dynamic, false, 'page-colors');
dynamic.links[0].setAttribute('rel', 'stylesheet');
dynamic.changed();
scheme(dynamic, true, 'argon-stylesheet');
const inserted = run();
const link = inserted.addLink({ href: '/luci-static/argon/css/dark.css?late=1' });
scheme(inserted, true, 'argon-stylesheet', 'head childList changes must discover new stylesheets');
assert.equal(inserted.stats.loadListeners, 1);
inserted.PT.detectScheme();
assert.equal(inserted.stats.loadListeners, 1, 'stylesheet load handlers are not duplicated');
inserted.rootAttr('data-pt-dark', 'false');
link.load();
scheme(inserted, true, 'argon-stylesheet', 'stylesheet load still refreshes detection');
assert.equal(dynamic.PT.color('success'), 'var(--ps-success)');
assert.equal(dynamic.PT.color('#888'), 'var(--ps-text-dim)');

const appearance = run({ appearance: { 'data-profile': 'contrast', 'data-mono-size': '18', 'data-mono-weight': '500', 'data-mono-line-height': '1.8' } });
assert.equal(appearance.attrs['data-pt-profile'], 'contrast');
assert.equal(appearance.style['--ps-mono-size'], '18px');
assert.equal(appearance.style['--ps-mono-weight'], '500');
assert.equal(appearance.style['--ps-mono-line-height'], '1.8');
appearance.PT.applyAppearance({ profile: 'bad', mono_font_size: '14; color:red', mono_font_weight: '900', mono_line_height: 'NaN' });
assert.equal(appearance.attrs['data-pt-profile'], 'soft');
assert.equal(appearance.style['--ps-mono-size'], '13px');
assert.equal(appearance.style['--ps-mono-weight'], '400');
assert.equal(appearance.style['--ps-mono-line-height'], '1.6');
checks += 8;

const custom = appearance.PT.applyAppearance({ profile: 'contrast', color_success_dark: '#12AB34', color_error_light: '#ffffff', color_warning_dark: '#ABCDEF' });
assert.equal(custom.color_success_dark, '#12ab34');
assert.equal(appearance.style['--ps-success-dark'], '#12ab34');
assert.equal(appearance.style['--ps-success-dark-rgb'], '18,171,52');
assert.equal(appearance.style['--ps-error-light'], '#ffffff', 'custom low-contrast colors must be applied exactly');
assert.equal(appearance.style['--ps-warning-dark-rgb'], '171,205,239');
appearance.PT.applyAppearance({ ...custom, profile: 'soft' });
assert.equal(appearance.style['--ps-success-dark'], '#12ab34', 'profile changes must keep the selected status colors');
appearance.PT.applyAppearance({ color_success_dark: 'url(x)', color_error_light: '#000000;}' });
assert.equal(appearance.style['--ps-success-dark'], cssDefaults['--ps-default-success-dark']);
assert.equal(appearance.style['--ps-error-light'], cssDefaults['--ps-default-error-light']);
assert.equal(appearance.PT.colorContrast('#000000', '#ffffff', 0).plain, 21);
assert.equal(appearance.PT.colorContrast('#ffffff', '#ffffff', 0).plain, 1);
assert.equal(appearance.PT.colorContrast('url(x)', '#ffffff', 0), null);
const bright = appearance.PT.colorContrast('#00ff00', '#303a49', 0.1);
assert.ok(bright.plain > 8.3 && bright.plain < 8.5);
assert.ok(bright.tinted < bright.plain && bright.tinted > 4.5);
checks += 13;

const lua = fs.readFileSync(path.join(repo, 'usr/lib/lua/podkop-tweaker/appearance.lua'), 'utf8');
const luaColors = [...lua.matchAll(/color_(success|error|warning)_(light|dark)\s*=\s*"(#[\da-f]{6})"/gi)];
const uci = fs.readFileSync(path.join(repo, 'etc/config/podkop-tweaker'), 'utf8');
assert.equal(luaColors.length, 6);
for (const [, role, scheme, value] of luaColors) {
    assert.equal(value, cssDefaults[`--ps-default-${role}-${scheme}`], 'Lua and first-paint CSS defaults must match');
    assert.equal(value, uci.match(new RegExp(`option color_${role}_${scheme} '(#[\\da-f]{6})'`, 'i'))[1], 'first-install UCI defaults must match Lua and CSS');
    checks++;
}
const selectedLight = { success: '#00be00', error: '#ff0000', warning: '#ff8c42' };
for (const [role, value] of Object.entries(selectedLight)) {
    assert.equal(cssDefaults[`--ps-default-${role}-light`], value, 'light status defaults must retain the user-selected colors exactly');
    checks++;
}

// Ordinary text and dark statuses retain their contrast gate. Light statuses use
// the exact user-selected preset; their plain/tinted ratios remain informative.
function palette(block, inherited = {}) {
    const values = { ...inherited, ...Object.fromEntries([...block.matchAll(/(--ps-[\w-]+):\s*([^;]+);/g)].map(m => [m[1], m[2].trim()])) };
    function resolve(key) {
        const alias = String(values[key]).match(/^var\((--ps-[\w-]+)\)$/);
        return alias ? resolve(alias[1]) : values[key];
    }
    return Object.fromEntries(Object.keys(values).map(key => [key, resolve(key)]));
}
function luminance(hex) {
    const rgb = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255).map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}
function contrast(a, b) { const x = luminance(a), y = luminance(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
const lightBlock = css.match(/:root\s*\{([^}]+)\}/)[1];
const darkBlock = css.match(/:root\[data-pt-dark="true"\]\s*\{([^}]+)\}/)[1];
const light = palette(lightBlock);
const dark = palette(darkBlock, light);
const lightContrast = palette(css.match(/:root\[data-pt-profile="contrast"\]\s*\{([^}]+)\}/)[1], light);
const darkContrast = palette(css.match(/:root\[data-pt-dark="true"\]\[data-pt-profile="contrast"\]\s*\{([^}]+)\}/)[1], dark);
const rgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
const hex = values => '#' + values.map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
for (const [mode, colors] of Object.entries({ light, dark, lightContrast, darkContrast })) {
    for (const fg of ['--ps-text', '--ps-text-muted', '--ps-text-dim', '--ps-success', '--ps-error', '--ps-warning', '--ps-primary']) {
        for (const bg of ['--ps-bg', '--ps-bg-alt', '--ps-bg-inset', '--ps-editor-bg']) {
            const ratio = contrast(colors[fg], colors[bg]);
            const selectedStatus = mode.startsWith('light') && ['--ps-success', '--ps-error', '--ps-warning'].includes(fg);
            if (selectedStatus) {
                assert.equal(colors[fg], selectedLight[fg.slice('--ps-'.length)]);
                assert.ok(Number.isFinite(ratio) && ratio >= 1);
            } else assert.ok(ratio >= 4.5, `${mode}: ${fg} on ${bg} is ${ratio.toFixed(2)}:1, needs 4.5:1`);
            checks++;
        }
    }
    assert.ok(contrast(colors['--ps-on-primary'], colors['--ps-primary-fill']) >= 4.5);
    assert.ok(contrast(colors['--ps-border-strong'], colors['--ps-bg-inset']) >= 3);
    assert.notEqual(colors['--ps-bg'], colors['--ps-bg-alt']);
    assert.notEqual(colors['--ps-bg'], colors['--ps-editor-bg'] === colors['--ps-bg'] ? colors['--ps-bg-inset'] : colors['--ps-editor-bg']);
    for (const role of ['success', 'error', 'warning']) {
        const alpha = Number(colors[`--ps-${role}-${mode.startsWith('dark') ? 'dark' : 'light'}-alpha`]);
        const foreground = rgb(colors['--ps-' + role]);
        for (const bg of ['--ps-bg', '--ps-bg-alt', '--ps-bg-inset', '--ps-editor-bg']) {
            const tinted = hex(rgb(colors[bg]).map((value, i) => value * (1 - alpha) + foreground[i] * alpha));
            const ratio = contrast(colors['--ps-' + role], tinted);
            if (mode.startsWith('light')) {
                assert.equal(colors['--ps-' + role], selectedLight[role]);
                assert.ok(Number.isFinite(ratio) && ratio >= 1);
            } else assert.ok(ratio >= 4.5, `${mode}: ${role} on tinted ${bg} must remain readable`);
            checks++;
        }
    }
    // Do not allow muted gray/pink or nearly-black status replacements.
    const green = rgb(colors['--ps-success']), red = rgb(colors['--ps-error']);
    assert.ok(green[1] > green[0] * 2 && green[1] > green[2] + 40, `${mode}: success must be saturated green`);
    assert.ok(red[0] > red[1] + 60 && red[0] > red[2] + 60, `${mode}: error must be saturated red`);
}
for (const role of ['success', 'error', 'warning']) {
    assert.equal(light['--ps-' + role], lightContrast['--ps-' + role]);
    assert.equal(dark['--ps-' + role], darkContrast['--ps-' + role]);
}
console.log(`Theme regressions: PASS (${checks} scheme/contrast checks)`);
