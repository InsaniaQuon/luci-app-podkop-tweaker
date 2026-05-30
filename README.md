# Podkop Tweaker

LuCI web interface for managing [Podkop](https://github.com/itdoginfo/podkop) proxy client on OpenWrt routers.

## Features

- **Config Editor** — web-based Podkop configuration editor with syntax highlighting
- **Import/Export** — config file import/export with automatic backup and one-click rollback
- **System Information** — Podkop and system version info with update via ttyd terminal
- **Subscriptions** — proxy subscription manager (vless/vmess/ss/trojan) with auto-update scheduling
- **Self-Update** — update Podkop Tweaker from GitHub Releases or local archive (drag & drop)

## Requirements

- OpenWrt 24.10+
- [Podkop](https://github.com/itdoginfo/podkop) (tested with the original project, not tested with forks)
- LuCI (classic, server-side templates)
- `curl`, `ttyd` (for Podkop update)

## Installation

Extract the release archive to the router root filesystem:

```bash
tar -xzf luci-app-podkop-tweaker-vX.Y.Z.tar.gz -C /
```

No ipk package build required — files are copied as-is.

## Disclaimer

Podkop Tweaker is an independent third-party tool and is not affiliated with, endorsed by, or officially connected to the Podkop project or its maintainers.

"Podkop" is a trademark of the Podkop project. All references to Podkop in this application are for descriptive purposes only — to indicate compatibility and the intended use of this tool.

## License

[Apache-2.0](LICENSE)
