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

	PT.xhrPost = function (url, params, cb) {
		var xhr = new XMLHttpRequest();
		xhr.open('POST', url);
		xhr.onload = function () { cb(xhr); };
		xhr.onerror = function () { cb(null); };
		if (typeof FormData !== 'undefined' && params instanceof FormData) {
			params.append('token', PT.csrf || '');
			// Browser supplies Content-Type with the multipart boundary.
			xhr.send(params);
		} else {
			xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
			xhr.send('token=' + encodeURIComponent(PT.csrf || '') + (params ? '&' + params : ''));
		}
	};

	PT.getJson = function (url, cb) {
		var xhr = new XMLHttpRequest();
		xhr.open('GET', url);
		xhr.onload = function () {
			if (xhr.status === 200) {
				try { cb(JSON.parse(xhr.responseText), xhr.status); return; } catch (e) {}
			}
			cb(null, xhr.status);
		};
		xhr.onerror = function () { cb(null, 0); };
		xhr.send();
	};

	// Wire the standard modal close behavior: close button + backdrop click.
	// Returns the hide function so callers can close programmatically.
	PT.bindModal = function (modal, closeBtn) {
		function hide() { modal.style.display = 'none'; }
		if (closeBtn) closeBtn.addEventListener('click', hide);
		modal.addEventListener('click', function (e) {
			if (e.target === modal) hide();
		});
		return hide;
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
	// tabs.htm; DOM/CSS detection also supports older Argon headers and themes
	// whose assets have cache-busting query strings. Never sample an app panel:
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
			var dark = null, source = '';

			if (bootstrap === 'true' || bootstrap === 'false') {
				dark = bootstrap === 'true';
				source = 'bootstrap';
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
			observer.observe(root, { attributes: true, attributeFilter: ['data-darkmode'] });
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
		var pollTimer = null;

		function update(running, pid) {
			dotEl.className = 'ps-status-dot ' + (running ? 'running' : 'stopped');
			textEl.textContent = running ? ('Running' + (pid ? ' (PID ' + pid + ')' : '')) : 'Stopped';
			textEl.style.color = PT.color(running ? 'success' : 'error');
			if (toggleBtn) {
				toggleBtn.textContent = running ? 'Stop' : 'Start';
				toggleBtn.style.display = 'inline-block';
				toggleBtn.disabled = false;
			}
		}

		function fetchStatus(cb) {
			PT.getJson(statusUrl, function (r) {
				cb(r ? !!r.running : false, r && r.pid ? r.pid : null);
			});
		}

		function poll(onSuccess, onTimeout, attempts) {
			if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
			attempts = attempts || 0;
			if (attempts >= 8) { onTimeout(); return; }
			pollTimer = setTimeout(function () {
				fetchStatus(function (running, pid) {
					update(running, pid);
					if (running) onSuccess();
					else poll(onSuccess, onTimeout, attempts + 1);
				});
			}, 2000);
		}

		return {
			update: update,
			refresh: function () { fetchStatus(update); },
			poll: poll
		};
	};

	PT.errorReporter = function (errorBtn, errorModal, errorDetails, errorClose, onPush) {
		var lastError = null;
		var errorTimer = null;
		var TTL = 600000;

		function hide() { errorModal.style.display = 'none'; }

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
		errorClose.addEventListener('click', hide);
		errorModal.addEventListener('click', function (e) {
			if (e.target === errorModal) hide();
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

		if (cfg.urls.toggle && toggleBtn) {
			toggleBtn.addEventListener('click', function () {
				var action = toggleBtn.textContent.toLowerCase();
				toggleBtn.disabled = true;
				toggleBtn.textContent = action === 'stop' ? 'Stopping...' : 'Starting...';
				PT.xhrPost(cfg.urls.toggle, 'action=' + action, function (xhr) {
					if (!xhr) { watcher.refresh(); return; }
					setTimeout(watcher.refresh, cfg.toggleDelay || 1000);
				});
			});
		}

		if (cfg.urls.autostart) {
			var autostartBtn = g('ps-autostart-btn');

			function setAutostart(enabled) {
				autostartBtn.textContent = enabled ? 'Autostart: ON' : 'Autostart: OFF';
				autostartBtn.style.display = 'inline-block';
			}

			function checkAutostart() {
				PT.getJson(cfg.urls.autostart, function (r) {
					if (r) setAutostart(!!r.enabled);
				});
			}

			autostartBtn.addEventListener('click', function () {
				var action = autostartBtn.textContent.indexOf('ON') >= 0 ? 'disable' : 'enable';
				autostartBtn.disabled = true;
				PT.xhrPost(cfg.urls.autostartToggle, 'action=' + action, function (xhr) {
					autostartBtn.disabled = false;
					if (xhr) {
						try { setAutostart(!!JSON.parse(xhr.responseText).enabled); } catch (e) {}
					}
				});
			});

			checkAutostart();
		}

		function loadConfig() {
			setStatus('Loading...', '#888');
			editor.disabled = true;
			var xhr = new XMLHttpRequest();
			xhr.open('GET', cfg.urls.read);
			xhr.onload = function () {
				editor.disabled = false;
				if (xhr.status === 200) {
					originalContent = xhr.responseText;
					editor.value = originalContent;
					isDirty = false;
					saveBtn.disabled = true;
					diffBtn.disabled = true;
					updateLineNumbers();
					setStatus('Loaded', '#4caf50');
				} else {
					setStatus('Failed to load', '#f44336');
					pushError('Failed to load config', 'HTTP ' + xhr.status);
				}
			};
			xhr.onerror = function () {
				editor.disabled = false;
				setStatus('Network error', '#f44336');
			};
			xhr.send();
		}

		function restoreDirtyButtons() {
			saveBtn.disabled = !isDirty;
			diffBtn.disabled = !isDirty;
		}

		function markSaved() {
			originalContent = editor.value;
			isDirty = false;
			diffBtn.disabled = true;
		}

		function doSave() {
			saveBtn.disabled = true;
			diffBtn.disabled = true;
			rollbackBtn.style.display = 'none';
			saveBtn.textContent = 'Saving...';
			editor.disabled = true;
			setStatus(t.saving, '#2196f3');

			PT.xhrPost(cfg.urls.save, 'content=' + encodeURIComponent(editor.value), function (xhr) {
				editor.disabled = false;
				saveBtn.textContent = 'Save Changes';
				if (!xhr) {
					restoreDirtyButtons();
					setStatus('Network error', '#f44336');
					pushError('Network error', 'Failed to connect to server');
					return;
				}
				try {
					var resp = JSON.parse(xhr.responseText);
					if (resp.success && resp.restarting) {
						setStatus(t.restarting, '#2196f3');
						watcher.poll(
							function () {
								markSaved();
								setStatus(t.saved, '#4caf50');
							},
							function () {
								setStatus(t.notStarted, '#f44336');
								rollbackBtn.style.display = 'inline-block';
								pushError('Restart failed', t.notStartedDetail);
							}
						);
					} else if (resp.success && resp.unchanged) {
						markSaved();
						saveBtn.disabled = true;
						setStatus(t.unchanged, '#4caf50');
					} else {
						restoreDirtyButtons();
						setStatus('Save failed', '#f44336');
						var err = cfg.extractError(resp);
						if (err && err.line) highlightErrorLine(err.line);
						pushError('Save failed', (err && err.msg) || 'Unknown error');
					}
				} catch (e) {
					restoreDirtyButtons();
					setStatus('Save failed', '#f44336');
					pushError('Save failed', 'Invalid response: ' + (xhr.responseText || '').substring(0, 300));
				}
			});
		}

		saveBtn.addEventListener('click', function () {
			if (isDirty) doSave();
		});

		document.addEventListener('keydown', function (e) {
			if ((e.ctrlKey || e.metaKey) && e.key === 's') {
				e.preventDefault();
				if (isDirty && !saveBtn.disabled) doSave();
			}
		});

		editor.addEventListener('input', function () {
			isDirty = (editor.value !== originalContent);
			restoreDirtyButtons();
			clearErrorLine();
			updateLineNumbers();
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
			if (!isDirty) return;
			if (!confirm('Discard unsaved changes?')) return;
			editor.value = originalContent;
			isDirty = false;
			saveBtn.disabled = true;
			diffBtn.disabled = true;
			updateLineNumbers();
			setStatus('Loaded', '#4caf50');
		});

		rollbackBtn.addEventListener('click', function () {
			rollbackBtn.style.display = 'none';
			setStatus('Rolling back...', '#2196f3');

			PT.xhrPost(cfg.urls.rollback, '', function (xhr) {
				if (!xhr) {
					setStatus('Rollback network error', '#f44336');
					return;
				}
				try {
					var resp = JSON.parse(xhr.responseText);
					if (resp.success) {
						setStatus('Rolled back. Restarting...', '#2196f3');
						watcher.poll(
							function () {
								setStatus('Rolled back successfully.', '#4caf50');
								loadConfig();
							},
							function () {
								setStatus(t.rollbackStillDown, '#ff9800');
								loadConfig();
							}
						);
					} else {
						setStatus('Rollback failed: ' + (resp.error || ''), '#f44336');
					}
				} catch (e) {
					setStatus('Rollback failed', '#f44336');
				}
			});
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
			if (!isDirty) return;
			renderDiffPreview();
			g('ps-diff-modal').style.display = 'flex';
		});

		diffToggle.addEventListener('change', function () {
			if (g('ps-diff-modal').style.display !== 'none') renderDiffPreview();
		});

		g('ps-diff-close').addEventListener('click', function () {
			g('ps-diff-modal').style.display = 'none';
		});
		g('ps-diff-modal').addEventListener('click', function (e) {
			if (e.target === g('ps-diff-modal')) g('ps-diff-modal').style.display = 'none';
		});

		window.addEventListener('beforeunload', function (e) {
			if (isDirty) { e.preventDefault(); e.returnValue = ''; }
		});

		watcher.refresh();
		loadConfig();

		return {
			loadConfig: loadConfig,
			refreshStatus: watcher.refresh,
			setStatus: setStatus,
			pushError: pushError
		};
	};
})();
