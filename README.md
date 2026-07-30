# telegram-mt5-signal-bot

Fully automated algorithmic trading pipeline that routes Telegram signals through a parser into MetaTrader 5 for live trade execution — running headlessly 24/7 on a free Oracle ARM64 VPS.

```
Telegram channel → Python (Ollama LLM) → signal.json → MT5 Expert Advisor → broker trades
```

## Features

- Listens to a Telegram channel for trading signals
- Parses signal text using an Ollama cloud LLM into structured JSON
- Writes parsed signal to a JSON file read by a MetaTrader 5 Expert Advisor
- EA places 3 orders per signal (TP1, TP2, TP3) with a shared SL
- Supports multiple broker accounts (PU Prime, Vantage Markets) running in parallel
- Runs headlessly on a free Oracle Cloud ARM64 VPS (Ubuntu)
- All components auto-start on reboot via systemd

## Repository Structure

```
telegram-mt5-signal-bot/
├── src/                          # Python signal bot scripts
│   ├── llm_telegram_signal2json_bot.py       # PUPrime signal zone bot
│   ├── telegram_mt5_signal_bot_gold.py       # PUPrime gold signal bot
│   └── telegram_mt5_signal_bot.py            # Vantage signal bot
├── config/
│   └── .env.example              # Environment variable template
├── mql5/
│   ├── Experts/                  # MT5 Expert Advisor source files (.mq5)
|   ├── Include/                  # MT5 library JSON/index.mqh
│   └── Profiles/                 # MT5 chart profile templates (.chr)
├── docs/
│   └── MT5_VPS_SETUP.md          # Full VPS setup guide
├── data/
│   └── sessions/                 # Telegram session files (gitignored)
├── logs/                         # Log files (gitignored)
├── requirements.txt              # Python dependencies
├── .gitignore
└── README.md
```

## Quick Start

### 1. Clone and install dependencies

```bash
git clone https://github.com/apakle/telegram-mt5-signal-bot.git
cd telegram-mt5-signal-bot
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure environment

```bash
cp config/.env.example config/.env
nano config/.env
# Fill in your Telegram API credentials and channel IDs
```

### 3. VPS / MT5 setup

See [docs/MT5_VPS_SETUP.md](docs/MT5_VPS_SETUP.md) for the complete guide to deploying MetaTrader 5 headlessly on an Oracle ARM64 VPS.

### 4. Deploy Expert Advisors

Compile the `.mq5` files in `mql5/Experts/` using MetaEditor on Windows, then deploy the compiled `.ex5` files to your VPS:

```bash
scp mql5/Experts/ForexeroSignalExecutor.ex5 ubuntu@your-vps-ip:"/home/ubuntu/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
```

### 5. Start services on VPS

```bash
sudo systemctl start xvfb-mt5 mt5-live signal-bot
```

## Architecture

| Component | Technology | Purpose |
|---|---|---|
| Signal listener | Python + Telethon | Listens to Telegram channel |
| LLM parser | Ollama (cloud model) | Extracts signal fields from message text |
| Signal bridge | JSON file | Passes parsed signal to MT5 |
| Trade executor | MQL5 Expert Advisor | Reads JSON, places 3 orders |
| Broker 1 | PU Prime (MT5) | Live trading via `.wine` prefix |
| Broker 2 | Vantage Markets (MT5) | Live trading via `.wine-vantage` prefix |
| Infrastructure | Oracle ARM64 VPS, Ubuntu, systemd, Xvfb, Hangover Wine | Headless 24/7 execution |

## Signal Format

Signals are received from a Telegram channel in the following format:

```
GBP/USD
Direction: BUY
Entry Price: 1.3378
TP1     1.3398
TP2     1.3421
TP3     1.3445
SL      1.3311
```

The LLM parser extracts these fields and writes a structured JSON file:

```json
{
  "symbol": "GBPUSD.s",
  "order_type": "BUY",
  "entry": 1.3378,
  "tp1": 1.3398,
  "tp2": 1.3421,
  "tp3": 1.3445,
  "sl": 1.3311,
  "volume": 0.01,
  "status": "new",
  "timestamp": "2026-07-10T12:00:00+02:00"
}
```

## Environment Variables

| Variable | Description |
|---|---|
| `API_ID` | Telegram API ID |
| `API_HASH` | Telegram API hash |

Get your Telegram API credentials at [https://my.telegram.org](https://my.telegram.org).

## Notes

- `.ex5` compiled EA files are **not** included in `mql5/Experts/`. The `.mq5` source files are provided for compilation using the MetaTrader 5 Desktop application before deployment to the VPS.
- Telegram session files in `data/sessions/` are gitignored — generate them by running the bot once interactively.
- Log files in `logs/` are gitignored.
- Broker credentials are never stored in this repo — use `config/.env` (gitignored).

## License

MIT
