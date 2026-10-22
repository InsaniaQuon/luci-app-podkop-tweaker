/*
LuCI Podkop Tweaker — shared JS helpers (served from /luci-static/resources/podkop-tweaker/)
Requires per-page bootstrap: window.PT = { version, csrf, urls: { appVersion, ... } }
Cache-busted via ?v=<app_version> in templates.
Author: InsaniaQuon
*/
window.PT = window.PT || {};
(function () {
	'use strict';

	var PT = window.PT;

	PT.escapeHtml = function (s) {
		return String(s === undefined || s === null ? '' : s)
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;');
	};

	PT.escapeAttr = function (s) {
		return String(s === undefined || s === null ? '' : s)
			.replace(/&/g, '&amp;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;');
	};

	// Clipboard API needs a secure context. Router HTTP pages use a temporary
	// selected textarea; always restore focus, selection and scroll afterwards.
	PT.copyText = function (text) {
		text = String(text === undefined || text === null ? '' : text);
		function fallback() {
			var area = null, active = document.activeElement, selection = window.getSelection && window.getSelection();
			var ranges = [], start, end, direction, top, left, x = window.scrollX, y = window.scrollY, copied = false;
			try {
				if (selection) for (var i = 0; i < selection.rangeCount; i++) ranges.push(selection.getRangeAt(i).cloneRange());
				if (active) {
					start = active.selectionStart; end = active.selectionEnd; direction = active.selectionDirection;
					top = active.scrollTop; left = active.scrollLeft;
				}
				area = document.createElement('textarea');
				area.className = 'ps-copy-fallback';
				area.readOnly = true;
				area.tabIndex = -1;
				area.value = text;
				document.body.appendChild(area);
				try { area.focus({ preventScroll: true }); } catch (e) { area.focus(); }
				area.select();
				copied = !!document.execCommand('copy');
			} catch (e) {} finally {
				if (area && area.parentNode) area.parentNode.removeChild(area);
				if (selection) {
					selection.removeAllRanges();
					for (var j = 0; j < ranges.length; j++) selection.addRange(ranges[j]);
				}
				// Chromium exposes an input's DOM range separately from its text
				// selection. Restore the text selection last, or addRange resets it.
				if (active && active.focus) {
					try { active.focus({ preventScroll: true }); } catch (e) { active.focus(); }
					if (typeof start === 'number' && active.setSelectionRange) active.setSelectionRange(start, end, direction);
					active.scrollTop = top; active.scrollLeft = left;
				}
				if (window.scrollTo && typeof x === 'number') window.scrollTo(x, y);
			}
			return copied;
		}
		var clipboard = window.navigator && window.navigator.clipboard;
		try {
			if (clipboard && clipboard.writeText) return Promise.resolve(clipboard.writeText(text)).then(function () { return true; }, fallback);
		} catch (e) {}
		return Promise.resolve(fallback());
	};

	PT.copyContent = function (source) {
		if (source.tagName === 'TEXTAREA') return source.value;
		if (source.tagName === 'PRE') return source.textContent;
		// innerText retains log/diff/diagram line breaks and includes all text
		// inside a scrollport. The button itself lives outside this source.
		return typeof source.innerText === 'string' ? source.innerText : source.textContent;
	};

	// An out-of-flow overlay leaves the text frame's full height to its source.
	// Its inner tools stay sticky within that frame during modal scrolling.
	function copyAnchor(source) {
		var panel = source.closest && source.closest('.ps-editor-wrap');
		if (panel) panel.classList.add('ps-copy-editor');
		else {
			if (!source.parentNode) return null;
			panel = document.createElement('div');
			panel.className = 'ps-copy-panel';
			if (source.tagName === 'PRE' || source.classList.contains('ps-diff-body')) panel.classList.add('ps-copy-raised');
			if (source.classList.contains('ps-dns-chain')) panel.classList.add('ps-copy-inset');
			source.parentNode.insertBefore(panel, source);
			panel.appendChild(source);
			source.classList.add('ps-copy-source');
		}
		var overlay = document.createElement('div');
		overlay.className = 'ps-copy-overlay';
		var anchor = document.createElement('div');
		anchor.className = 'ps-copy-tools';
		overlay.appendChild(anchor);
		panel.insertBefore(overlay, panel.firstChild);
		return anchor;
	}

	var COPY_ICONS = {
		copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4"/>',
		done: '<path d="m5 12 4 4L19 6"/>',
		error: '<path d="m6 6 12 12M18 6 6 18"/>'
	};
	PT.addCopyButton = function (source, options) {
		if (!source || source.__ptCopyButton) return source && source.__ptCopyButton;
		options = options || {};
		var anchor = options.anchor || copyAnchor(source);
		if (!anchor) return null;
		var button = document.createElement('button');
		button.type = 'button';
		button.className = 'btn cbi-button ps-copy-btn';
		button.setAttribute('aria-live', 'polite');
		if (source.id) button.setAttribute('data-pt-copy-for', source.id);
		function state(value) {
			var label = value === 'done' ? 'Copied' : value === 'error' ? 'Copy failed; select the text and copy manually' : (options.label || 'Copy all text');
			button.title = label;
			button.setAttribute('aria-label', label);
			button.setAttribute('data-pt-copy-state', value);
			// Only fixed SVG markup is inserted; source text never enters HTML.
			button.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' + COPY_ICONS[value] + '</svg><span class="ps-copy-status">' + PT.escapeHtml(label) + '</span>';
		}
		state('copy');
		var resetTimer;
		// Native touch does not consistently expose :active. This hint belongs
		// only to the button; cancellation/leave never triggers a copy.
		button.addEventListener('pointerdown', function (e) {
			if (!button.disabled && e.isPrimary !== false && e.button === 0) button.setAttribute('data-pt-copy-pressed', 'true');
		});
		['pointerup', 'pointercancel', 'pointerleave', 'lostpointercapture', 'blur'].forEach(function (event) {
			button.addEventListener(event, function () { button.setAttribute('data-pt-copy-pressed', 'false'); });
		});
		button.addEventListener('mousedown', function (e) { e.preventDefault(); });
		button.addEventListener('click', function (e) {
			e.preventDefault();
			e.stopPropagation();
			if (button.disabled) return;
			if (resetTimer) clearTimeout(resetTimer);
			var text = options.getText ? options.getText() : PT.copyContent(source);
			button.disabled = true;
			PT.copyText(text).then(function (ok) {
				button.disabled = false;
				state(ok ? 'done' : 'error');
				resetTimer = setTimeout(function () {
					state('copy');
				}, 2000);
			});
		});
		anchor.appendChild(button);
		source.__ptCopyButton = button;
		return button;
	};

	// Static sources are present before page scripts run; dynamic error details
	// bind explicitly in setErr. Repeated initialization never stacks listeners.
	PT.initCopyButtons = function () {
		var sources = document.querySelectorAll('#cbi-podkop-tweaker textarea, #cbi-podkop-tweaker pre, #cbi-podkop-tweaker .ps-log-viewer-wrap, #cbi-podkop-tweaker .ps-log-viewer-full, #cbi-podkop-tweaker .ps-dns-chain, #cbi-podkop-tweaker .ps-diff-body, .ps-modal textarea, .ps-modal pre, .ps-modal .ps-log-viewer-full, .ps-modal .ps-diff-body');
		for (var i = 0; i < sources.length; i++) PT.addCopyButton(sources[i]);
	};

	// Resolve status roles to CSS variables, so existing messages recolor when
	// the scheme changes. Legacy literals are accepted while callers migrate.
	PT.color = function (role) {
		var tokens = {
			success: '--ps-success', error: '--ps-error', info: '--ps-primary',
			warning: '--ps-warning', dim: '--ps-text-dim', muted: '--ps-text-muted',
			'#4caf50': '--ps-success', '#f44336': '--ps-error', '#2196f3': '--ps-primary',
			'#ff9800': '--ps-warning', '#e67e22': '--ps-warning', '#888': '--ps-text-dim'
		};
		if (Object.prototype.hasOwnProperty.call(tokens, role)) return 'var(' + tokens[role] + ')';
		return role || 'var(--ps-text-dim)';
	};

	PT.checkStale = function () {
		var banner = document.getElementById('ps-stale-banner');
		if (!banner || !PT.version || !(PT.urls && PT.urls.appVersion)) return;
		var xhr = new XMLHttpRequest();
		xhr.open('GET', PT.urls.appVersion);
		xhr.onload = function () {
			try {
				var r = JSON.parse(xhr.responseText);
				if (r.version && r.version !== PT.version) {
					banner.classList.add('ps-stale-visible');
				}
			} catch (e) {}
		};
		xhr.send();
	};

	PT.xhrPost = function (url, params, cb, timeout) {
		var xhr = new XMLHttpRequest();
		var finished = false;
		function finish(value, reason) { if (!finished) { finished = true; cb(value, reason); } }
		xhr.open('POST', url);
		if (timeout) xhr.timeout = timeout;
		xhr.onload = function () { finish(xhr); };
		xhr.onerror = function () { finish(null, 'Network error'); };
		xhr.ontimeout = function () { finish(null, 'Request timed out'); };
		xhr.onabort = function () { finish(null, 'Request aborted'); };
		if (typeof FormData !== 'undefined' && params instanceof FormData) {
			params.append('token', PT.csrf || '');
			// Browser supplies Content-Type with the multipart boundary.
			xhr.send(params);
		} else {
			xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
			xhr.send('token=' + encodeURIComponent(PT.csrf || '') + (params ? '&' + params : ''));
		}
	};

	PT.postJson = function (url, params, cb, timeout) {
		PT.xhrPost(url, params, function (xhr, reason) {
			var data = null, error = null;
			if (xhr) {
				try {
					var parsed = JSON.parse(xhr.responseText);
					if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) data = parsed;
				} catch (e) {}
			}
			if (!xhr) error = { kind: 'transport', message: reason || 'Network error' };
			else if (xhr.status !== 200) error = { kind: 'http', message: data && data.error || 'HTTP error: ' + xhr.status, details: data && data.details || xhr.responseText };
			else if (!data) error = { kind: 'parse', message: 'Invalid response', details: xhr.responseText };
			else if (data.error || data.success === false) error = { kind: 'application', message: data.error || 'Operation failed', details: data.details, applied: data.applied === true,
				phase: data.phase, resume_available: data.resume_available === true, partial: data.partial === true };
			if (error && data) {
				// Retain the whole parsed result, including nested item/restart facts.
				// Callers must not parse the response again or mistake it for success.
				error.data = data;
				if (data.unknown === true) error.unknown = true;
				if (data.applied === true) error.applied = true;
			}
			cb(error ? null : data, error, xhr);
		}, timeout || 120000);
	};

	PT.contentForm = function (content, fields, filename) {
		var form = new FormData();
		form.append('content_file', new Blob([content], { type: 'text/plain;charset=utf-8' }), filename || 'config.txt');
		Object.keys(fields || {}).forEach(function (key) { form.append(key, fields[key]); });
		return form;
	};

	PT.getJson = function (url, cb, timeout) {
		var xhr = new XMLHttpRequest();
		var finished = false;
		function finish(data, status, reason) { if (!finished) { finished = true; cb(data, status, reason); } }
		xhr.open('GET', url);
		xhr.timeout = timeout || 30000;
		xhr.onload = function () {
			var data = null;
			if (xhr.status === 200) {
				try { data = JSON.parse(xhr.responseText); } catch (e) {}
			}
			finish(data, xhr.status, data ? null : 'Invalid response');
		};
		xhr.onerror = function () { finish(null, 0, 'Network error'); };
		xhr.ontimeout = function () { finish(null, 0, 'Request timed out'); };
		xhr.onabort = function () { finish(null, 0, 'Request aborted'); };
		xhr.send();
	};

	// Keep the original facts, or reject them. A missing/error enabled field is
	// unknown, never a false (disabled) autostart observation.
	PT.typedAutostart = function (r) {
		return r && typeof r === 'object' && !Array.isArray(r) && !('error' in r) && r.unknown !== true &&
			(r.success === undefined || r.success === true) && typeof r.enabled === 'boolean' ? r : null;
	};

	PT.newOperationId = function () {
		var bytes = new Uint8Array(16);
		if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(bytes);
		else for (var i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
		return Array.prototype.map.call(bytes, function (n) { return ('0' + n.toString(16)).slice(-2); }).join('');
	};

	PT.waitForRestart = function (url, id, expectedVersion, cb, legacyUrl) {
		var done = false, request = null, retry = null;
		var legacy = false, stable = 0;
		var deadline = setTimeout(function () {
			finish({ message: 'Restart verification timed out. The operation may already be applied; retry verification.' }, null, true);
		}, 60000);
		function cancel() {
			done = true;
			clearTimeout(deadline); clearTimeout(retry);
			if (window.removeEventListener) window.removeEventListener('pagehide', cancel);
			if (request) request.abort();
		}
		function finish(error, data, uncertain) {
			if (done) return;
			cancel(); cb(error, data, uncertain);
		}
		function probe() {
			if (done) return;
			var xhr = new XMLHttpRequest(), settled = false;
			request = xhr;
			var endpoint = legacy ? legacyUrl : url;
			xhr.open('GET', endpoint + (endpoint.indexOf('?') >= 0 ? '&' : '?') + 'id=' + encodeURIComponent(id) + '&_pt=' + Date.now());
			xhr.timeout = 4000;
			function again() { if (settled || done) return; settled = true; request = null; retry = setTimeout(probe, 1000); }
			xhr.onerror = xhr.ontimeout = xhr.onabort = function () { stable = 0; again(); };
			xhr.onload = function () {
				if (settled || done) return;
				var html = xhr.status === 200 && /^\s*(?:<!doctype\s+html|<html)/i.test(xhr.responseText);
				// Older target controllers have no operation-status route. This path
				// is enabled only by a received checked-apply ACK, never response loss.
				if (!legacy && legacyUrl && (xhr.status === 404 || html)) { legacy = true; again(); return; }
				if (xhr.status === 401 || xhr.status === 403 || html) {
					finish({ message: html ? 'LuCI returned an HTML login/error page. Sign in if needed, then retry verification.' : 'LuCI session expired or access denied. Sign in, then retry verification.', details: xhr.responseText }, null, true);
					return;
				}
				var data = null;
				try { data = JSON.parse(xhr.responseText); } catch (e) {}
				if (legacy) {
					stable = xhr.status === 200 && data && data.version === expectedVersion ? stable + 1 : 0;
					if (stable >= 3) { finish(null, { legacy_ready: true, installed_version: data.version }, false); return; }
					again(); return;
				}
				if (xhr.status === 200 && data && data.id === id) {
					if (data.state === 'failed') { finish({ message: data.error || 'Operation failed' }, data, false); return; }
					var expected = data.expected_version || expectedVersion;
					if (data.state === 'applied' && data.restarted === true && data.ready === true && (!expected || data.installed_version === expected)) {
						finish(null, data, false); return;
					}
				}
				again();
			};
			xhr.send();
		}
		if (window.addEventListener) window.addEventListener('pagehide', cancel);
		probe();
		return cancel;
	};

	PT.restartAction = function (cfg) {
		var id = PT.newOperationId();
		var legacyUrl = null;
		var params = (cfg.params ? cfg.params + '&' : '') + 'restart_id=' + id;
		function fail(error, uncertain) {
			PT.setErr(cfg.status, error.message, error.details);
			if (uncertain) {
				var button = document.createElement('button');
				button.type = 'button'; button.className = 'btn cbi-button ps-restart-retry'; button.textContent = 'Retry verification';
				button.addEventListener('click', function () { button.disabled = true; verify(); });
				cfg.status.appendChild(button);
			}
			if (cfg.onFailure) cfg.onFailure(error, uncertain);
		}
		function verify() {
			cfg.status.textContent = 'Waiting for LuCI and operation confirmation...';
			cfg.status.style.color = PT.color('info');
			PT.waitForRestart(cfg.statusUrl || PT.urls.restartStatus, id, cfg.expectedVersion, function (error, data, uncertain) {
				if (error) { fail(error, uncertain); return; }
				cfg.status.textContent = data && data.legacy_ready ? 'Target version responding (legacy verification). Reloading...' : 'Operation confirmed. Reloading...';
				cfg.status.style.color = PT.color('success');
				// A bounded nonce also refreshes equal-version reinstall assets.
				var next = new URL(window.location.href);
				next.searchParams.set('_pt_reload', id);
				if (window.location.replace) window.location.replace(next.href); else window.location.reload();
			}, legacyUrl);
		}
		PT.postJson(cfg.url, params, function (resp, error, xhr) {
			if (error) {
				if (error.applied) fail(error, true);
				else if (error.kind === 'transport' || error.kind === 'parse' || xhr && xhr.status >= 500) verify();
				else fail(error, false);
				return;
			}
			if (resp.success !== true || resp.restart_id !== id) { verify(); return; }
			if (resp.new_version) cfg.expectedVersion = resp.new_version;
			var version = String(resp.new_version || '').match(/^(\d+)\.(\d+)\.(\d+)/);
			if (cfg.target === 'tweaker' && version && (+version[1] < 4 || +version[1] === 4 && +version[2] < 9)) legacyUrl = PT.urls.appVersion;
			verify();
		}, 300000);
		return id;
	};

	var modalEscapeBound = false;
	// All close paths share the same optional cleanup; Esc closes the top overlay.
	// Returns the hide function so callers can close programmatically.
	PT.bindModal = function (modal, closeBtn, onHide) {
		if (modal.__ptModalHide) return modal.__ptModalHide;
		function hide() {
			modal.style.display = 'none';
			if (onHide) onHide();
		}
		modal.__ptModalHide = hide;
		(Array.isArray(closeBtn) ? closeBtn : [closeBtn]).forEach(function (button) {
			if (button) button.addEventListener('click', hide);
		});
		modal.addEventListener('click', function (e) {
			if (e.target === modal) hide();
		});
		if (!modalEscapeBound) {
			modalEscapeBound = true;
			document.addEventListener('keydown', function (e) {
				if (e.defaultPrevented || e.isComposing || (e.key !== 'Escape' && e.key !== 'Esc' && e.keyCode !== 27)) return;
				var modals = document.querySelectorAll('.ps-modal');
				for (var i = modals.length - 1; i >= 0; i--) {
					var current = modals[i];
					var display = window.getComputedStyle ? window.getComputedStyle(current).display : current.style.display;
					if (!current.__ptModalHide || !display || display === 'none') continue;
					e.preventDefault(); e.stopPropagation();
					current.__ptModalHide();
					return;
				}
			});
		}
		return hide;
	};

	// LuCI ui.tabs persists a section index, not a URL fragment. Open its
	// normal same-origin route and select the initialized diagnostic tab by
	// clicking the native link. Bounded best-effort; no script injection.
	PT.openPodkopDiagnostics = function (href) {
		var target;
		try { target = new URL(href, window.location.href); } catch (e) { return false; }
		if (target.origin !== window.location.origin || !/\/admin\/services\/podkop\/?$/.test(target.pathname)) return false;
		target.hash = '';
		var child = window.open(target.href, '_blank');
		if (!child) return false;
		try { child.opener = null; } catch (e) {}
		var observer = null, observedDocument = null, stopped = false;
		function stop() {
			if (stopped) return;
			stopped = true;
			if (observer) observer.disconnect();
			clearInterval(timer);
			clearTimeout(timeout);
			window.removeEventListener('pagehide', stop);
		}
		function select() {
			if (stopped) return;
			try {
				if (child.closed) { stop(); return; }
				if (child.location.href === 'about:blank') return;
				var current = new URL(child.location.href);
				if (current.origin !== target.origin || current.pathname !== target.pathname) { stop(); return; }
				var doc = child.document;
				if (!doc.documentElement) return;
				if (window.MutationObserver && doc !== observedDocument) {
					if (observer) observer.disconnect();
					observedDocument = doc;
					observer = new MutationObserver(select);
					observer.observe(doc.documentElement, { childList: true, subtree: true, attributes: true,
						attributeFilter: ['data-initialized', 'data-tab-active', 'class', 'style'] });
				}
				var tab = doc.querySelector('ul.cbi-tabmenu > li[data-tab="diagnostic"]');
				var group = tab && tab.parentElement.nextElementSibling;
				if (!group || group.getAttribute('data-initialized') !== 'true' || tab.style.display === 'none') return;
				var pane = group.querySelector('[data-tab="diagnostic"]'), link = tab.querySelector('a');
				if (!pane || !link) return;
				if (pane.getAttribute('data-tab-active') !== 'true') link.click();
				if (pane.getAttribute('data-tab-active') === 'true') stop();
			} catch (e) { stop(); }
		}
		var timer = setInterval(select, 200), timeout = setTimeout(stop, 15000);
		window.addEventListener('pagehide', stop);
		select();
		return true;
	};

	// Apply only bounded app-owned values. Status colors do not depend on the
	// profile, and no raw UCI or API value is inserted into a stylesheet.
	var COLOR_ROLES = ['success', 'error', 'warning'];
	var COLOR_SCHEMES = ['light', 'dark'];
	function hexRgb(value) {
		if (typeof value !== 'string' || !/^#[0-9a-f]{6}$/i.test(value)) return null;
		return [1, 3, 5].map(function (offset) { return parseInt(value.substr(offset, 2), 16); });
	}

	PT.colorContrast = function (foreground, background, alpha) {
		var fg = hexRgb(foreground), bg = hexRgb(background);
		if (!fg || !bg) return null;
		function luminance(rgb) {
			var linear = rgb.map(function (value) {
				value /= 255;
				return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
			});
			return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
		}
		function ratio(a, b) {
			var x = luminance(a), y = luminance(b);
			return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
		}
		alpha = Math.max(0, Math.min(1, Number(alpha) || 0));
		var tinted = bg.map(function (value, i) { return value * (1 - alpha) + fg[i] * alpha; });
		return { plain: ratio(fg, bg), tinted: ratio(fg, tinted) };
	};

	PT.applyAppearance = function (settings) {
		settings = settings || {};
		var size = String(settings.mono_font_size || '13');
		var weight = String(settings.mono_font_weight || '400');
		var height = String(settings.mono_line_height || '1.6');
		var clean = {
			profile: settings.profile === 'contrast' ? 'contrast' : 'soft',
			mono_font_size: /^(1[2-8])$/.test(size) ? size : '13',
			mono_font_weight: /^(400|500)$/.test(weight) ? weight : '400',
			mono_line_height: /^1\.[3-8]$/.test(height) ? height : '1.6'
		};
		var root = document.documentElement;
		root.setAttribute('data-pt-profile', clean.profile);
		root.style.setProperty('--ps-mono-size', clean.mono_font_size + 'px');
		root.style.setProperty('--ps-mono-weight', clean.mono_font_weight);
		root.style.setProperty('--ps-mono-line-height', clean.mono_line_height);
		var css = window.getComputedStyle ? window.getComputedStyle(root) : null;
		COLOR_SCHEMES.forEach(function (scheme) {
			COLOR_ROLES.forEach(function (role) {
				var key = 'color_' + role + '_' + scheme;
				var value = settings[key];
				if (!hexRgb(value)) value = css && css.getPropertyValue ? css.getPropertyValue('--ps-default-' + role + '-' + scheme).trim() : '';
				var rgb = hexRgb(value);
				if (!rgb) return;
				clean[key] = value.toLowerCase();
				root.style.setProperty('--ps-' + role + '-' + scheme, clean[key]);
				root.style.setProperty('--ps-' + role + '-' + scheme + '-rgb', rgb.join(','));
			});
		});
		return clean;
	};

	// One source of truth for the app palette. Configuration is supplied by
	// tabs.htm; Argon 3's live mode takes precedence over that render-time snapshot.
	// DOM/CSS detection also supports older Argon headers and versioned assets.
	// Never sample an app panel:
	// its color depends on this detector and would introduce a feedback loop.
	var schemeRefresh = null;
	PT.detectScheme = function () {
		if (schemeRefresh) return schemeRefresh();
		var root = document.documentElement;

		function mediaMatches(media) {
			if (!media || media === 'all') return true;
			return !!(window.matchMedia && window.matchMedia(media).matches);
		}

		function pageIsDark() {
			if (!window.getComputedStyle) return null;
			var main = document.querySelector ? document.querySelector('.main-right') : null;
			var nodes = [main, document.body, root];
			for (var i = 0; i < nodes.length; i++) {
				if (!nodes[i]) continue;
				var rgb = window.getComputedStyle(nodes[i]).backgroundColor.match(/^rgba?\(([^)]+)\)$/);
				if (!rgb) continue;
				var values = rgb[1].split(/[,\s\/]+/).map(Number);
				if (values.length > 3 && values[3] === 0) continue;
				return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722 < 128;
			}
			return null;
		}

		function apply() {
			var context = document.getElementById('ps-theme-context');
			var theme = context ? context.getAttribute('data-theme') : '';
			var mode = context ? context.getAttribute('data-mode') : '';
			var bootstrap = root.getAttribute('data-darkmode');
			var argonMode = root.getAttribute('data-argon-mode');
			var dark = null, source = '';

			if (bootstrap === 'true' || bootstrap === 'false') {
				dark = bootstrap === 'true';
				source = 'bootstrap';
			} else if (argonMode === 'dark' || argonMode === 'light' || argonMode === 'normal') {
				dark = argonMode === 'dark' || argonMode === 'normal' && mediaMatches('(prefers-color-scheme: dark)');
				source = 'argon-mode';
			} else if (theme === 'argon' && (mode === 'dark' || mode === 'light')) {
				dark = mode === 'dark';
				source = 'argon-config';
			}

			var links = document.querySelectorAll('link[rel~="stylesheet"]');
			var hasDarkAsset = false, activeDarkAsset = false;
			for (var i = 0; i < links.length; i++) {
				var link = links[i];
				var href = (link.getAttribute('href') || link.href || '').split(/[?#]/)[0];
				if (/\/argon\/css\/dark(?:\.min)?\.css$/i.test(href)) {
					hasDarkAsset = true;
					if (!link.disabled && mediaMatches(link.getAttribute('media'))) activeDarkAsset = true;
				}
				if (!link.__ptSchemeLoadBound && link.addEventListener) {
					link.__ptSchemeLoadBound = true;
					link.addEventListener('load', apply);
				}
			}
			if (dark === null && hasDarkAsset) {
				dark = activeDarkAsset;
				source = 'argon-stylesheet';
			}
			if (dark === null) {
				dark = pageIsDark();
				source = 'page-colors';
			}
			if (dark === null) {
				dark = theme === 'argon' && mode === 'normal' && mediaMatches('(prefers-color-scheme: dark)');
				source = 'argon-auto';
			}
			var value = dark ? 'true' : 'false';
			if (root.getAttribute('data-pt-dark') !== value) root.setAttribute('data-pt-dark', value);
			root.setAttribute('data-pt-scheme-source', source);
			return !!dark;
		}

		schemeRefresh = apply;
		var initial = apply();
		if (window.matchMedia) {
			var mq = window.matchMedia('(prefers-color-scheme: dark)');
			if (mq.addEventListener) mq.addEventListener('change', apply);
			else if (mq.addListener) mq.addListener(apply);
		}
		if (window.MutationObserver) {
			var observer = new MutationObserver(apply);
			observer.observe(root, { attributes: true, attributeFilter: ['data-darkmode', 'data-argon-mode'] });
			if (document.head) observer.observe(document.head, {
				childList: true, subtree: true, attributes: true,
				attributeFilter: ['href', 'media', 'disabled', 'rel']
			});
			var context = document.getElementById('ps-theme-context');
			if (context) observer.observe(context, { attributes: true, attributeFilter: ['data-theme', 'data-mode'] });
		}
		if (document.addEventListener) document.addEventListener('DOMContentLoaded', apply);
		return initial;
	};

	// Short summary + complete diagnostic output, inserted as text (not HTML).
	PT.setErr = function (el, text, details) {
		if (!el) return;
		var limit = 120;
		text = String(text || 'Unknown error');
		var full = details ? String(details) : text;
		el.style.color = PT.color('error');
		if (!details && text.length <= limit && text.indexOf('\n') === -1) {
			el.textContent = text;
			return;
		}
		var head = text.substring(0, limit);
		if (text.length > limit) {
			var cut = head.lastIndexOf(' ');
			if (cut > limit * 0.6) head = head.substring(0, cut);
			head += '…';
		}
		el.innerHTML = '';
		el.style.whiteSpace = 'normal';
		var d = document.createElement('details');
		d.className = 'ps-err-details';
		var s = document.createElement('summary');
		s.textContent = head + ' — Show details';
		var pre = document.createElement('pre');
		pre.textContent = full;
		d.appendChild(s);
		d.appendChild(pre);
		el.appendChild(d);
		var bodyAnchor = copyAnchor(pre);
		var copy = PT.addCopyButton(pre, { anchor: s, label: 'Copy complete error details' });
		d.addEventListener('toggle', function () {
			var focused = document.activeElement === copy;
			(d.open ? bodyAnchor : s).appendChild(copy);
			if (focused) copy.focus({ preventScroll: true });
		});
	};

	var appearanceContext = document.getElementById('ps-theme-context');
	var initialAppearance = appearanceContext ? {
		profile: appearanceContext.getAttribute('data-profile'),
		mono_font_size: appearanceContext.getAttribute('data-mono-size'),
		mono_font_weight: appearanceContext.getAttribute('data-mono-weight'),
		mono_line_height: appearanceContext.getAttribute('data-mono-line-height')
	} : {};
	if (appearanceContext) COLOR_SCHEMES.forEach(function (scheme) {
		COLOR_ROLES.forEach(function (role) {
			initialAppearance['color_' + role + '_' + scheme] = appearanceContext.getAttribute('data-color-' + role + '-' + scheme);
		});
	});
	PT.applyAppearance(initialAppearance);
	PT.detectScheme();
	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', PT.initCopyButtons);
	else PT.initCopyButtons();

	PT.downloadJson = function (filename, obj) {
		var blob = new Blob([JSON.stringify(obj, null, 2)], { type: 'application/json' });
		var url = URL.createObjectURL(blob);
		var a = document.createElement('a');
		a.href = url;
		a.download = filename;
		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
		setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
	};

	PT.statusWatcher = function (statusUrl, dotEl, textEl, toggleBtn) {
		var pollTimer = null, deadline = null, generation = 0, readSequence = 0;
		var busy = false, polling = false, current = { known: false, running: null };

		function instance(value) {
			return typeof value === 'string' && /^[1-9]\d*:\d+$/.test(value) ? value : null;
		}

		function render() {
			if (dotEl) dotEl.className = 'ps-status-dot ' + (!current.known ? 'checking' : current.running ? 'running' : 'stopped');
			if (textEl) {
				textEl.textContent = !current.known ? 'Unknown' : current.running ? ('Running' + (current.pid ? ' (PID ' + current.pid + ')' : '')) : 'Stopped';
				textEl.title = current.error || (current.running && !current.instance ? 'Process identity unavailable; running alone does not confirm a restart.' : '');
				textEl.style.color = PT.color(!current.known ? 'warning' : current.running ? 'success' : 'error');
			}
			if (toggleBtn) {
				toggleBtn.textContent = !current.known ? 'Start / Stop' : current.running ? 'Stop' : 'Start';
				toggleBtn.style.display = 'inline-block';
				toggleBtn.disabled = busy || polling || !current.known;
			}
		}

		function update(running, pid, identity) {
			++readSequence;
			current = { known: typeof running === 'boolean', running: typeof running === 'boolean' ? running : null,
				pid: pid || null, instance: instance(identity) };
			render();
		}

		function fetchStatus(cb) {
			var sequence = ++readSequence;
			PT.getJson(statusUrl, function (r, status, reason) {
				var valid = r && typeof r === 'object' && !Array.isArray(r) && !('error' in r) && r.unknown !== true && (r.success === undefined || r.success === true) && typeof r.running === 'boolean';
				var pid = valid && r.pid != null ? String(r.pid) : null;
				if (pid !== null && !/^[1-9]\d*$/.test(pid)) valid = false;
				var identity = valid ? instance(r.instance) : null;
				if (valid && r.instance != null && (!identity || pid && identity.split(':')[0] !== pid)) valid = false;
				if (valid && !r.running && (pid || identity)) valid = false;
				var state = valid ? { known: true, running: r.running, pid: pid, instance: r.identity_error ? null : identity,
					error: typeof r.identity_error === 'string' ? r.identity_error : null } : {
					known: false, running: null, error: r && typeof r.error === 'string' && r.error || (status && status !== 200 ? 'Service status HTTP error: ' + status : reason || 'Invalid service status response'),
					details: r && typeof r.details === 'string' ? r.details : null
				};
				cb(state, sequence === readSequence);
			}, 4000);
		}

		// The first two callbacks retain their old signature. The optional third
		// argument is the restart ACK, not a status cached before the mutation.
		// Old callers without that evidence finish unverified through onTimeout.
		// Both callbacks receive {confirmed,known,running,instance,reason,message}.
		// Known absence needs previous_running=false, previous_identity_known=true
		// and no previous_instance; unknown-before is never promoted to absence.
		function poll(onSuccess, onTimeout, context) {
			clearTimeout(pollTimer); clearTimeout(deadline);
			var ownGeneration = ++generation, attempts = typeof context === 'number' ? context : 0;
			var meta = context && typeof context === 'object' ? context : {};
			var previous = instance(meta.previous_instance);
			var previousKnown = meta.verification_required === true && meta.previous_identity_known === true && meta.unknown !== true && meta.success !== false && !('error' in meta);
			var absentBefore = previousKnown && meta.previous_running === false && !meta.previous_instance;
			var runningBefore = previousKnown && meta.previous_running === true && previous;
			polling = true;
			++readSequence; // A pre-mutation refresh cannot replace this observation.
			current = { known: false, running: null };
			render();

			function finish(confirmed) {
				if (ownGeneration !== generation || !polling) return;
				clearTimeout(pollTimer); clearTimeout(deadline);
				pollTimer = deadline = null;
				polling = false;
				++readSequence;
				var result = { confirmed: confirmed, known: current.known, running: current.running,
					pid: current.pid, instance: current.instance, error: current.error, details: current.details };
				result.reason = confirmed ? 'new_instance' : !current.known ? 'status_unknown' : !current.running ? 'not_running' :
					!previousKnown || !absentBefore && !runningBefore ? 'previous_unknown' : !current.instance ? 'identity_unknown' : 'same_instance';
				result.message = confirmed ? 'A new service instance is running.' : !current.known ? 'Service status is unknown; restart is unconfirmed.' :
					!current.running ? 'The service is not running at the latest check; restart is unconfirmed.' : 'Service is running, but restart is unconfirmed.';
				render();
				if (confirmed) { if (onSuccess) onSuccess(result); }
				else if (onTimeout) onTimeout(result);
			}

			function next() {
				if (attempts >= 8) { finish(false); return; }
				pollTimer = setTimeout(function () {
					fetchStatus(function (state, latest) {
						if (ownGeneration !== generation || !polling || !latest) return;
						current = state; render();
						if (state.known && state.running && state.instance && (absentBefore || runningBefore && state.instance !== previous)) { finish(true); return; }
						attempts++; next();
					});
				}, 2000);
			}
			deadline = setTimeout(function () { finish(false); }, 30000);
			next();
		}

		return {
			update: update,
			refresh: function () {
				if (polling) return;
				fetchStatus(function (state, latest) { if (latest) { current = state; render(); } });
			},
			poll: poll,
			action: function () { return !busy && !polling && current.known ? current.running ? 'stop' : 'start' : null; },
			setBusy: function (value) { busy = !!value; render(); }
		};
	};

	PT.errorReporter = function (errorBtn, errorModal, errorDetails, errorClose, onPush) {
		var lastError = null;
		var errorTimer = null;
		var TTL = 600000;

		PT.bindModal(errorModal, errorClose);

		function push(shortMsg, fullDetails) {
			var ts = new Date();
			var t = [ts.getHours(), ts.getMinutes(), ts.getSeconds()].map(function (v) {
				return String(v).padStart(2, '0');
			}).join(':');
			lastError = '[' + t + '] ' + (fullDetails || shortMsg);
			errorBtn.style.display = 'inline-block';
			if (errorTimer) clearTimeout(errorTimer);
			errorTimer = setTimeout(function () {
				lastError = null;
				errorBtn.style.display = 'none';
			}, TTL);
			if (onPush) onPush();
		}

		errorBtn.addEventListener('click', function () {
			if (!lastError) return;
			errorDetails.textContent = lastError;
			errorModal.style.display = 'flex';
		});

		return { push: push };
	};

	PT._diffRows = function (oldText, newText) {
		var oldLines = oldText.split('\n');
		var newLines = newText.split('\n');
		var rows = [];
		var added = 0, removed = 0;
		var MAX_CELLS = 4000000;

		function sameRow(num, text) { rows.push({ t: 'same', num: num, text: text }); }
		function delRow(num, text) { removed++; rows.push({ t: 'del', num: num, text: text }); }
		function addRow(num, text) { added++; rows.push({ t: 'add', num: num, text: text }); }

		var pre = 0;
		while (pre < oldLines.length && pre < newLines.length && oldLines[pre] === newLines[pre]) pre++;
		var endOld = oldLines.length, endNew = newLines.length;
		while (endOld > pre && endNew > pre && oldLines[endOld - 1] === newLines[endNew - 1]) { endOld--; endNew--; }

		for (var p = 0; p < pre; p++) sameRow(p + 1, oldLines[p]);

		var n = endOld - pre, m = endNew - pre;
		var i, j;

		if (n === 0 || m === 0 || n * m > MAX_CELLS) {
			for (i = 0; i < n; i++) delRow(pre + i + 1, oldLines[pre + i]);
			for (j = 0; j < m; j++) addRow(pre + j + 1, newLines[pre + j]);
		} else {
			var a = oldLines.slice(pre, endOld);
			var b = newLines.slice(pre, endNew);
			var lcs = [];
			for (i = 0; i <= n; i++) lcs.push(new Array(m + 1));
			for (i = n - 1; i >= 0; i--) {
				for (j = m - 1; j >= 0; j--) {
					if (a[i] === b[j]) lcs[i][j] = 1 + (lcs[i + 1][j + 1] || 0);
					else {
						var down = lcs[i + 1][j] || 0;
						var right = lcs[i][j + 1] || 0;
						lcs[i][j] = down >= right ? down : right;
					}
				}
			}
			i = 0; j = 0;
			var ops = [];
			while (i < n && j < m) {
				if (a[i] === b[j]) { ops.push('='); i++; j++; }
				else if ((lcs[i + 1][j] || 0) >= (lcs[i][j + 1] || 0)) { ops.push('-'); i++; }
				else { ops.push('+'); j++; }
			}
			while (i < n) { ops.push('-'); i++; }
			while (j < m) { ops.push('+'); j++; }

			i = 0; j = 0;
			for (var q = 0; q < ops.length; q++) {
				var op = ops[q];
				if (op === '=') { sameRow(pre + j + 1, b[j]); i++; j++; }
				else if (op === '-') { delRow(pre + i + 1, a[i]); i++; }
				else { addRow(pre + j + 1, b[j]); j++; }
			}
		}

		for (var s2 = endNew; s2 < newLines.length; s2++) sameRow(s2 + 1, newLines[s2]);

		return { rows: rows, added: added, removed: removed, total: newLines.length };
	};

	PT._renderRows = function (rows, collapsed) {
		function lineHtml(r) {
			if (r.t === 'same') return '<div class="ps-diff-line ps-diff-same"><span class="ps-diff-num">' + r.num + '</span> ' + PT.escapeHtml(r.text) + '</div>';
			if (r.t === 'del') return '<div class="ps-diff-line ps-diff-del"><span class="ps-diff-num">' + r.num + '</span><span class="ps-diff-mark">-</span> ' + PT.escapeHtml(r.text) + '</div>';
			return '<div class="ps-diff-line ps-diff-add"><span class="ps-diff-num">' + r.num + '</span><span class="ps-diff-mark">+</span> ' + PT.escapeHtml(r.text) + '</div>';
		}
		function skipHtml(from, to) {
			var count = to - from + 1;
			return '<div class="ps-diff-skip">⋯ ' + count + ' unchanged (lines ' + from + '–' + to + ')</div>';
		}

		var out = [];
		var i = 0, len = rows.length;
		while (i < len) {
			if (!collapsed || rows[i].t !== 'same') { out.push(lineHtml(rows[i])); i++; continue; }
			var start = i;
			while (i < len && rows[i].t === 'same') i++;
			var run = i - start;
			var keepHead = (start === 0) ? 0 : 2;
			var keepTail = (i === len) ? 0 : 2;
			if (run < 7 || run < keepHead + keepTail + 3) {
				for (var k = start; k < start + run; k++) out.push(lineHtml(rows[k]));
			} else {
				for (var k2 = start; k2 < start + keepHead; k2++) out.push(lineHtml(rows[k2]));
				out.push(skipHtml(rows[start + keepHead].num, rows[start + run - 1 - keepTail].num));
				for (var k3 = start + run - keepTail; k3 < start + run; k3++) out.push(lineHtml(rows[k3]));
			}
		}
		return out.join('');
	};

	PT.editorPage = function (cfg) {
		var g = function (id) { return document.getElementById(id); };
		var editor = g('ps-config-editor');
		var lineNums = g('ps-line-numbers');
		var saveBtn = g('ps-config-save');
		var undoBtn = g('ps-config-undo');
		var diffBtn = g('ps-config-diff');
		var rollbackBtn = g('ps-rollback-btn');
		var statusEl = g('ps-config-status');
		var statusDot = g('ps-status-dot');
		var statusText = g('ps-status-text');
		var toggleBtn = g('ps-toggle-btn');

		var t = cfg.texts;
		var originalContent = '';
		var isDirty = false;
		var readReady = false;
		var readSequence = 0;
		var savePending = false;
		var togglePending = false;
		var mutationUnknown = false;
		var serviceNotice = null;
		var errorLineNo = -1;

		function setStatus(text, color) {
			statusEl.textContent = text;
			statusEl.style.color = PT.color(color);
		}

		var errors = PT.errorReporter(g('ps-error-btn'), g('ps-error-modal'),
			g('ps-error-details'), g('ps-error-close'), function () {
				setStatus('Error', '#f44336');
			});

		function pushError(shortMsg, fullDetails) { errors.push(shortMsg, fullDetails); }

		function updateLineNumbers() {
			var count = editor.value.split('\n').length;
			var nums = [];
			for (var i = 1; i <= count; i++) {
				if (i === errorLineNo) {
					nums.push('<span style="color:var(--ps-error);font-weight:700;">\u25B6 ' + i + '</span>');
				} else {
					nums.push(i);
				}
			}
			lineNums.innerHTML = nums.join('\n');
		}

		function highlightErrorLine(lineNo) {
			errorLineNo = lineNo;
			updateLineNumbers();
			var lineHeight = editor.scrollHeight / editor.value.split('\n').length;
			editor.scrollTop = Math.max(0, (lineNo - 5) * lineHeight);
			lineNums.scrollTop = editor.scrollTop;
		}

		function clearErrorLine() {
			if (errorLineNo === -1) return;
			errorLineNo = -1;
			updateLineNumbers();
		}

		editor.addEventListener('scroll', function () {
			lineNums.scrollTop = editor.scrollTop;
		});

		var watcher = PT.statusWatcher(cfg.urls.status, statusDot, statusText,
			cfg.urls.toggle ? toggleBtn : null);

		function serviceBusy(value) {
			if (watcher.setBusy) watcher.setBusy(value || mutationUnknown);
			if (value && watcher.update) watcher.update(null);
		}

		if (cfg.urls.toggle && toggleBtn) {
			toggleBtn.addEventListener('click', function () {
				var action = watcher.action ? watcher.action() : null;
				if (savePending || togglePending || mutationUnknown || !action) return;
				togglePending = true;
				serviceBusy(true);
				toggleBtn.disabled = true;
				toggleBtn.textContent = action === 'stop' ? 'Stopping...' : 'Starting...';
				PT.postJson(cfg.urls.toggle, 'action=' + action, function (resp, error, xhr) {
					togglePending = false;
					if (error && (error.unknown || error.kind === 'transport' || error.kind === 'parse' || error.kind === 'http' && xhr && xhr.status >= 500 || error.message === 'Internal error') || !error && (resp.success !== true || resp.unknown === true)) {
						mutationUnknown = true;
						++readSequence;
						editor.disabled = false;
						readReady = false;
						restoreDirtyButtons();
					}
					serviceBusy(false);
					if (error || resp.success !== true || mutationUnknown) {
						pushError('Service command failed', error ? error.message + (error.details ? '\n\n' + error.details : '') : 'Invalid service command response');
						serviceNotice = { message: mutationUnknown ? 'Service command result unknown. Reload the config before another mutation.' : 'Service command failed or is unverified. Check service status.', role: 'error' };
						setStatus(serviceNotice.message, serviceNotice.role);
						watcher.refresh(); return;
					}
					setTimeout(watcher.refresh, cfg.toggleDelay || 1000);
				});
			});
		}

		if (cfg.urls.autostart) {
			var autostartBtn = g('ps-autostart-btn');
			var autostartEnabled = null, autostartBusy = false, autostartSequence = 0;

			function renderAutostart() {
				autostartBtn.textContent = autostartEnabled === null ? 'Autostart: Unknown' : autostartEnabled ? 'Autostart: ON' : 'Autostart: OFF';
				autostartBtn.style.display = 'inline-block';
				autostartBtn.disabled = autostartBusy || autostartEnabled === null;
			}

			function autostartErrorText(error) {
				return error.message + (error.details ? '\n\n' + error.details : '');
			}

			function checkAutostart(operation) {
				var sequence = ++autostartSequence;
				autostartBusy = true;
				autostartEnabled = null;
				autostartBtn.title = 'Checking autostart state...';
				renderAutostart();
				PT.getJson(cfg.urls.autostart, function (r, status, reason) {
					if (sequence !== autostartSequence) return;
					var valid = status === 200 && PT.typedAutostart(r), problems = [], summary = '';
					autostartBusy = false;
					autostartEnabled = valid ? r.enabled : null;
					renderAutostart();
					if (operation && operation.error) {
						summary = operation.unknown ? 'Autostart update result unknown' : 'Autostart update failed';
						problems.push('Update: ' + autostartErrorText(operation.error));
					}
					if (!valid) {
						var message = r && typeof r.error === 'string' && r.error || (status && status !== 200 ? 'HTTP error: ' + status : reason || 'Invalid autostart response');
						var details = r && typeof r.details === 'string' ? r.details : '';
						problems.push((operation ? 'Readback: ' : 'Read: ') + message + (details ? '\n\n' + details : ''));
						summary = summary ? summary + '; readback failed' : operation ? 'Autostart update acknowledged; readback failed' : 'Autostart read failed';
					} else if (operation && !operation.error && r.enabled !== operation.expected) {
						summary = 'Autostart readback did not match the requested state';
						problems.push('Expected autostart ' + (operation.expected ? 'ON' : 'OFF') + ', but read back ' + (r.enabled ? 'ON' : 'OFF') + '.');
					}
					autostartBtn.title = summary || (valid ? (r.enabled ? 'Enabled at boot' : 'Disabled at boot') : 'Autostart state unknown');
					if (!valid) autostartBtn.title += '. Reload the page to retry the read.';
					if (problems.length) {
						pushError(summary, summary + '\n\n' + problems.join('\n\n'));
						setStatus(summary, 'error');
					}
				}, 30000);
			}

			autostartBtn.addEventListener('click', function () {
				if (autostartBusy || typeof autostartEnabled !== 'boolean' || !cfg.urls.autostartToggle) return;
				var expected = !autostartEnabled, sequence = ++autostartSequence;
				autostartBusy = true;
				autostartEnabled = null;
				autostartBtn.title = 'Updating autostart...';
				renderAutostart();
				PT.postJson(cfg.urls.autostartToggle, 'action=' + (expected ? 'enable' : 'disable'), function (resp, error, xhr) {
					if (sequence !== autostartSequence) return;
					if (!error && (!PT.typedAutostart(resp) || resp.success !== true || resp.enabled !== expected)) {
						error = { message: 'Invalid autostart update response', details: xhr && xhr.responseText, unknown: true };
					}
					// A failed command can still have changed the boot links. Read facts
					// separately, retaining the POST error and never replaying the POST.
					checkAutostart({ expected: expected, error: error, unknown: error && (error.unknown === true || error.kind === 'transport' || error.kind === 'parse' ||
						error.kind === 'http' && xhr && xhr.status >= 500 || error.message === 'Internal error') });
				}, 30000);
			});

			checkAutostart();
		}

		function loadConfig(options) {
			if (savePending) return;
			var sequence = ++readSequence;
			readReady = false;
			restoreDirtyButtons();
			setStatus('Loading...', '#888');
			editor.disabled = true;
			var xhr = new XMLHttpRequest();
			var finished = false;
			function finish(error, details) {
				if (finished) return;
				finished = true;
				if (sequence !== readSequence) return;
				editor.disabled = false;
				if (error) {
					restoreDirtyButtons();
					pushError('Failed to load config', 'Failed to load config: ' + error + (details ? '\n\n' + details : ''));
					setStatus('Failed to load: ' + error, '#f44336');
					if (options && options.onComplete) options.onComplete(error);
					return;
				}
				originalContent = xhr.responseText;
				if (!options || !options.preserveDraft) editor.value = originalContent;
				isDirty = editor.value !== originalContent;
				readReady = true;
				mutationUnknown = false;
				serviceBusy(togglePending || savePending);
				serviceNotice = null;
				restoreDirtyButtons();
				updateLineNumbers();
				setStatus(isDirty ? 'Loaded — unsaved changes remain' : 'Loaded', isDirty ? 'warning' : 'success');
				if (options && options.onComplete) options.onComplete(null);
			}
			xhr.open('GET', cfg.urls.read);
			xhr.timeout = 30000;
			xhr.onload = function () {
				var content = xhr.responseText || '';
				var contentType = xhr.getResponseHeader ? xhr.getResponseHeader('Content-Type') || '' : '';
				var html = /^\s*(?:<!doctype\s+html\b|<(?:html|head|body|form)\b)/i.test(content) || /^\s*(?:text\/html|application\/xhtml\+xml)(?:\s*;|\s*$)/i.test(contentType);
				var loginError = 'LuCI returned an HTML login/error page. Sign in if needed, then reload the config.';
				if (xhr.status !== 200) {
					var data = null;
					try { data = JSON.parse(content); } catch (e) {}
					var message = data && typeof data.error === 'string' && data.error;
					if (!message) message = html ? loginError : (xhr.status === 401 || xhr.status === 403) ? 'LuCI session expired or access denied. Sign in, then reload the config.' : 'HTTP error: ' + xhr.status;
					var details = data && typeof data.details === 'string' ? data.details : content;
					finish(message, 'HTTP ' + xhr.status + (details ? '\n' + details : ''));
				} else if (html) {
					finish(loginError, 'HTTP 200\n' + content);
				} else if (!/\S/.test(content)) {
					finish('Config response is empty or whitespace-only', 'HTTP 200');
				} else {
					finish();
				}
			};
			xhr.onerror = function () { finish('Network error', 'Failed to connect to server'); };
			xhr.ontimeout = function () { finish('Request timed out', 'Config read did not complete within 30 seconds.'); };
			xhr.onabort = function () { finish('Request aborted'); };
			xhr.send();
		}

		function restoreDirtyButtons() {
			saveBtn.disabled = savePending || !readReady || !isDirty;
			diffBtn.disabled = savePending || !readReady || !isDirty;
			undoBtn.disabled = savePending || !readReady;
			rollbackBtn.disabled = savePending || togglePending || mutationUnknown;
		}

		function markSaved(snapshot) {
			originalContent = snapshot;
			isDirty = editor.value !== originalContent;
			restoreDirtyButtons();
		}

		function finishSave(message, role) {
			savePending = false;
			serviceBusy(false);
			serviceNotice = role === 'success' ? null : { message: message, role: role };
			restoreDirtyButtons();
			setStatus(isDirty ? message + ' — unsaved changes remain' : message, role === 'error' ? 'error' : isDirty ? 'warning' : role);
		}

		function responseDetails(resp) {
			return (typeof resp.error === 'string' ? resp.error : 'Operation failed') + (typeof resp.details === 'string' ? '\n\n' + resp.details : '');
		}

		function unknownResponse(resp, xhr) {
			return resp.unknown === true || resp.error === 'Internal error' || xhr.status >= 500 && typeof resp.success !== 'boolean' && typeof resp.applied !== 'boolean';
		}

		function unverified(result, prefix) {
			var state = result && result.known === true;
			var message = state && result.running === false ? 'The service is not running at the latest check; restart is unconfirmed.' :
				state && result.running === true ? 'Service is running, but restart is unconfirmed.' : 'Service status is unknown; restart is unconfirmed.';
			return prefix + ' ' + message;
		}

		function restartDetails(result, meta) {
			var details = unverified(result, 'Disk changes were applied.');
			if (result && result.instance) details += '\nCurrent instance: ' + result.instance;
			if (meta && meta.previous_instance) details += '\nPrevious instance: ' + meta.previous_instance;
			if (!meta || meta.verification_required !== true || meta.previous_identity_known !== true) details += '\nPrevious service identity/absence was not established. A running process alone cannot confirm this restart.';
			if (result && result.error) details += '\n' + result.error;
			if (result && result.details) details += '\n\n' + result.details;
			return details + '\nCheck service status and logs. No mutation was retried automatically.';
		}

		function doSave() {
			if (savePending || togglePending || mutationUnknown || !readReady || !isDirty) return;
			var snapshot = editor.value;
			savePending = true;
			serviceNotice = null;
			serviceBusy(true);
			undoBtn.disabled = true;
			saveBtn.disabled = true;
			diffBtn.disabled = true;
			rollbackBtn.style.display = 'none';
			saveBtn.textContent = 'Saving...';
			editor.disabled = true;
			setStatus(t.saving, '#2196f3');

			PT.xhrPost(cfg.urls.save, PT.contentForm(snapshot), function (xhr, reason) {
				var resp = null;
				function failedVerification(result) {
					pushError('Restart unconfirmed', restartDetails(result, resp));
					finishSave(unverified(result, 'Config saved to disk.'), result && result.known && result.running === false ? 'error' : 'warning');
					rollbackBtn.style.display = 'inline-block';
				}
				editor.disabled = false;
				saveBtn.textContent = 'Save Changes';
				if (!xhr) {
					mutationUnknown = true;
					readReady = false;
					pushError('Save result unknown', (reason || 'Network error') + '. Reload the config to verify the disk state before saving again.');
					finishSave('Save result unknown. Reload the config to verify before saving again.', 'error');
					watcher.refresh();
					return;
				}
				try {
					resp = JSON.parse(xhr.responseText);
					if (!resp || typeof resp !== 'object' || Array.isArray(resp)) throw new Error('Invalid save response');
					if (unknownResponse(resp, xhr)) {
						if (resp.applied === true) markSaved(snapshot);
						mutationUnknown = true;
						readReady = false;
						pushError('Save finishing unknown', responseDetails(resp));
						finishSave(resp.applied === true ? 'Config saved to disk; finishing result unknown. Reload the config to verify before another mutation.' :
							'Save result unknown. Reload the config to verify before another mutation.', 'error');
						watcher.refresh();
					} else if (resp.applied === true && (xhr.status !== 200 || resp.error || resp.success !== true)) {
						markSaved(snapshot);
						pushError('Config saved; service unverified', responseDetails(resp));
						finishSave('Config saved to disk, but restart failed or is unverified. Check service status and logs.', 'error');
						rollbackBtn.style.display = 'inline-block';
						watcher.refresh();
					} else if (xhr.status === 200 && !resp.error && resp.success === true && resp.restarting === true) {
						markSaved(snapshot);
						setStatus(t.restarting, '#2196f3');
						watcher.poll(
							function (result) {
								if (result && result.confirmed === true) finishSave(t.saved, 'success');
								else failedVerification(result);
							},
							failedVerification,
							resp
						);
					} else if (xhr.status === 200 && !resp.error && resp.success === true && resp.unchanged === true) {
						markSaved(snapshot);
						finishSave(t.unchanged, 'success');
						watcher.refresh();
					} else if (xhr.status === 200 && !resp.error && resp.success === true) {
						markSaved(snapshot);
						failedVerification(null);
					} else {
						if (!resp.error && resp.success !== false) throw new Error('Invalid save response');
						var err = cfg.extractError ? cfg.extractError(resp) : null;
						if (err && err.line) highlightErrorLine(err.line);
						pushError('Save failed', responseDetails(resp));
						finishSave('Save failed: ' + (resp.error || 'Operation failed'), 'error');
						watcher.refresh();
					}
				} catch (e) {
					mutationUnknown = true;
					readReady = false;
					pushError('Save result unknown', 'Invalid response (HTTP ' + xhr.status + '):\n' + (xhr.responseText || '') + '\nReload the config to verify the disk state before saving again.');
					finishSave('Save result unknown. Reload the config to verify before saving again.', 'error');
					watcher.refresh();
				}
			}, 120000);
		}

		saveBtn.addEventListener('click', function () {
			if (isDirty) doSave();
		});

		document.addEventListener('keydown', function (e) {
			if ((e.ctrlKey || e.metaKey) && e.key === 's') {
				e.preventDefault();
				if (readReady && isDirty && !saveBtn.disabled) doSave();
			}
		});

		editor.addEventListener('input', function () {
			isDirty = (editor.value !== originalContent);
			restoreDirtyButtons();
			clearErrorLine();
			updateLineNumbers();
			if (!readReady || savePending) return;
			if (serviceNotice) {
				setStatus(serviceNotice.message + (isDirty ? ' — unsaved changes remain' : ''), serviceNotice.role);
				return;
			}
			setStatus(isDirty ? 'Unsaved changes' : 'Loaded', isDirty ? '#ff9800' : '#4caf50');
		});

		editor.addEventListener('keydown', function (e) {
			if (e.key === 'Tab') {
				e.preventDefault();
				var s = editor.selectionStart, end = editor.selectionEnd;
				editor.value = editor.value.substring(0, s) + '\t' + editor.value.substring(end);
				editor.selectionStart = editor.selectionEnd = s + 1;
				editor.dispatchEvent(new Event('input'));
			}
		});

		undoBtn.addEventListener('click', function () {
			if (savePending || !readReady || !isDirty) return;
			if (!confirm('Discard unsaved changes?')) return;
			editor.value = originalContent;
			isDirty = false;
			saveBtn.disabled = true;
			diffBtn.disabled = true;
			updateLineNumbers();
			setStatus(serviceNotice ? serviceNotice.message : 'Loaded', serviceNotice ? serviceNotice.role : 'success');
		});

		rollbackBtn.addEventListener('click', function () {
			if (savePending || togglePending || mutationUnknown || !cfg.urls.rollback) return;
			var draft = editor.value, preserveDraft = isDirty;
			savePending = true;
			++readSequence;
			editor.disabled = false;
			serviceBusy(true);
			restoreDirtyButtons();
			rollbackBtn.style.display = 'none';
			setStatus('Rolling back...', '#2196f3');

			function finishRollback(message, role, applied) {
				savePending = false;
				serviceBusy(false);
				if (applied) {
					loadConfig({ preserveDraft: preserveDraft || editor.value !== draft, onComplete: function (error) {
						if (!error) finishSave(message, role);
						else {
							serviceNotice = { message: message + ' Config read failed: ' + error + '. Reload the config to verify the disk baseline.', role: 'error' };
							setStatus(serviceNotice.message, serviceNotice.role);
						}
					} });
				} else finishSave(message, role);
			}

			PT.xhrPost(cfg.urls.rollback, '', function (xhr, reason) {
				var resp = null;
				function failedVerification(result) {
					pushError('Rollback restart unconfirmed', restartDetails(result, resp));
					finishRollback(unverified(result, 'Config restored to disk.'), result && result.known && result.running === false ? 'error' : 'warning', true);
				}
				if (!xhr) {
					mutationUnknown = true;
					readReady = false;
					pushError('Rollback result unknown', (reason || 'Network error') + '. Reload the config to verify the disk state.');
					finishRollback('Rollback result unknown. Reload the config to verify.', 'error', false);
					watcher.refresh();
					return;
				}
				try {
					resp = JSON.parse(xhr.responseText);
					if (!resp || typeof resp !== 'object' || Array.isArray(resp)) throw new Error('Invalid rollback response');
					if (unknownResponse(resp, xhr)) {
						mutationUnknown = true;
						readReady = false;
						pushError('Rollback finishing unknown', responseDetails(resp));
						finishRollback(resp.applied === true ? 'Config restored to disk; finishing result unknown. Reload the config to verify the baseline.' :
							'Rollback result unknown. Reload the config to verify the disk state.', 'error', false);
						watcher.refresh();
					} else if (resp.applied === true && (xhr.status !== 200 || resp.error || resp.success !== true)) {
						pushError('Rollback applied; service unverified', responseDetails(resp));
						finishRollback('Config restored to disk, but restart failed or is unverified. Check service status and logs.', 'error', true);
						watcher.refresh();
					} else if (xhr.status === 200 && !resp.error && resp.success === true) {
						setStatus('Rolled back. Restarting...', '#2196f3');
						watcher.poll(
							function (result) {
								if (result && result.confirmed === true) finishRollback('Config restored. A new service instance is running.', 'success', true);
								else failedVerification(result);
							},
							failedVerification,
							resp
						);
					} else {
						if (!resp.error && resp.success !== false) throw new Error('Invalid rollback response');
						pushError('Rollback failed', responseDetails(resp));
						finishRollback('Rollback failed: ' + (resp.error || 'Operation failed'), 'error', false);
						watcher.refresh();
					}
				} catch (e) {
					mutationUnknown = true;
					readReady = false;
					pushError('Rollback result unknown', 'Invalid response (HTTP ' + xhr.status + '):\n' + (xhr.responseText || ''));
					finishRollback('Rollback result unknown. Reload the config to verify.', 'error', false);
					watcher.refresh();
				}
			}, 120000);
		});

		var diffToggleWrap = document.createElement('label');
		diffToggleWrap.className = 'ps-diff-toggle';
		diffToggleWrap.innerHTML = '<input type="checkbox" checked> Only changed';
		var diffToggle = diffToggleWrap.firstChild;
		g('ps-diff-stats').parentNode.insertBefore(diffToggleWrap, g('ps-diff-stats').nextSibling);

		var diffCache = { old: null, cur: null, rows: null, added: 0, removed: 0, total: 0 };

		function renderDiffPreview() {
			if (diffCache.old !== originalContent || diffCache.cur !== editor.value) {
				var d = PT._diffRows(originalContent, editor.value);
				diffCache = { old: originalContent, cur: editor.value, rows: d.rows, added: d.added, removed: d.removed, total: d.total };
			}
			g('ps-diff-stats').textContent = diffCache.added + ' added, ' + diffCache.removed + ' removed (' + diffCache.total + ' lines total)';
			g('ps-diff-body').innerHTML = PT._renderRows(diffCache.rows, diffToggle.checked);
		}

		diffBtn.addEventListener('click', function () {
			if (savePending || !readReady || !isDirty) return;
			renderDiffPreview();
			g('ps-diff-modal').style.display = 'flex';
		});

		diffToggle.addEventListener('change', function () {
			if (g('ps-diff-modal').style.display !== 'none') renderDiffPreview();
		});

		PT.bindModal(g('ps-diff-modal'), g('ps-diff-close'));

		window.addEventListener('beforeunload', function (e) {
			if (isDirty) { e.preventDefault(); e.returnValue = ''; }
		});

		watcher.refresh();
		loadConfig();

		return {
			loadConfig: loadConfig,
			refreshStatus: watcher.refresh
		};
	};
})();
