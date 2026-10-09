# Podkop Tweaker

LuCI web interface for managing Podkop proxy client on OpenWrt routers.

## Features

- **Podkop Config** — web-based editor for `/etc/config/podkop` with diff preview (LCS diff, collapsed unchanged lines, "only changed" toggle) and one-click rollback
- **Stubby Config** — Stubby DNS-over-TLS editor with a recommended template (six DoT upstreams across three independent providers, round-robin), init script fix, service start/stop and autostart
- **Sing-box Config** — sing-box `config.json` editor with `sing-box check` validation, rollback, plus the fragment patch module (TLS fragment / record fragment on selected outbounds, wrapper auto-reinstall after Podkop updates)
- **Diagnostics** — DNS chain visualization and local probes, a manual browser-origin external DNS resolver observation, direct navigation to Podkop Diagnostics, and a per-run log with JSON export
- **Subscriptions** — proxy subscription manager (vless/vmess/ss/trojan): attach per slot, manual and scheduled auto-updates (cron + hotplug), actual scheduler status and update journal
- **Import/Export** — JSON bundle backup of selected items (podkop, stubby, sing-box, fragment, argon, tweaker settings, subscriptions + schedule), review modal before applying, per-item results, automatic pre-apply backups, service status panel; single raw config files are supported as well
- **System Information** — Podkop and system versions, update via ttyd terminal
- **Local Update / Git Update** — self-update from GitHub Releases or a local archive, with LuCI cache cleanup
- **Argon Config** (optional, hidden by default) — global Argon typography and sidebar tuning, app-local Soft / High contrast profiles, adjustable monospace text and per-scheme status colors, with live preview
- **Copy text** — upper-right clipboard controls for editors, logs, DNS chains, diff previews and complete error details, including ordinary HTTP router pages

## Requirements

- **OpenWrt** 24.10.x
- `luci-lua-runtime` — Lua runtime for classic LuCI server-side templates
- `Podkop` — proxy client (sing-box based)
- `curl` — HTTP requests (subscriptions, diagnostics, updates)
- `stubby` — optional, for Stubby Config tab and DNS-over-TLS diagnostics
- `ttyd` — optional, for interactive Podkop updates
- `cron` — optional, for automatic subscription updates

## Installation

Extract the release archive to the router root filesystem:

```bash
tar -xzf luci-app-podkop-tweaker-vX.Y.Z.tar.gz -C /
```

No ipk package build required — files are copied as-is. After installing (or updating), restart the web interface (`/etc/init.d/uhttpd restart`) or use the built-in "Clear LuCI Cache" button.

### Local same-version reinstall (4.7.1+)

After archive validation, Local Update offers **Update** for a newer version and
**Reinstall** for an archive whose version exactly matches the installed version.
Reinstall sends an explicit `reinstall=1` POST; the server checks equality again
after manifest/file validation and uses the same checked application pipeline.
Existing app UCI settings are preserved and LuCI restarts on complete success.
Older archives are still blocked by Local Update; intentional Git force downgrade
retains its existing behavior. Upload/apply controls stay locked while applying.

Install this capability initially using an archive newer than the installed version
(**4.7.1 or later**): an installed
4.7.0 updater cannot expose a button contained only in an equal-version archive.
After that transition, another archive matching the installed version can be
applied through **Reinstall**.

### Update confirmation (4.9.0+)

Local Update/Reinstall, Git Update, Argon Theme Update and Clear LuCI Cache wait
for operation confirmation instead of blindly reloading after a fixed delay.
The server records the checked result in a private, bounded RAM record and queues
uhttpd restart after a short response-delivery delay. Readiness requires the same
operation ID, a changed uhttpd PID/start-time identity and the expected installed
version; equal-version Reinstall is covered as well.

Verification has a 60-second deadline and 4-second probe timeouts. A lost apply
response is checked against the recorded result, without automatically submitting
Apply again. If readiness or the session cannot be confirmed, **Retry verification**
repeats only the read checks. Git downgrade to a pre-4.9.0 target uses stable target
version/availability checks only after receiving the successful checked-apply
response; it does not claim process-identity verification for that older target.
Reload uses a bounded nonce to refresh equal-version app assets. Podkop installation
remains interactive in ttyd, followed by the existing Refresh action.

