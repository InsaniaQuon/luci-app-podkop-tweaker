# Podkop Tweaker

LuCI web interface for managing Podkop proxy client on OpenWrt routers.

## Features

- **Podkop Config** — editor for `/etc/config/podkop` with diff preview and one-click rollback
- **Stubby Config** — DNS-over-TLS editor, recommended six-upstream template, init script fix, service controls and autostart
- **Sing-box Config** — `config.json` editor with validation, rollback and TLS fragment/wrapper controls
- **Diagnostics** — DNS chain, local DNS/proxy/end-to-end tests, manual browser DNS observation, Podkop Diagnostics shortcut and JSON run log
- **Subscriptions** — vless/vmess/ss/trojan subscriptions per proxy slot, manual/cron/WAN updates, scheduler status and journal
- **Import/Export** — selected-item JSON bundle backups and raw config imports, review before applying and automatic backups
- **System Information** — component versions, update checks and interactive Podkop update via ttyd
- **Local Update / Git Update** — self-update from an archive or GitHub Releases, same-version reinstall and LuCI cache cleanup
- **Argon Config** (optional) — global theme typography and app appearance profiles, monospace settings and status colors with live preview
- **Copy text** — clipboard controls for editors, logs, diagrams, diff previews and complete error details

## Requirements

- **OpenWrt** with classic LuCI/Lua support (24.10.x / 25.12.x)
- `luci-lua-runtime` — Lua runtime for classic LuCI server-side templates
- `Podkop` — proxy client (sing-box based)
- `curl` — HTTP requests
- `stubby` — optional, for Stubby configuration and DNS-over-TLS diagnostics
- `ttyd` — optional, for interactive Podkop updates
- `cron` — optional, for scheduled subscription updates

## Installation

Extract the release archive to the router root filesystem:

```sh
tar -xzf luci-app-podkop-tweaker-vX.Y.Z.tar.gz -C /
```

No ipk package build required — files are copied as-is. Restart the web interface
with `/etc/init.d/uhttpd restart` or use the built-in **Clear LuCI Cache** button.

## Argon Config (optional)

The tab is **hidden by default**. It provides typography and sidebar settings for
the [Argon theme](https://github.com/jerrykuku/luci-theme-argon) with live preview.

Enable the tab via SSH:

```sh
uci set podkop-tweaker.settings.show_argon_tab='1'
uci commit podkop-tweaker
```

Disable it back:

```sh
uci set podkop-tweaker.settings.show_argon_tab='0'
uci commit podkop-tweaker
```

Theme typography is stored in `/etc/config/argon`. If its CSS is lost after an
external theme update, use **Reinject CSS**.

**Tweaker Appearance** controls the app's Soft (default) / High contrast profile,
monospace text and light/dark status colors. Settings are stored in
`/etc/config/podkop-tweaker`; unsaved preview can be discarded by refreshing the page.

## Disclaimer

Podkop Tweaker is an independent third-party tool and is not affiliated with, endorsed by, or officially connected to the Podkop project or its maintainers.

"Podkop" is a trademark of the Podkop project. All references to Podkop in this application are for descriptive purposes only — to indicate compatibility and the intended use of this tool.

## License

[Apache-2.0](LICENSE)
