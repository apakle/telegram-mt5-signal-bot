# MetaTrader 5 on Oracle Cloud ARM64 VPS — Complete Setup Guide

Full installation and configuration manual for running a headless MetaTrader 5 automated trading pipeline on a free Oracle ARM64 VPS (Ubuntu), with the following architecture:

```
Telegram channel → Python script (Ollama LLM) → signal.json → MT5 Expert Advisor → broker trades
```

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Hangover Wine (ARM64)](#2-install-hangover-wine-arm64)
3. [Install Xvfb (Virtual Display)](#3-install-xvfb-virtual-display)
4. [Verify Wine Prefix is ARM64](#4-verify-wine-prefix-is-arm64)
5. [Install MetaTrader 5](#5-install-metatrader-5)
6. [Copy Broker's servers.dat](#6-copy-brokers-serversdat)
7. [Deploy Your Expert Advisor](#7-deploy-your-expert-advisor)
8. [Configure the Chart Profile (.chr files)](#8-configure-the-chart-profile-chr-files)
9. [Configure common.ini](#9-configure-commonini)
10. [Configure live.ini](#10-configure-liveini)
11. [Set Up Signal JSON Path](#11-set-up-signal-json-path)
12. [Create MT5 Startup Script](#12-create-mt5-startup-script)
13. [Create systemd Services](#13-create-systemd-services)
14. [Enable and Start All Services](#14-enable-and-start-all-services)
15. [Verify Everything is Running](#15-verify-everything-is-running)
16. [Python Signal Bot Service](#16-python-signal-bot-service)
17. [Running Multiple MT5 Instances (Separate Prefix)](#17-running-multiple-mt5-instances)
18. [Running Multiple MT5 Instances (Shared Prefix)](#18-running-multiple-mt5-instances-under-one-wine-prefix)
19. [Running Multiple EAs on One MT5 Instance](#19-running-multiple-eas-on-one-mt5-instance)
20. [Key Learnings and Gotchas](#20-key-learnings-and-gotchas)
21. [Useful Commands](#21-useful-commands)

---

## 1. Prerequisites

- Free Oracle ARM64 VPS running Ubuntu (24GB RAM instance recommended)
- SSH access to the VPS
- MT5 broker account (account number, password, server name)
- MT5 installed on a Windows machine with the same broker (needed for `servers.dat` and `.chr` profile files)
- Python signal bot script with venv prepared
- MT5 Expert Advisor `.ex5` file compiled and ready

---

## 2. Install Hangover Wine (ARM64)

Hangover Wine is required to run MT5 (a Windows x86-64 application) on ARM64 Linux. Follow the Medium article for installation:

[https://medium.com/@altbozon/running-mt5-on-a-free-oracle-arm64-vps-2f7c7f47cebb](https://medium.com/@altbozon/running-mt5-on-a-free-oracle-arm64-vps-2f7c7f47cebb)

Accompanying GitHub repo:
[https://github.com/altbozon/xauusd-algo-public/blob/main/docs/vps-setup.md](https://github.com/altbozon/xauusd-algo-public/blob/main/docs/vps-setup.md)

> **Important:** The `.ini` files used by MT5 must be **ASCII with no BOM**. Any BOM causes MT5 to silently ignore the entire file. Always write ini files using Python with `encoding='ascii'` (see examples below).

---

## 3. Install Xvfb (Virtual Display)

MT5 requires a display to render its UI even in headless mode.

```bash
sudo apt install -y xvfb xdotool
```

---

## 4. Verify Wine Prefix is ARM64

After Hangover Wine is installed, verify the Wine prefix was created correctly:

```bash
file ~/.wine/drive_c/windows/system32/kernel32.dll
```

Expected output:
```
PE32+ executable (DLL) (console) Aarch64, for MS Windows, 14 sections
```

If it shows `x86_64` or errors, wipe and rebuild:

```bash
rm -rf ~/.wine
DISPLAY=:10.0 WINEPREFIX=/home/ubuntu/.wine WINEARCH=win64 wine wineboot --init
```

---

## 5. Install MetaTrader 5

### Option A — Broker-specific installer (recommended)

Download the MT5 installer from your broker's website on your Windows machine, then copy it to the VPS:

```bash
scp "C:\Downloads\brokermt5setup.exe" ubuntu@your-vps-ip:/home/ubuntu/brokermt5setup.exe
```

### Option B — Generic MetaQuotes installer

```bash
wget https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /home/ubuntu/mt5setup.exe
```

### Run the installer

Start a temporary Xvfb display:

```bash
Xvfb :10 -screen 0 1024x768x24 &
```

> The xkbcomp warnings that appear are harmless — ignore them.

Run the installer silently:

```bash
DISPLAY=:10.0 WINEPREFIX=/home/ubuntu/.wine wine /home/ubuntu/mt5setup.exe /auto
```

Wait ~60 seconds (the `/auto` flag installs silently), then confirm:

```bash
ls ~/.wine/drive_c/Program\ Files/MetaTrader\ 5/
```

You should see `terminal64.exe` listed.

---

## 6. Copy Broker's servers.dat

MT5 needs your broker's server address. The easiest way is to copy `servers.dat` from an existing Windows MT5 installation that already connects to your broker.

On your **Windows machine**, find:
```
C:\Program Files\<Broker> MT5 Terminal\Config\servers.dat
```

Copy it to the VPS:

```bash
scp "C:\Program Files\<Broker> MT5 Terminal\Config\servers.dat" \
    ubuntu@your-vps-ip:"/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/Config/servers.dat"
```

> If you used the broker-specific installer (Option A above), `servers.dat` may already be included and this step can be skipped. Check the logs after first startup to confirm broker connection.

---

## 7. Deploy Your Expert Advisor

Copy your compiled `.ex5` file and the JSON parsing library to the VPS:

```bash
# Copy EA
scp /path/to/YourEA.ex5 ubuntu@your-vps-ip:"/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"

# Copy JSON library (if your EA uses it)
scp /path/to/JSON/index.mqh ubuntu@your-vps-ip:"/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/"
```

---

## 8. Configure the Chart Profile (.chr files)

This is the **key solution** for enabling algo trading headlessly. MT5 stores per-chart EA settings — including the "Allow Algo Trading" checkbox — in `.chr` profile files. By copying these from a working Windows installation, you bypass the need for any GUI interaction.

### Why this works

The `.chr` file contains `expertmode=1` under the `<expert>` tag, which is the exact flag that corresponds to the "Allow Algo Trading" checkbox in MT5's EA Properties dialog. MT5 reads this on startup and enables EA-level trading automatically.

### Step 1 — Get .chr files from Windows

On your Windows MT5 installation, navigate to:
```
C:\Users\<username>\AppData\Roaming\MetaQuotes\Terminal\<TERMINAL_ID>\profiles\charts\Default\
```

You will find files like `chart01.chr`, `chart02.chr`, `order.wnd`. Each `.chr` file represents one chart window with its attached EA.

### Step 2 — Create the profile folder on the VPS

```bash
mkdir -p "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/PUPrime_EAs"
```

### Step 3 — Create minimal .chr files

Rather than copying the full `.chr` files from Windows (which accumulate large amounts of trade history objects), create clean minimal versions. Here is the structure of a minimal `.chr` file:

```
<chart>
id=1
symbol=XAUUSD.s
description=Gold US Dollar
period_type=0
period_size=5
digits=2
tick_size=0.000000
scale=16
mode=1
fore=0
grid=1
volume=1
scroll=1
shift=0
ticker=1
background_color=0
foreground_color=16777215
barup_color=65280
bardown_color=65280
bullcandle_color=0
bearcandle_color=16777215
chartline_color=65280
windows_total=1

<expert>
name=YourEAName
path=Experts\YourEAName.ex5
expertmode=1
<inputs>
FileName=signal.json
PollIntervalMs=2000
Slippage=10
EnableTrading=true
</inputs>
</expert>

<window>
height=100.000000
objects=0

<indicator>
name=Main
path=
apply=1
show_data=1
scale_inherit=0
expertmode=0
fixed_height=-1
</indicator>
</window>
</chart>
```

Key fields:
- `symbol` — the trading symbol (e.g. `XAUUSD.s`, `EURUSD.s`)
- `period_size` — timeframe in minutes (1=M1, 5=M5, 60=H1)
- `expertmode=1` — **critical**: enables "Allow Algo Trading" for this EA
- `name` / `path` — EA name and path (without `.ex5` extension in name)
- `<inputs>` — EA input parameters matching your EA's `input` variables

Create `chart01.chr` for your first EA:

```bash
nano "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/PUPrime_EAs/chart01.chr"
```

Also create `order.wnd` (required by MT5, can be empty):

```bash
touch "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/PUPrime_EAs/order.wnd"
```

---

## 9. Configure common.ini

MT5 reads `common.ini` to determine which chart profile to load on startup.

> **Encoding note:** MT5 writes `common.ini` in UTF-16 LE. However it reads the `ProfileLast` setting correctly as long as the file is written consistently. The safest approach is to write it in ASCII — MT5 will rewrite it in its own format on next startup but will preserve the `ProfileLast` setting by reading it from `live.ini` instead (see next section).

The critical setting is `ProfileLast` which tells MT5 which chart profile to load:

```bash
cat "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/Config/common.ini"
```

You should see (after first startup with the correct `live.ini`):

```ini
[Common]
Environment=<hardware_fingerprint>
[Charts]
ProfileLast=PUPrime_EAs
```

MT5 regenerates the `Environment` value automatically — do not try to set or preserve it manually.

---

## 10. Configure live.ini

The `live.ini` file is passed to MT5 at startup and controls broker login, profile loading, and EA startup.

> **Critical:** Must be written in **ASCII with no BOM**. Use Python to write it:

```bash
python3 -c "
content = (
    '[Common]\r\n'
    'Login=YOUR_ACCOUNT_NUMBER\r\n'
    'Password=YOUR_PASSWORD\r\n'
    'Server=YOUR_BROKER_SERVER\r\n'
    '\r\n'
    '[StartUp]\r\n'
    'Profile=PUPrime_EAs\r\n'
    '\r\n'
    '[Experts]\r\n'
    'Enabled=1\r\n'
)
with open('/home/ubuntu/.wine/drive_c/windows/temp/live.ini', 'w', encoding='ascii') as f:
    f.write(content)
print('Done')
"
```

### live.ini fields explained

| Field | Section | Purpose |
|---|---|---|
| `Login` | `[Common]` | MT5 account number |
| `Password` | `[Common]` | MT5 account password |
| `Server` | `[Common]` | Broker server name (exact, case-sensitive) |
| `Profile` | `[StartUp]` | Chart profile folder to load on startup |
| `Enabled=1` | `[Experts]` | Enables algo trading at terminal level |

### Finding your broker's exact server name

The server name must match exactly what your broker uses. Check it from your Windows MT5 login screen or from `servers.dat`:

```bash
strings "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/Config/servers.dat" | grep -i "your_broker"
```

---

## 11. Set Up Signal JSON Path

Create the Common Files folder that MT5 uses — this matches `C:\Users\...\AppData\Roaming\MetaQuotes\Terminal\Common\Files\` on Windows:

```bash
mkdir -p "/home/ubuntu/.wine/drive_c/users/ubuntu/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
```

Your Python script writes `signal.json` to:
```
/home/ubuntu/.wine/drive_c/users/ubuntu/AppData/Roaming/MetaQuotes/Terminal/Common/Files/signal.json
```

Your EA reads it using `FILE_COMMON` flag in `FileOpen()`, which maps to the same path automatically.

> **JSON encoding:** Write the JSON file with `encoding='utf-8'` in Python and read it in the EA with `FILE_ANSI` flag. This avoids the UTF-16 hieroglyphs issue.

---

## 12. Create MT5 Startup Script

```bash
nano /home/ubuntu/start-mt5-live.sh
```

```bash
#!/bin/bash

# Clean up accumulated charts from previous session
# (prevents chart windows accumulating across restarts)
rm -rf "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/Default/"
mkdir -p "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/Default/"

# Start MT5
DISPLAY=:99 WINEPREFIX=/home/ubuntu/.wine wine \
  "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" \
  /portable \
  "/config:C:\\windows\\temp\\live.ini"
```

Make it executable:

```bash
chmod +x /home/ubuntu/start-mt5-live.sh
```

> **Why delete Default/ on startup?** MT5 saves its current chart layout to the `Default` profile on exit. When killed by systemd it sometimes saves duplicate charts. Deleting before startup ensures it always loads from your named profile (`PUPrime_EAs`) cleanly.

---

## 13. Create systemd Services

### Why Wine services need special systemd settings

Wine's process model doesn't map cleanly onto systemd's default `Type=simple`. When `wine terminal64.exe` starts, it internally forks into child processes (`services.exe`, `explorer.exe`, `winedevice.exe`, the real MT5 GUI process, etc.). At some point the PID that systemd is tracking as "the service" exits normally (`status=0/SUCCESS`), even though the actual MT5 terminal is still alive under a different PID in the same cgroup.

systemd sees "the main process exited" and tears down every other process in the cgroup — `winedevice.exe` doesn't respond cleanly to SIGTERM, so systemd waits the default 90s (`stop-sigterm timed out`) then SIGKILLs it, showing:

```
Active: failed (Result: timeout)
...Killing process NNNN (winedevice.exe) with signal SIGKILL.
```

This is a race condition, not a crash — it explains why services sometimes run fine for an hour before failing.

**Two settings fix this:**

- **`RemainAfterExit=yes`** — when the tracked `ExecStart` process exits, systemd marks the unit `active (exited)` instead of tearing down the cgroup. The real Wine/MT5 process tree is left running undisturbed.
- **`KillMode=process`** — if the service is stopped, systemd only signals the specific tracked PID, not every process in the cgroup, avoiding the 90s timeout cycle.

**Side effect — stop/restart needs an explicit `ExecStop`:** With `RemainAfterExit=yes`, `systemctl stop` may have no live process left to signal, so the actual `terminal64.exe` keeps running (orphaned from systemd but still placing trades). A second `systemctl start` would then launch a duplicate terminal on the same live account. Fix: add `ExecStop` with `pkill` targeting each terminal's unique path.

> After any `stop`/`restart`, always verify no duplicate is running: `ps aux | grep terminal64`

> `active (exited)` in `systemctl status` is **normal and expected** for MT5 services — check the `CGroup:` section for a live `terminal64.exe` PID as the real health signal.

---

### Xvfb Service

```bash
sudo tee /etc/systemd/system/xvfb-mt5.service << 'EOF'
[Unit]
Description=Xvfb virtual display for MT5
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1024x768x24
Restart=always
User=ubuntu

[Install]
WantedBy=multi-user.target
EOF
```

### MT5 Service

```bash
sudo tee /etc/systemd/system/mt5-live.service << 'EOF'
[Unit]
Description=MetaTrader 5 Live
After=xvfb-mt5.service
Requires=xvfb-mt5.service

[Service]
User=ubuntu
ExecStart=/home/ubuntu/start-mt5-live.sh
ExecStop=/usr/bin/pkill -f "MetaTrader 5/terminal64.exe"
Restart=no
RemainAfterExit=yes
KillMode=process
Environment=DISPLAY=:99
Environment=WINEPREFIX=/home/ubuntu/.wine

[Install]
WantedBy=multi-user.target
EOF
```

### Signal Bot Service

```bash
sudo tee /etc/systemd/system/signal-bot.service << 'EOF'
[Unit]
Description=Telegram MT5 Signal Bot
After=network.target mt5-live.service

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/Projects/telegram-mt5-signal-bot
ExecStart=/home/ubuntu/Projects/telegram-mt5-signal-bot/venv/bin/python3 src/llm_telegram_signal2json_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

> `ExecStart` points directly to the venv Python binary — no need for `source activate`.

---

## 14. Enable and Start All Services

```bash
sudo systemctl daemon-reload
sudo systemctl enable xvfb-mt5 mt5-live signal-bot
sudo systemctl start xvfb-mt5
sudo systemctl start mt5-live
sudo systemctl start signal-bot
```

---

## 15. Verify Everything is Running

```bash
sudo systemctl status xvfb-mt5
sudo systemctl status mt5-live
sudo systemctl status signal-bot
```

The signal bot should show `active (running)`. The MT5 services (`mt5-live`, `mt5-vantage`) will show `active (exited)` — this is **normal and expected** due to Wine's process model. Verify MT5 is actually running by checking the `CGroup:` section for a live `terminal64.exe` process:

```bash
sudo systemctl status mt5-live
# Look for terminal64.exe under CGroup: — that confirms MT5 is alive
# active (exited) at the top is normal, not a failure
```

Check MT5 logs to confirm broker connection and EA loading:

```bash
cat "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/logs/$(ls -t '/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/logs/' | head -1)"
```

Look for these lines confirming success:

```
Network    'YOUR_ACCOUNT': authorized on YOUR_BROKER through ...
Network    'YOUR_ACCOUNT': terminal synchronized with ...: X positions, X orders, X symbols
Network    'YOUR_ACCOUNT': trading has been enabled
Experts    expert YourEA (SYMBOL,TIMEFRAME) loaded successfully
```

Check MQL5 EA logs:

```bash
cat "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/logs/$(ls -t '/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/logs/' | head -1)"
```

Take a screenshot of the virtual display to visually verify:

```bash
DISPLAY=:99 scrot /tmp/mt5_check.png
scp ubuntu@your-vps-ip:/tmp/mt5_check.png ~/Desktop/
```

---

## 16. Python Signal Bot Service

The Python script listens to a Telegram channel, parses signals using an Ollama LLM (cloud model), and writes `signal.json` to the MT5 Common Files path.

### Signal JSON format

```json
{
  "symbol": "XAUUSD.s",
  "order_type": "BUY",
  "entry": 3350.00,
  "tp1": 3360.00,
  "tp2": 3375.00,
  "tp3": 3395.00,
  "sl": 3330.00,
  "volume": 0.01,
  "status": "new",
  "timestamp": "2026-07-10T12:00:00+02:00"
}
```

### Status lifecycle

- Python writes `"status": "new"` when a signal arrives
- EA reads the file, places orders, then overwrites with `"status": "done"`
- EA skips files where `status != "new"` to prevent re-processing

### File reading in the EA

Use `FILE_ANSI | FILE_COMMON` flags in `FileOpen()` to correctly read UTF-8 JSON written by Python:

```mql5
int fh = FileOpen("signal.json", FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
```

---

## 17. Running Multiple MT5 Instances

You can run a second broker (e.g. Vantage Markets) in parallel using a completely separate Wine prefix and virtual display. Everything is isolated — registry, config files, display, and systemd services.

### Second instance setup

| Setting | PUPrime (Instance 1) | Vantage (Instance 2) |
|---|---|---|
| Wine prefix | `~/.wine` | `~/.wine-vantage` |
| Xvfb display | `:99` | `:98` |
| Startup script | `start-mt5-live.sh` | `start-mt5-vantage.sh` |
| live.ini | `~/.wine/drive_c/windows/temp/live.ini` | `~/.wine-vantage/drive_c/windows/temp/live-vantage.ini` |
| systemd Xvfb | `xvfb-mt5.service` | `xvfb-vantage.service` |
| systemd MT5 | `mt5-live.service` | `mt5-vantage.service` |

### Install second MT5 instance

```bash
# Download broker installer to VPS
scp "C:\Downloads\vantage5setup.exe" ubuntu@your-vps-ip:/home/ubuntu/vantage5setup.exe

# Start Xvfb on display :98
Xvfb :98 -screen 0 1024x768x24 &

# Install into separate Wine prefix
DISPLAY=:98 WINEPREFIX=/home/ubuntu/.wine-vantage wine /home/ubuntu/vantage5setup.exe /auto

# Check installation folder name
ls /home/ubuntu/.wine-vantage/drive_c/Program\ Files/
```

### Startup script for second instance

```bash
nano /home/ubuntu/start-mt5-vantage.sh
```

```bash
#!/bin/bash

# Clean up accumulated charts
rm -rf "/home/ubuntu/.wine-vantage/drive_c/Program Files/Vantage Markets MT5 Terminal/MQL5/Profiles/Charts/Default/"
mkdir -p "/home/ubuntu/.wine-vantage/drive_c/Program Files/Vantage Markets MT5 Terminal/MQL5/Profiles/Charts/Default/"

# Start MT5
DISPLAY=:98 WINEPREFIX=/home/ubuntu/.wine-vantage wine \
  "/home/ubuntu/.wine-vantage/drive_c/Program Files/Vantage Markets MT5 Terminal/terminal64.exe" \
  /portable \
  "/config:C:\\windows\\temp\\live-vantage.ini"
```

```bash
chmod +x /home/ubuntu/start-mt5-vantage.sh
```

### systemd services for second instance

```bash
sudo tee /etc/systemd/system/xvfb-vantage.service << 'EOF'
[Unit]
Description=Xvfb virtual display for Vantage MT5
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :98 -screen 0 1024x768x24
Restart=always
User=ubuntu

[Install]
WantedBy=multi-user.target
EOF
```

```bash
sudo tee /etc/systemd/system/mt5-vantage.service << 'EOF'
[Unit]
Description=MetaTrader 5 Vantage
After=xvfb-vantage.service
Requires=xvfb-vantage.service

[Service]
User=ubuntu
ExecStart=/home/ubuntu/start-mt5-vantage.sh
ExecStop=/usr/bin/pkill -f "Vantage Markets MT5 Terminal/terminal64.exe"
Restart=no
RemainAfterExit=yes
KillMode=process
Environment=DISPLAY=:98
Environment=WINEPREFIX=/home/ubuntu/.wine-vantage

[Install]
WantedBy=multi-user.target
EOF
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable xvfb-vantage mt5-vantage
sudo systemctl start xvfb-vantage mt5-vantage
```

> **Service template for additional instances:** Every MT5 service file must include `RemainAfterExit=yes`, `KillMode=process`, and a unique `ExecStop` pkill path matching that instance's terminal folder name. The `ExecStop` path fragment must be unique enough to match only that specific instance's `terminal64.exe` — use the broker folder name (e.g. `"Vantage Markets MT5 Terminal/terminal64.exe"` vs `"MetaTrader 5/terminal64.exe"`).

> **Note on window IDs:** Both MT5 instances may show the same window ID (e.g. `10485761`) when queried with `xdotool`. This is normal — X window IDs are only unique within a single display. Since every xdotool command specifies `DISPLAY=:98` or `DISPLAY=:99` explicitly, there is no conflict.

---

## 18. Running Multiple MT5 Instances Under One Wine Prefix

A single Wine prefix can host more than one MT5 terminal install. The prefix just provides the shared Windows environment (registry, system DLLs) — it's not tied to a single account or terminal folder. Each running terminal still needs its **own installation folder** and its **own Xvfb display**.

This is useful when you want to run two accounts from the same broker (e.g. two Vantage accounts) without creating a whole new Wine prefix.

### Separate prefix vs shared prefix

| | Separate prefix | Shared prefix |
|---|---|---|
| Setup effort | Higher (full reinstall) | Lower (folder copy) |
| Isolation | Full — own `wineserver` | Shared `wineserver` |
| Failure risk | Fully independent | One `wineserver` crash affects both |
| Use case | Different brokers | Same broker, different accounts |

### Step 1 — Copy the terminal folder (no reinstall needed)

MT5 under Wine is mostly self-contained in its install folder. A straight folder copy works:

```bash
cp -r "/home/ubuntu/.wine-vantage/drive_c/Program Files/Vantage Markets MT5 Terminal" \
      "/home/ubuntu/.wine-vantage/drive_c/Program Files/MetaTrader 5 - Igor"
```

### Step 2 — Clear stale session data from the copy

The copy will otherwise try to reconnect using the source account's session:

```bash
cd "/home/ubuntu/.wine-vantage/drive_c/Program Files/MetaTrader 5 - Igor"
rm -rf config/*.ini logs/* MQL5/Logs/*
```

Keep the `MQL5` folder structure itself — the signal bot writes into `MQL5/Files` and the EA reads from there.

### Step 3 — Check available display numbers

```bash
ls -la /tmp/.X*-lock
ps aux | grep -i xvfb
```

Pick a free display number (e.g. `:97` if `:98` and `:99` are already in use).

### Step 4 — Create Xvfb service for the new display

```bash
sudo tee /etc/systemd/system/xvfb-igor.service << 'SVCEOF'
[Unit]
Description=Xvfb virtual display for Igor MT5
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :97 -screen 0 1024x768x24
Restart=always
User=ubuntu

[Install]
WantedBy=multi-user.target
SVCEOF
```

### Step 5 — Create live.ini for the new instance

```bash
python3 -c "
content = (
    '[Common]\r\n'
    'Login=YOUR_IGOR_ACCOUNT\r\n'
    'Password=YOUR_IGOR_PASSWORD\r\n'
    'Server=YOUR_BROKER_SERVER\r\n'
    '\r\n'
    '[StartUp]\r\n'
    'Profile=Igor_EAs\r\n'
    '\r\n'
    '[Experts]\r\n'
    'Enabled=1\r\n'
)
with open('/home/ubuntu/.wine-vantage/drive_c/windows/temp/live-igor.ini', 'w', encoding='ascii') as f:
    f.write(content)
print('Done')
"
```

### Step 6 — Create startup script

```bash
nano /home/ubuntu/start-mt5-igor.sh
```

```bash
#!/bin/bash

# Clean up accumulated charts
rm -rf "/home/ubuntu/.wine-vantage/drive_c/Program Files/MetaTrader 5 - Igor/MQL5/Profiles/Charts/Default/"
mkdir -p "/home/ubuntu/.wine-vantage/drive_c/Program Files/MetaTrader 5 - Igor/MQL5/Profiles/Charts/Default/"

# Start MT5 — same WINEPREFIX as Vantage, different display and executable path
DISPLAY=:97 WINEPREFIX=/home/ubuntu/.wine-vantage wine \
  "/home/ubuntu/.wine-vantage/drive_c/Program Files/MetaTrader 5 - Igor/terminal64.exe" \
  /portable \
  "/config:C:\\windows\\temp\\live-igor.ini"
```

```bash
chmod +x /home/ubuntu/start-mt5-igor.sh
```

### Step 7 — Create MT5 service

```bash
sudo tee /etc/systemd/system/mt5-igor.service << 'SVCEOF'
[Unit]
Description=MetaTrader 5 Igor
After=xvfb-igor.service
Requires=xvfb-igor.service

[Service]
User=ubuntu
ExecStart=/home/ubuntu/start-mt5-igor.sh
ExecStop=/usr/bin/pkill -f "MetaTrader 5 - Igor/terminal64.exe"
Restart=no
RemainAfterExit=yes
KillMode=process
Environment=DISPLAY=:97
Environment=WINEPREFIX=/home/ubuntu/.wine-vantage

[Install]
WantedBy=multi-user.target
SVCEOF
```

Note that `WINEPREFIX` is the same as `mt5-vantage.service` — only `DISPLAY` and `ExecStart`/`ExecStop` paths differ.

### Step 8 — Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable xvfb-igor mt5-igor
sudo systemctl start xvfb-igor mt5-igor
```

### Shared prefix caveat

Vantage and Igor share `.wine-vantage` and therefore share a single `wineserver` process (verify with `ps aux | grep wineserver`). This doesn't add CPU/memory overhead — each terminal runs as its own independent process — but if that shared `wineserver` hangs or crashes, it can affect both terminals simultaneously. The PUPrime instance running under `.wine` is fully isolated from this risk.

### Signal file isolation

Each instance has its own `MQL5/Files` path inside its install folder. If your EA uses `FILE_COMMON`, both instances share the same Common Files folder under the prefix — use different filenames per instance to avoid conflicts:

| Instance | Signal JSON (FILE_COMMON path) |
|---|---|
| Vantage | `signal_vantage.json` |
| Igor | `signal_igor.json` |

> **Warning:** If two EAs under the same prefix both use `FILE_COMMON` with the same filename, they read and overwrite each other's signal file.

---

## 19. Running Multiple EAs on One MT5 Instance

To run multiple EAs simultaneously on one MT5 instance, create one `.chr` file per EA in your profile folder. Each `.chr` represents one chart window.

### Example: two EAs on PUPrime

```bash
ls "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Profiles/Charts/PUPrime_EAs/"
# chart01.chr  ← ForexeroSignalExecutor on XAUUSD.s M5
# chart02.chr  ← SignalExecutorFromJson3 on XAUUSD.s M1
# order.wnd
```

`chart02.chr` example for the second EA:

```
<chart>
id=2
symbol=XAUUSD.s
description=Gold US Dollar
period_type=0
period_size=1
digits=2
tick_size=0.000000
scale=16
mode=1
fore=0
grid=1
volume=1
scroll=1
shift=0
ticker=1
background_color=0
foreground_color=16777215
barup_color=65280
bardown_color=65280
bullcandle_color=0
bearcandle_color=16777215
chartline_color=65280
windows_total=1

<expert>
name=SignalExecutorFromJson3
path=Experts\SignalExecutorFromJson3.ex5
expertmode=1
<inputs>
FileName=signal_zones.json
PollIntervalMs=2000
Slippage=10
</inputs>
</expert>

<window>
height=100.000000
objects=0

<indicator>
name=Main
path=
apply=1
show_data=1
scale_inherit=0
expertmode=0
fixed_height=-1
</indicator>
</window>
</chart>
```

Each EA reads its own separate JSON file (`signal.json`, `signal_zones.json` etc.) so they don't interfere with each other.

> **Important:** Do not try to use `[StartUp1]`, `[StartUp2]` sections in `live.ini` — MT5 only reads `[StartUp]` and ignores numbered variants. The `.chr` profile approach is the correct method for multiple EAs.

---

## 20. Key Learnings and Gotchas

### Wine / Hangover

| Issue | Solution |
|---|---|
| `nodrv_CreateWindow` error | Xvfb not running or wrong display number |
| `kernel32.dll` shows x86_64 | Wrong Wine prefix — wipe and rebuild with Hangover |
| MT5 not found after install | Wait 60 seconds after `/auto` install before checking |
| `servers.dat` missing broker | Copy from Windows MT5 installation |

### systemd and Wine process model

| Symptom | Cause | Fix |
|---|---|---|
| Service shows `failed (Result: timeout)` | systemd kills Wine cgroup after tracked PID exits | Add `RemainAfterExit=yes` and `KillMode=process` |
| `active (exited)` in status | Normal Wine behaviour — tracked PID exited but MT5 is alive | Check `CGroup:` for `terminal64.exe` instead |
| `systemctl stop` doesn't kill MT5 | No live tracked PID to signal | Add `ExecStop=/usr/bin/pkill -f "<path>/terminal64.exe"` |
| Duplicate MT5 on same account after restart | `stop` didn't kill old instance, `start` launched second | Always run `ps aux | grep terminal64` after restart to confirm clean state |
| Service shows `status=203/EXEC` | Wrapper script not executable | `chmod +x /home/ubuntu/start-mt5-*.sh` |

### ini file encoding

| File | Required encoding | Notes |
|---|---|---|
| `live.ini` | ASCII, no BOM | Use Python `encoding='ascii'` to write |
| `common.ini` | Written by MT5 in UTF-16 LE | Do not write manually — MT5 overwrites it |
| `live-vantage.ini` | ASCII, no BOM | Same as live.ini |

### Algo Trading / AutoTrading

- `AutoTrading=1` in `live.ini` — **does not work** under Wine, ignored silently
- `AllowLiveTrading=1` in `[StartUp]` — **does not work** under Wine, ignored silently
- `ExpertAdvisorEnabled=1` in `common.ini` — **does not work** reliably, MT5 overwrites the file
- **The solution that works:** `expertmode=1` in the `.chr` profile file + `[Experts] Enabled=1` in `live.ini`

### Chart accumulation

Without cleanup, MT5 accumulates chart windows across restarts because it saves the current layout on exit. Fix: delete `MQL5/Profiles/Charts/Default/` contents in the startup script before launching MT5.

### JSON file encoding

- Python must write signal JSON with `encoding='utf-8'`
- EA must read with `FILE_ANSI` flag (not `FILE_UNICODE`)
- Without `FILE_ANSI`, the EA reads the file as garbled hieroglyphs

### MT5 log locations

| Log type | Path |
|---|---|
| Terminal logs | `~/.wine/drive_c/Program Files/MetaTrader 5/logs/` |
| EA / MQL5 logs | `~/.wine/drive_c/Program Files/MetaTrader 5/MQL5/logs/` |

---

## 21. Useful Commands

```bash
# Check all service statuses
sudo systemctl status xvfb-mt5 mt5-live signal-bot

# Restart all services
sudo systemctl restart xvfb-mt5 mt5-live signal-bot

# View live MT5 terminal log
tail -f "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/logs/$(ls -t '/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/logs/' | head -1)"

# View live EA log
tail -f "/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/logs/$(ls -t '/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/logs/' | head -1)"

# View signal bot logs
journalctl -u signal-bot -f

# Check if MT5 process is running
ps aux | grep terminal64

# Check signal.json is being written
ls -la "/home/ubuntu/.wine/drive_c/users/ubuntu/AppData/Roaming/MetaQuotes/Terminal/Common/Files/"

# Take screenshot of virtual display
DISPLAY=:99 scrot /tmp/mt5_check.png

# Find MT5 window ID
DISPLAY=:99 xdotool search --name "" 2>/dev/null | while read wid; do
  name=$(DISPLAY=:99 xdotool getwindowname $wid 2>/dev/null)
  if [ -n "$name" ]; then echo "$wid: $name"; fi
done

# Write live.ini in correct ASCII encoding
python3 -c "
content = (
    '[Common]\r\n'
    'Login=YOUR_ACCOUNT\r\n'
    'Password=YOUR_PASSWORD\r\n'
    'Server=YOUR_BROKER_SERVER\r\n'
    '\r\n'
    '[StartUp]\r\n'
    'Profile=PUPrime_EAs\r\n'
    '\r\n'
    '[Experts]\r\n'
    'Enabled=1\r\n'
)
with open('/home/ubuntu/.wine/drive_c/windows/temp/live.ini', 'w', encoding='ascii') as f:
    f.write(content)
print('Done')
"

# Verify live.ini is ASCII (first bytes should be 5b 43 6f 6d = [Com)
hexdump -C /home/ubuntu/.wine/drive_c/windows/temp/live.ini | head -3
```

---

## Architecture Summary

| Component | Technology | Auto-start |
|---|---|---|
| Virtual display (PUPrime) | Xvfb on `:99` | `xvfb-mt5.service` |
| MetaTrader 5 (PUPrime) | Hangover Wine 11.4 + ARM64 | `mt5-live.service` |
| Virtual display (Vantage) | Xvfb on `:98` | `xvfb-vantage.service` |
| MetaTrader 5 (Vantage) | Hangover Wine 11.4 + ARM64 | `mt5-vantage.service` |
| Signal bot | Python 3 + venv | `signal-bot.service` |

All services start automatically on reboot in the correct dependency order. The full pipeline runs 24/7 headlessly with no screen or human interaction required.