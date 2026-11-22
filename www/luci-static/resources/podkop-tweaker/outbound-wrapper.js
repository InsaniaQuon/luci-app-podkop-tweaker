/* Persistent outbound selection. Opening/refreshing never submits a mutation. */
(function () {
    'use strict';
    var bar = document.getElementById('ps-outbound-wrapper');
    var dialog = document.getElementById('ps-outbound-dialog');
    var model = null, mode = null, busy = false, generation = 0;
    function get(root, kind, key) { return root.querySelector('[data-' + kind + '="' + key + '"]'); }
    function btn(key) { return get(bar, 'action', key); }
    function msg(value) { get(bar, 'role', 'message').textContent = value; }
    function opt(key) { return get(dialog, 'option', key); }
    function badge(key, text, color) {
        var el = get(bar, 'role', key);
        el.textContent = text; el.style.color = 'var(--ps-' + color + ')';
    }
    function valid(data) {
        if (!data || data.error || typeof data.ready !== 'boolean' || typeof data.revision !== 'string' ||
            !Number.isInteger(data.count) || data.count < 0 || typeof data.tcp !== 'boolean' ||
            typeof data.record !== 'boolean' || typeof data.delay !== 'string') return false;
        if (data.count === 0 && data.rows && !Object.keys(data.rows).length) data.rows = [];
        return Array.isArray(data.rows) && data.rows.length === data.count && data.rows.every(function (r) {
            return r && typeof r.tag === 'string' && typeof r.section === 'string' && typeof r.name === 'string' &&
                typeof r.id === 'string' && typeof r.eligible === 'boolean';
        }) && ['mask','fragment'].every(function (k) {
            var x = data[k]; return x && ['ON','OFF','ERROR','Temporary'].indexOf(x.state) !== -1 &&
                [x.selected,x.applied,x.temporary].every(function (v) { return Number.isInteger(v) && v >= 0; });
        });
    }
    function refresh(done) {
        var seq = ++generation;
        model = null; btn('fragment').disabled = btn('mask').disabled = true; btn('repair').hidden = true;
        PT.getJson(PT.urls.policy, function (data, status, reason) {
            if (seq !== generation) return;
            if (!valid(data)) {
                badge('health','Unknown','warning'); badge('mask','Unknown','warning'); badge('fragment','Unknown','warning');
                msg(data && data.error || reason || 'Invalid wrapper status'); return;
            }
            model = data;
            badge('health',data.ready ? 'Ready' : 'Repair required',data.ready ? 'success' : 'error');
            btn('repair').hidden = data.ready; btn('repair').disabled = busy;
            ['mask','fragment'].forEach(function (k) {
                var x = data[k], text = x.state;
                if (x.state === 'ON' || x.state === 'ERROR') text += ' \u00b7 ' + x.applied + '/' + x.selected;
                if (x.temporary) text += (x.state === 'Temporary' ? ' \u00b7 ' : ' + temporary: ') + x.temporary;
                badge(k,text,({ON:'success',OFF:'text-dim',Temporary:'warning',ERROR:'error'})[x.state]);
                btn(k).disabled = busy;
            });
            if (done) done();
        });
    }
    function open(k) {
        if (!model || busy) return;
        mode = k;
        get(dialog,'role','title').textContent = k === 'mask' ? 'FinalMask' : 'Fragment';
        get(dialog,'role','options').hidden = k !== 'fragment';
        opt('tcp').checked = model.tcp; opt('record').checked = model.record; opt('delay').value = model.delay;
        opt('delay').disabled = !opt('tcp').checked;
        var list = get(dialog,'role','nodes'), section = null;
        list.textContent = '';
        model.rows.forEach(function (r) {
            if (section !== r.section) {
                var h = document.createElement('h4'); h.textContent = section = r.section; list.appendChild(h);
            }
            var label = document.createElement('label'), cb = document.createElement('input'), detail = document.createElement('small');
            cb.type = 'checkbox'; cb.value = r.id;
            cb.checked = r.wanted === k || (!r.wanted && r.eligible && (k === 'mask' ? r.exact : r.fragment));
            cb.disabled = (!r.eligible && r.wanted !== k) || (r.mask && !r.exact);
            cb.dataset.conflict = String(!!((r.wanted && r.wanted !== k) || (k === 'mask' ? r.fragment : r.mask)));
            detail.textContent = (r.tag || 'Missing') + (!r.eligible ? ' (unavailable)' :
                r.mask && !r.exact ? ' (custom mask)' : cb.dataset.conflict === 'true' ? ' (other mode)' : '');
            label.appendChild(cb); label.appendChild(document.createTextNode(r.name)); label.appendChild(detail); list.appendChild(label);
        });
        if (!model.count) list.textContent = 'No Podkop proxy nodes found.';
        get(dialog,'action','apply').disabled = !model.ready;
        dialog.style.display = 'flex';
    }
    function post(url, params, success) {
        busy = true; ++generation; model = null; mode = null; dialog.style.display = 'none';
        ['fragment','mask','repair','refresh'].forEach(function (k) { btn(k).disabled = true; });
        msg('Working...');
        PT.postJson(url,params,function (data,err) {
            if (err || !data || data.success !== true) {
                busy = false; btn('refresh').disabled = false;
                msg((err && err.data && err.data.settings_saved ? 'Rules saved. ' : '') +
                    (err && err.message || 'Result unknown') + (err && err.details ? ': ' + err.details : ''));
                refresh(); return;
            }
            success(data);
        },120000);
    }
    function finish(message) { busy = false; btn('refresh').disabled = false; msg(message); refresh(); }
    function verify(result) {
        var attempts = 0;
        function probe() {
            PT.getJson(PT.urls.status,function (s) {
                if (s && !s.error && s.running === true && typeof s.instance === 'string' && result.previous_identity_known === true &&
                    (result.previous_running === false || (result.previous_instance && result.previous_instance !== s.instance))) {
                    finish('New sing-box process confirmed. Reload the editor before further edits.'); return;
                }
                if (++attempts < 30) window.setTimeout(probe,2000);
                else finish('Rules saved; restart unverified. Refresh to inspect status.');
            },4000);
        }
        msg('Rules saved. Checking new sing-box process...'); probe();
    }
    opt('tcp').onchange = function () { opt('delay').disabled = !opt('tcp').checked; };
    PT.bindModal(dialog,get(dialog,'action','close'),function () { mode = null; });
    get(dialog,'action','apply').onclick = function () {
        if (busy || !model || !model.ready || !mode) return;
        var picked = Array.from(get(dialog,'role','nodes').querySelectorAll('input:checked'));
        var replace = picked.some(function (cb) { return cb.dataset.conflict === 'true'; });
        if (!window.confirm((replace ? 'Replace the other mode on the selected nodes? ' : '') +
            'Save this selection and restart Podkop? Temporary edits not selected for persistence will be lost.')) return;
        post(PT.urls.policyApply,'selection=' + encodeURIComponent(JSON.stringify({
            revision:model.revision,mode:mode,ids:picked.map(function (cb) { return cb.value; }),
            replace:replace,tcp:opt('tcp').checked,record:opt('record').checked,delay:opt('delay').value
        })),verify);
    };
    btn('fragment').onclick = function () { open('fragment'); };
    btn('mask').onclick = function () { open('mask'); };
    btn('refresh').onclick = function () { if (!busy) { msg(''); refresh(); } };
    btn('repair').onclick = function () {
        if (busy || !model || model.ready || !window.confirm('Install the generator hook without regenerating the current config?')) return;
        post(PT.urls.policyRepair,'',function () { finish('Wrapper installed.'); });
    };
    refresh();
})();