### Large config and bundle transport (4.9.0+)

The three config editors and raw/bundle imports send UTF-8 content as a bounded
multipart file, avoiding LuCI's approximately 100 KiB text-field limit and URL
encoding expansion. Application limits remain 1 MiB for UCI, 2 MiB for sing-box and
4 MiB for a bundle. Existing validation, backups and per-item results still apply.
The server collects file bytes before parsing the form, verifies CSRF before
mutation, rejects incomplete/multiple/unexpected files and reports parser failures
as JSON. Legacy small text POSTs remain supported.

## Subscription scheduling status (4.9.0+)

**Actual Auto-Update Status**, below Auto-Update options, shows the expected and
installed cron entry, crond presence, launcher/hotplug content and executable state,
and the last journaled automatic completion with updated/unchanged/failed counts.
Cron uses the router's time. The last completion is read from a bounded 64 KiB tail;
missing history is unknown, not a successful run. Cron and WAN triggers share the
existing `auto` label, so that journal does not distinguish their source.

Schedule setup failures are reported after saved settings, including partial setup;
the status block reflects the actual files. Unrelated crontab entries are retained.
Saving the log display count changes only that preference and does not rewrite or
reschedule auto-updates. Network, timeout, HTTP and malformed-response failures
release subscription controls for retry. Mobile split panels stack at full width.

Appearance preview can still be discarded by refreshing the page; an additional
Cancel Preview action is deferred.

## Copy text (4.8.0+)

**Copy** reads the current contents of its editor, journal, diagram, diff or error
block, including text outside the scroll viewport. Editors copy their entire current
value without line-number gutters. Recent subscription logs copy the displayed
entries; **Full Log** copies the whole loaded history. Error disclosures copy all
details even while collapsed, retaining literal HTML and line breaks.

Since 4.8.1, the two-overlapping-squares icon sits at the upper right **inside** the
text frame, with its own non-scrolling tools row. A check mark confirms success;
an error mark and tooltip allow retry or manual selection. Error icons move between
the collapsed summary and the expanded text frame. Status text remains available
to assistive technology. Copying preserves editor selection, focus, scroll and
unsaved state. HTTPS uses the Clipboard API when available; ordinary HTTP and
denied/unavailable API access fall back to a temporary selected text field. Clipboard
writes happen only after the user activates Copy, with no server request.

## Stubby template and logging (4.8.1)

The recommended template keeps six IPv4 DoT endpoints (Cloudflare, Quad9, DNS.SB),
round-robin redundancy and the 30,000ms idle timeout. DNS.SB uses the documented
TLS authentication name **dot.sb**. Podkop block sections provide the user's domain
filtering; Quad9 additionally applies its own threat filtering.

`log_level '3'` is the template default. The template help lists all supported levels:
0 Emergency, 1 Alert, 2 Critical, 3 Error, 4 Warning, 5 Notice, 6 Info, 7 Debug.
Logging is configured in the text editor; system logs are collected in the terminal.
OpenWrt's package init passes `-v` and forwards stderr/stdout to procd/logd. Its main
logread history is a bounded shared RAM ring, normally 64 KiB unless system logging
settings override it. `appdata_dir` is runtime/trust-anchor storage, not a log path.

Updating Tweaker delivers this template; adopting it uses **Template → Apply This
Template** with a backup, or explicit edits to the existing Stubby configuration.
To collect detailed logs after installation:

```sh
uci set stubby.global.log_level='7' && uci commit stubby && /etc/init.d/stubby restart
logread -f -e stubby
```

