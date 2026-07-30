import asyncio
import re
import json
import logging
from logging.handlers import TimedRotatingFileHandler
from datetime import datetime
from zoneinfo import ZoneInfo
from pathlib import Path

from telethon.sync import TelegramClient, events
from telethon.tl.types import PeerChannel
from dotenv import load_dotenv
import os

# === PATHS ===
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR      = PROJECT_ROOT / "src"
DATA_DIR     = PROJECT_ROOT / "data"
LOG_DIR      = PROJECT_ROOT / "logs"
SESSION_DIR  = DATA_DIR / "sessions"
CONFIG_DIR   = PROJECT_ROOT / "config"

LOG_DIR.mkdir(parents=True, exist_ok=True)
SESSION_DIR.mkdir(parents=True, exist_ok=True)

# Signal JSON output path (Vantage MT5 Common Files folder on Linux/Wine)
SIGNAL_PATH = Path(
    "/home/ubuntu/.wine-vantage/drive_c/users/ubuntu/AppData/"
    "Roaming/MetaQuotes/Terminal/Common/Files/signal.json"
)
SIGNAL_PATH.parent.mkdir(parents=True, exist_ok=True)

load_dotenv(CONFIG_DIR / ".env")

# === LOGGING ===
TZ = ZoneInfo("Europe/Berlin")
logging.Formatter.converter = lambda *args: datetime.now(TZ).timetuple()

log_file = LOG_DIR / "vantage_signal_bot.log"

file_handler = TimedRotatingFileHandler(
    filename=log_file,
    when="midnight",      # rotates at midnight (system time)
    interval=1,
    backupCount=10,        # keep last 10 rotated files, auto-delete older ones
    encoding="utf-8",
    utc=False              # doesn't matter much here if server is also UTC
)
file_handler.suffix = "%Y%m%d"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        file_handler,
        logging.StreamHandler()
    ]
)
logging.getLogger("telethon").setLevel(logging.WARNING)

# === CONFIGURATION ===
api_id       = int(os.getenv("API_ID"))
api_hash     = os.getenv("API_HASH")
channel      = PeerChannel(channel_id=1676632907)  # Forexero
# channel = 'https://t.me/+XbsN0jGOqVA4MWE6' # my test channel
session_name = str(SESSION_DIR / "forexero_session")
volume       = 0.01  # Volume per order (3 orders will be placed per signal)

# === HELPERS ===

def remove_emojis(text: str) -> str:
    emoji_pattern = re.compile(
        "["
        u"\U0001F600-\U0001F64F"
        u"\U0001F300-\U0001F5FF"
        u"\U0001F680-\U0001F6FF"
        u"\U0001F1E0-\U0001F1FF"
        u"\U00002500-\U00002BEF"
        u"\U00002702-\U000027B0"
        u"\U000024C2-\U0001F251"
        "]+",
        flags=re.UNICODE
    )
    return emoji_pattern.sub("", text).strip()


def normalize_symbol(raw: str) -> str:
    """
    Normalize symbol to MT5 format for Vantage:
    - Remove '/' separator  (EUR/USD -> EURUSD)
    - Uppercase
    - Append '+' suffix used by Vantage (EURUSD -> EURUSD+)
    Special case: XAUUSD for gold regardless of input format (XAU/USD, GOLD, etc.)
    """
    symbol = raw.replace("/", "").upper().strip()
    # Map common gold aliases
    if symbol in ("XAUUSD", "GOLD", "XAUUSD+"):
        return "XAUUSD+"
    return symbol + "+"


def parse_signal(text: str) -> dict | None:
    """
    Parse a signal message of the form:
        GBP/USD
        Direction: BUY
        Entry Price: 1.3378
        TP1     1.3398
        TP2     1.3421
        TP3     1.3445
        SL      1.3311
    Returns a dict or None if parsing fails.
    """
    lines = [remove_emojis(line).strip() for line in text.splitlines() if line.strip()]
    clean = "\n".join(lines)

    pattern = re.search(
        r"^(?P<symbol>[A-Z]{2,6}[/\s]?[A-Z]{0,3})\s*\n"
        r".*?Direction\s*[:\-]?\s*(?P<order_type>BUY|SELL)\s*\n"
        r".*?Entry\s*Price\s*[:\-]?\s*(?P<entry>\d+(?:\.\d+)?)\s*\n"
        r".*?TP1\s*[:\-]?\s*(?P<tp1>\d+(?:\.\d+)?)\s*\n"
        r".*?TP2\s*[:\-]?\s*(?P<tp2>\d+(?:\.\d+)?)\s*\n"
        r".*?TP3\s*[:\-]?\s*(?P<tp3>\d+(?:\.\d+)?)\s*\n"
        r".*?SL\s*[:\-]?\s*(?P<sl>\d+(?:\.\d+)?)",
        clean,
        re.IGNORECASE | re.DOTALL | re.MULTILINE
    )

    if not pattern:
        return None

    d = pattern.groupdict()
    return {
        "symbol":     normalize_symbol(d["symbol"]),
        "order_type": d["order_type"].upper(),
        "entry":      float(d["entry"]),
        "tp1":        float(d["tp1"]),
        "tp2":        float(d["tp2"]),
        "tp3":        float(d["tp3"]),
        "sl":         float(d["sl"]),
        "volume":     volume,
        "status":     "new",
        "timestamp":  datetime.now(TZ).isoformat(),
    }


def write_signal(signal: dict) -> None:
    """Write signal JSON atomically so the EA never reads a partial file."""
    tmp = SIGNAL_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(signal, indent=2), encoding="utf-8")
    tmp.replace(SIGNAL_PATH)
    logging.info(f"📝 Signal written to {SIGNAL_PATH}: {signal}")


# === EVENT HANDLER ===

async def handler(event):
    try:
        message = event.message.message
        if not message:
            return  # skip non-caption items in a media group/album
        logging.info(f"📨 New Telegram message received.")
        signal = parse_signal(message)
        if signal:
            logging.info(f"✅ Signal parsed: {signal}")
            write_signal(signal)
        else:
            logging.info("⚠️ Message did not match signal format — ignored.")
    except Exception as e:
        logging.exception(f"❌ Error processing message: {e}")


# === MAIN ===

async def main():
    client = TelegramClient(session_name, api_id, api_hash)
    await client.start()
    logging.info("📶 Telegram client started.")

    try:
        await client.get_entity(channel)
    except Exception as e:
        logging.exception(f"❌ Could not load channel: {e}")
        return

    client.add_event_handler(handler, events.NewMessage(chats=channel))
    logging.info("🟢 Listening for new signals on channel %s ...", channel.channel_id)
    await client.run_until_disconnected()


if __name__ == "__main__":
    while True:
        try:
            asyncio.run(main())
        except KeyboardInterrupt:
            logging.info("⛔ Bot stopped by user.")
            break
        except Exception as e:
            logging.exception("❌ Unexpected error. Restarting in 5 seconds...")
            import time
            time.sleep(5)