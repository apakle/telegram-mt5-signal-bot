# MQL5 Files

This folder contains MetaTrader 5 Expert Advisor source files and chart profile templates.

## Experts/

| File | Description |
|---|---|
| `ForexeroSignalExecutor.mq5` | Main EA — reads `signal.json`, places 3 orders (TP1/TP2/TP3) |
| `SignalExecutorFromJson3.mq5` | Second EA for zone-based signals — reads `signal_zones.json` |

## Profiles/

Chart profile templates (`.chr` files) for each MT5 instance. These are copied to the VPS at:

```
~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/<ProfileName>/
```

The `.chr` files contain `expertmode=1` which enables "Allow Algo Trading" per EA — this is the key to headless algo trading without GUI interaction. See [../docs/MT5_VPS_SETUP.md](../docs/MT5_VPS_SETUP.md) section 8 for details.

## Compiling

Open `.mq5` files in MetaEditor on Windows and press `F7` to compile. The resulting `.ex5` file can be deployed directly to the VPS:

```bash
scp mql5/Experts/ForexeroSignalExecutor.ex5 \
    ubuntu@your-vps-ip:"/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
```

> Note: The JSON parsing library (`JSON/index.mqh`) does **not** need to be copied to the VPS — the compiled `.ex5` file works standalone.

## Deploying chart profiles to VPS

```bash
scp mql5/Profiles/PUPrime_EAs/* \
    ubuntu@your-vps-ip:"/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/PUPrime_EAs/"
```