Collect 15–20 minutes: five minutes of normal browsing, then three 12–15s quiet
periods and three 40–60s quiet periods, each followed by fresh site/app activity.
The shorter gaps distinguish 9s from 30s reuse; the longer gaps exercise reopening
after both client idle limits. Note each pause/request time and any delay.
Background LAN activity may prevent a true idle period; use per-upstream
timestamps. Keep complete messages for all six endpoints: `Keepalive(ms)`, `Conns`,
`Conn_fails`, `Conn_shuts`, `Timeouts`, `Backoffs`, authentication failures and query
errors. A/B comparison with 9,000ms needs the same actions, an unchanged resolver
set and logging level, and a separate pass changing only idle timeout. Direct Stubby
queries avoid Podkop/browser DNS caches when measuring; successful warm/cold query
latency, failures and connection counts matter more than normal close messages.
For repeatable traffic without the browser/Podkop cache, run the existing router
utility six times in succession, to give the healthy round-robin pool activity:

```sh
for n in 1 2 3 4 5 6; do nslookup example.com 127.0.0.53; done
```

Repeat the same burst after each quiet period. Unhealthy endpoints can be skipped;
check per-address records rather than assuming one query went to every endpoint.

Restore normal logging afterwards:

```sh
uci set stubby.global.log_level='3' && uci commit stubby && /etc/init.d/stubby restart
```

Local DNSSEC validation is disabled while upstream validation and TLS certificate
authentication remain independent. `tls_connection_retries` is a connection/health
setting, not a promise of two repeats per query; `tls_backoff_time` is the progressive
backoff ceiling, not an immediate one-hour suspension. The router's supplied dump
confirmed Stubby 0.4.3/getdns 1.7.3/OpenSSL 3.5.7 and the intended TLS-only settings.

## Argon Config (optional)

