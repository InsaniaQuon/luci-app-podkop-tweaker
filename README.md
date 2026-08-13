# Podkop Tweaker

LuCI web interface for managing Podkop proxy client on OpenWrt routers.

## Features

- **Config Editor** — web-based Podkop configuration editor with syntax highlighting
- **Stubby Config** — Stubby DNS-over-TLS configuration editor with init script fix and service start/stop
- **Sing-box Config** — sing-box config.json editor with validation, start/stop
- **Diagnostics** — DNS chain visualization with live test coloring, DNS resolution test, proxy connectivity test, end-to-end test, DNS leak test
- **Import/Export** — config file import/export with automatic backup and one-click rollback
- **System Information** — Podkop and system version info with update via ttyd terminal
- **Subscriptions** — proxy subscription manager (vless/vmess/ss/trojan) with auto-update scheduling
- **Self-Update** — update Podkop Tweaker from GitHub Releases or local archive
- **Argon Config** (optional, disabled by default) — typography settings for the Argon LuCI theme: font size, family, weight, line height, letter spacing, sidebar menu tuning with live preview

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

No ipk package build required — files are copied as-is.

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
