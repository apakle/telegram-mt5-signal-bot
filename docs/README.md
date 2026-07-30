# Documentation

| File | Description |
|---|---|
| `MT5_VPS_SETUP.md` | Complete guide for deploying MT5 headlessly on Oracle ARM64 VPS |

## MT5_VPS_SETUP.md covers

- Installing Hangover Wine (ARM64) on Ubuntu
- Installing MetaTrader 5 under Wine
- Configuring broker connection (`servers.dat`, `live.ini`)
- Enabling headless algo trading via chart profiles (`.chr` files)
- Setting up systemd services with correct Wine/systemd settings
- Running multiple MT5 instances (separate and shared Wine prefix)
- Running multiple EAs on one MT5 instance
- Python signal bot systemd service
- Key learnings and gotchas