The Argon Config tab is **hidden by default**. It provides typography settings (font size, font family, font weight, line height, letter spacing, sidebar menu font size and padding) for the [Argon theme](https://github.com/jerrykuku/luci-theme-argon) with live preview. Settings are stored in `/etc/config/argon` and applied by appending a CSS block to `/www/luci-static/argon/css/cascade.css`.

Enable the tab via SSH:

```bash
uci set podkop-tweaker.settings.show_argon_tab='1'
uci commit podkop-tweaker
```

Disable it back:

```bash
uci set podkop-tweaker.settings.show_argon_tab='0'
uci commit podkop-tweaker
```

After a theme update the CSS block is lost — open the Argon Config tab and click "Reinject CSS".

### Tweaker Appearance

The same tab contains a separate **Tweaker Appearance** panel. Its settings affect
Podkop Tweaker only and do not modify Argon's global typography or theme CSS:

| Setting | Values | Default |
|---|---|---|
| Appearance Profile | Soft / High contrast | Soft |
| Monospace Font Size | 12–18px | 13px |
| Monospace Font Weight | 400 / 500 | 400 |
| Monospace Line Height | 1.3–1.8, step 0.1 | 1.6 |

Monospace settings apply to config editors, journals, DNS chains and diff previews.
Editors retain horizontal scrolling so enlarged text stays aligned with line numbers.
By default, success statuses use saturated green, errors red, and update notices orange in both
profiles. The live sample shows ordinary text, line numbers and all three statuses.

Use **Save Appearance** to persist the preview, or **Reset Appearance** to restore
the profile/monospace defaults independently of status colors and global typography. Settings live in the `appearance`
section of `/etc/config/podkop-tweaker` and are included in the **Tweaker** bundle item.
Saved appearance remains active if the optional tab is hidden or a different LuCI
theme is selected. Refresh already-open tabs to pick up changed settings.

#### Status Colors

The **Status Colors** block has three rows and separate Light / Dark controls.
Use either the native color picker or the synchronized **#RRGGBB** text field:

| Role | Light default | Dark default |
|---|---|---|
| Success / Green | `#00be00` | `#00ff00` |
| Error / Red | `#ff0000` | `#ff8080` |
| Warning / Orange | `#ff8c42` | `#ffbd42` |

Both scheme previews remain visible regardless of the current page scheme. They
show the exact selected color and its contrast on a raised/header surface, with
and without the derived translucent highlight. Contrast is informative: any valid
six-digit HEX color is applied exactly, including a low-contrast choice. Invalid
intermediate HEX leaves the last valid preview intact and disables Save until fixed.

Colors affect diagnostic results, service indicators, journals, diff rows, errors
and update notices across the application. Scheme changes select the corresponding
saved colors automatically; Soft / High contrast profiles keep those colors intact.
RGB highlight channels are derived from the selected HEX, with no separate RGB setting.

**Save Appearance** saves all ten settings. **Reset Colors** saves only the six
default colors and preserves profile, font settings and any unsaved font preview.
**Reset Appearance** saves only the four profile/monospace defaults and preserves
the colors. All settings travel in the existing **Tweaker** bundle item.

The installed v4.6.0+ Local/Git updater preserves an existing app config instead of
copying archive defaults over it; defaults are copied only when the config is absent.
Older installed updaters and direct archive extraction retain their original copy behavior.

## Operation integrity and update validation (4.7.0)

File writes/backups/restores check open, write, close and rename results. Each
self-update file is applied atomically, with executable permissions checked before
rename. Failed application returns the failed path and retains staging for
inspection/retry; it does not claim success, delete deprecated files or restart
LuCI as a successful completion. App-owned UCI settings remain preserved.

Release archives are inspected before extraction using bounded gzip output and
tar metadata. Regular files/directories only, safe canonical paths, checksums,
duplicate detection and limits are enforced: 256 members, 1 MiB per file, 4 MiB
expanded data and 5 MiB total tar stream. POSIX PAX/GNU long-name metadata is
bounded; links, devices, FIFO and sparse members are rejected. Extraction status,
regular file type and actual size are rechecked against the manifest. Local upload
still has a 128,000-byte compressed limit; Git downloads are capped at 512,000 bytes.
Git Update accepts only canonical HTTPS release-download URLs for this repository.
Intentional force downgrade remains supported.

Subscription responses use bounded HTTP pipes (1 MiB), including absent/incorrect
Content-Length; decoding, proxy count (1,000) and link length (16 KiB) are bounded.
Literal control bytes are rejected. Proxy-link replacement scans logical UCI
statements, preserves unrelated multiline values/comments and validates the
candidate before backup/write. Failed updates do not advance successful timestamps.

### External DNS observation

**Observe Browser DNS** is a manual action separate from Run All. It creates a
bash.ws test ID, sends six unique HTTPS probes from the current browser, and reads
the observed recursive resolver IP/ASN/country facts through a bounded JSON request.
The provider control-request IP is explicitly labeled as router-origin context.
Results are mirrored into the existing Run Log/JSON export. Empty observations are
inconclusive; generic provider VPN/ASN conclusions are not used to declare no leaks.
The legacy two-nslookup leak heuristic is retired with an explicit API error.

The visible note and collapsible **How to read results** guide explain when to run
the independent observation, each result field and the Run Log metadata. Resolver
IP is an outgoing recursive-server address, not a website answer; the control IP
is router-context, not browser egress. **OBSERVATIONS COLLECTED** / log **OK** means
data was collected, not that no leaks exist. **INCONCLUSIVE** covers missing data
or request errors. `probes_completed` includes load/error events, while `complete`
means at least one resolver was observed. Export the current JSON log before
starting another test if it should be retained.

Browser DoH and Podkop split-routing/FakeIP affect the measured path; these facts
describe this browser/run, not every LAN device or DNS transport encryption.
Podkop's built-in DNS, FakeIP, firewall and outbound checks remain in its own UI.
**Podkop Diagnostics** opens its normal LuCI route in a new tab and selects the
native diagnostics tab after initialization when possible, with bounded fallback
to the ordinary page. No diagnostic requests are automatically started there.

## Disclaimer

Podkop Tweaker is an independent third-party tool and is not affiliated with, endorsed by, or officially connected to the Podkop project or its maintainers.

"Podkop" is a trademark of the Podkop project. All references to Podkop in this application are for descriptive purposes only — to indicate compatibility and the intended use of this tool.

## License

[Apache-2.0](LICENSE)
