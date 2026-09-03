# Podkop Tweaker

LuCI web interface for managing Podkop proxy client on OpenWrt routers.

## Features

- **Podkop Config** — web-based editor for `/etc/config/podkop` with diff preview (LCS diff, collapsed unchanged lines, "only changed" toggle) and one-click rollback
- **Stubby Config** — Stubby DNS-over-TLS editor with a recommended template (six DoT upstreams across three independent providers, round-robin), init script fix, service start/stop and autostart
- **Sing-box Config** — sing-box `config.json` editor with `sing-box check` validation, rollback, plus the fragment patch module (TLS fragment / record fragment on selected outbounds, wrapper auto-reinstall after Podkop updates)
- **Diagnostics** — DNS chain visualization with live test coloring, DNS resolution / proxy connectivity / end-to-end / DNS leak tests, and a per-run log with JSON export
- **Subscriptions** — proxy subscription manager (vless/vmess/ss/trojan): attach per slot, manual and scheduled auto-updates (cron + hotplug), update journal
- **Import/Export** — JSON bundle backup of selected items (podkop, stubby, sing-box, fragment, argon, tweaker settings, subscriptions + schedule), review modal before applying, per-item results, automatic pre-apply backups, service status panel; single raw config files are supported as well
- **System Information** — Podkop and system versions, update via ttyd terminal
- **Local Update / Git Update** — self-update from GitHub Releases or a local archive, with LuCI cache cleanup
- **Argon Config** (optional, hidden by default) — typography settings for the Argon LuCI theme: font size, family, weight, line height, letter spacing, sidebar menu tuning with live preview

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

## Disclaimer

Podkop Tweaker is an independent third-party tool and is not affiliated with, endorsed by, or officially connected to the Podkop project or its maintainers.

"Podkop" is a trademark of the Podkop project. All references to Podkop in this application are for descriptive purposes only — to indicate compatibility and the intended use of this tool.

## License

[Apache-2.0](LICENSE)
