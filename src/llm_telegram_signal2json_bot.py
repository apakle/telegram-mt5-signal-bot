import json
import logging
from logging.handlers import TimedRotatingFileHandler
import re
from datetime import datetime
from zoneinfo import ZoneInfo

from ollama import chat
from telethon import TelegramClient, events
from telethon.tl.types import PeerChannel

from pathlib import Path

from dotenv import load_dotenv
import os

PROJECT_ROOT = Path(__file__).resolve().parent.parent

SRC_DIR = PROJECT_ROOT / "src"
DATA_DIR = PROJECT_ROOT / "data"
LOG_DIR = PROJECT_ROOT / "logs"
SESSION_DIR = DATA_DIR / "sessions"
CONFIG_DIR = PROJECT_ROOT / "config"

LOG_DIR.mkdir(parents=True, exist_ok=True)
SESSION_DIR.mkdir(parents=True, exist_ok=True)

load_dotenv(CONFIG_DIR / ".env")

# ── Logging ───────────────────────────────────────────────────────────────────
TZ = ZoneInfo("Europe/Berlin")

logging.Formatter.converter = lambda *args: datetime.now(TZ).timetuple()

log_file = LOG_DIR / "signal_zones_bot.log"

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
    format="%(asctime)s  [%(levelname)s]  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(),
        file_handler,
    ],
)
logging.getLogger("telethon").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────────────
API_ID       = int(os.getenv("API_ID"))
API_HASH     = os.getenv("API_HASH")
CHANNEL      = PeerChannel(channel_id=2386108670) # BARE PIPS GOLD VIP
# CHANNEL      = PeerChannel(channel_id=2661711862) # my test channel
SESSION_NAME = SESSION_DIR / "session_name_gold_llm"

SYMBOL       = "XAUUSD.s"
MODEL        = "minimax-m3:cloud"
SIGNAL_FILE = Path("/home/ubuntu/.wine/drive_c/users/ubuntu/AppData/Roaming/MetaQuotes/Terminal/Common/Files/signal_zones.json")

# ── System prompt ─────────────────────────────────────────────────────────────
SYSTEM_PROMPT = """You are a financial signal parser. Extract trading zones from messages about buying and selling zones for a ticker.
Return ONLY a valid JSON array with no markdown, no explanation. Each zone object must have exactly these fields:
- "symbol": string (use the provided default if not mentioned in the message)
- "order_type": "BUY" or "SELL"
- "entry_min": number (integer or decimal, e.g. 4066.50)
- "entry_max": number (integer or decimal, e.g. 4068.50)

Rules:
1. Buy Zones / Support areas → order_type = "BUY"
2. Sell Zones / Resistance areas → order_type = "SELL"
3. For ranges like "4398/02": entry_min=4398, entry_max=4402 (NOT 4302).
   The suffix replaces the last N digits of the prefix. If the result would be <= entry_min, increment the prefix by 1.
   E.g. 4398/02 -> "43"+"02"=4302 < 4398, so carry: "44"+"02" = 4402
4. If symbol is not mentioned, use the default symbol provided in the user message.
5. If risk level is mentioned (Low/Mid/High Risk), ignore it.
6. If zones are listed without explicit BUY/SELL labels but described as "support" -> BUY, "resistance" -> SELL.
7. Return [] if no valid zones are found.
8. Ranges may use "/", "-", or "to" as separator: 4420/24, 3770-72, 4066.50 to 4068.50
"""

# ── Pre-filter ────────────────────────────────────────────────────────────────
_RANGE_PATTERN = re.compile(
    r"\d{3,6}(?:\.\d+)?"
    r"\s*(?:/|-|to)\s*"
    r"\d{2,6}(?:\.\d+)?",
    re.IGNORECASE,
)
_DIRECTION_PATTERN = re.compile(
    r"\b(?:buy|sell|support|resistance)\b",
    re.IGNORECASE,
)


def is_signal(text: str) -> bool:
    return bool(_RANGE_PATTERN.search(text)) and bool(_DIRECTION_PATTERN.search(text))


# ── Parser ────────────────────────────────────────────────────────────────────
def parse_signal(text: str, symbol: str = SYMBOL) -> list[dict]:
    resp = chat(
        model=MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": f"Default symbol: {symbol}\n\n{text}"},
        ],
    )
    raw = re.sub(r"^```[a-z]*\n?|\n?```$", "", resp.message.content.strip())
    zones = json.loads(raw)
    if isinstance(zones, dict):
        zones = next((v for v in zones.values() if isinstance(v, list)), [])
    return [z for z in zones if z.get("entry_max", 0) > z.get("entry_min", 0)]


# ── Persistence ───────────────────────────────────────────────────────────────
def save_signals(zones: list[dict], path: Path = SIGNAL_FILE) -> None:
    payload = {
        "timestamp": datetime.now(ZoneInfo("Europe/Berlin")).strftime("%Y-%m-%d %H:%M:%S"),
        "zones": zones,
    }
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    log.info("✅ Signal written to %s", path)


# ── Pipeline ──────────────────────────────────────────────────────────────────
def process(text: str, symbol: str = SYMBOL, path: Path = SIGNAL_FILE) -> list[dict]:
    if not is_signal(text):
        log.info("⚠️ No valid zone message — skipped.")
        return []
    try:
        zones = parse_signal(text, symbol)
    except Exception:
        log.exception("❌ Failed to parse signal")
        return []
    if zones:
        log.info("✅ Signal received: %s", zones)
        save_signals(zones, path)
    return zones


# ── Telegram listener ─────────────────────────────────────────────────────────
def main() -> None:
    START_TIME = datetime.now(ZoneInfo("UTC"))
    client = TelegramClient(str(SESSION_NAME), API_ID, API_HASH)

    @client.on(events.NewMessage(chats=CHANNEL))
    async def handler(event) -> None:
        if event.message.date < START_TIME:
            return                      # ignore messages sent before startup
        text = event.message.text
        if text:
            process(text)

    with client:
        log.info("📶 Telegram client started — listening on channel %s ...", CHANNEL.channel_id)
        try:
            client.run_until_disconnected()
        except KeyboardInterrupt:
            pass

    log.info("⛔ Bot stopped by user.")


if __name__ == "__main__":
    main()