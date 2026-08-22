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
		xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
		xhr.onload = function () { cb(xhr); };
		xhr.onerror = function () { cb(null); };
		xhr.send('token=' + encodeURIComponent(PT.csrf || '') + (params ? '&' + params : ''));
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
			textEl.style.color = running ? '#4caf50' : '#f44336';
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

	PT.buildDiff = function (oldText, newText, statsEl) {
		var oldLines = oldText.split('\n');
		var newLines = newText.split('\n');
		var html = '';
		var added = 0, removed = 0;
		var max = Math.max(oldLines.length, newLines.length);
		for (var i = 0; i < max; i++) {
			var o = oldLines[i];
			var n = newLines[i];
			if (o === n) {
				html += '<div class="ps-diff-line ps-diff-same"><span class="ps-diff-num">' + (i + 1) + '</span> ' + PT.escapeHtml(o || '') + '</div>';
			} else {
				if (o !== undefined) {
					removed++;
					html += '<div class="ps-diff-line ps-diff-del"><span class="ps-diff-num">' + (i + 1) + '</span><span class="ps-diff-mark">-</span> ' + PT.escapeHtml(o) + '</div>';
				}
				if (n !== undefined) {
					added++;
					html += '<div class="ps-diff-line ps-diff-add"><span class="ps-diff-num">' + (i + 1) + '</span><span class="ps-diff-mark">+</span> ' + PT.escapeHtml(n) + '</div>';
				}
			}
		}
		if (statsEl) statsEl.textContent = added + ' added, ' + removed + ' removed (' + newLines.length + ' lines total)';
		return html;
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
			statusEl.style.color = color || '#888';
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
					nums.push('<span style="color:#f44336;font-weight:700;">\u25B6 ' + i + '</span>');
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

		diffBtn.addEventListener('click', function () {
			if (!isDirty) return;
			g('ps-diff-body').innerHTML = PT.buildDiff(originalContent, editor.value, g('ps-diff-stats'));
			g('ps-diff-modal').style.display = 'flex';
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
