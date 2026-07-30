//+------------------------------------------------------------------+
//|  ForexeroSignalExecutor.mq5                                       |
//|  Reads signal.json from Common\Files and places 3 orders        |
//|  Requires: JSON.mqh in MQL5\Include\                            |
//+------------------------------------------------------------------+
#property copyright "Andre"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <JSON\index.mqh>

// ---- Inputs -------------------------------------------------------
input string   FileName       = "signal.json";
input int      PollIntervalMs = 2000;
input int      Slippage       = 10;
input bool     EnableTrading  = true;

// ---- Globals ------------------------------------------------------
CTrade   trade;
string   lastProcessedTimestamp = "";

//+------------------------------------------------------------------+
int OnInit()
{
   Print("Terminal trade allowed: ", TerminalInfoInteger(TERMINAL_TRADE_ALLOWED));
   Print("EA trade allowed: ", MQLInfoInteger(MQL_TRADE_ALLOWED));

   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);
   EventSetMillisecondTimer(PollIntervalMs);
   Print("ForexeroSignalExecutor started. Polling every ", PollIntervalMs, " ms.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTick()                   { ProcessSignalFile(); }
void OnTimer()                  { ProcessSignalFile(); }

//+------------------------------------------------------------------+
//| Simple deterministic string hash (djb2-style)                    |
//+------------------------------------------------------------------+
ulong HashTimestamp(string s)
{
   ulong h = 5381;
   int len = StringLen(s);
   for(int i = 0; i < len; i++)
      h = ((h << 5) + h) + StringGetCharacter(s, i); // h*33 + c
   return h;
}

//+------------------------------------------------------------------+
void ProcessSignalFile()
{
   if(!EnableTrading) return;

   // ---- Read file ------------------------------------------------
   int fh = FileOpen(FileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE) return;

   string raw = "";
   while(!FileIsEnding(fh))
      raw += FileReadString(fh) + "\n";
   FileClose(fh);

   if(StringLen(raw) < 10) return;

   // ---- Parse with JSON library ----------------------------------
   JSON::Object* j = new JSON::Object(raw);
   if(j == NULL) { Print("❌ JSON parse failed."); delete j; return; }

   string status = j.getString("status");
   if(status != "new") { delete j; return; }

   string timestamp = j.getString("timestamp");
   if(timestamp == lastProcessedTimestamp) { delete j; return; }

   string symbol     = j.getString("symbol");
   string order_type = j.getString("order_type");
   double entry      = j.getNumber("entry");
   double tp1        = j.getNumber("tp1");
   double tp2        = j.getNumber("tp2");
   double tp3        = j.getNumber("tp3");
   double sl         = j.getNumber("sl");
   double volume     = j.getNumber("volume");
   delete j;

   // ---- Validate -------------------------------------------------
   if(symbol == "" || order_type == "" || entry == 0 || sl == 0)
   {
      Print("⚠️  Invalid signal data — skipping.");
      MarkSignalDone();
      return;
   }

   Print("📨 Signal: ", symbol, " ", order_type,
         " Entry=", entry, " SL=", sl,
         " TP1=", tp1, " TP2=", tp2, " TP3=", tp3,
         " Vol=", volume);

   // ---- Select symbol --------------------------------------------
   if(!SymbolSelect(symbol, true))
   {
      Print("❌ Symbol not available: ", symbol);
      MarkSignalDone();
      return;
   }
   // Wait for symbol to be ready
   int attempts = 0;
   while(SymbolInfoDouble(symbol, SYMBOL_ASK) == 0 && attempts++ < 10)
      Sleep(500);

   ENUM_ORDER_TYPE otype = (order_type == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   // ---- Place 3 orders -------------------------------------------
   double tps[3] = { tp1, tp2, tp3 };
   int placed = 0;
   
   // One magic number per signal, derived from its timestamp.
   // Same signal -> same magic number every time -> lets you later
   // group TP1/TP2/TP3 positions together (e.g. for breakeven logic).
   ulong magic = 500000 + (HashTimestamp(timestamp) % 499999);
   trade.SetExpertMagicNumber(magic);
   // Print("🔖 Magic number for this signal: ", magic);

   for(int i = 0; i < 3; i++)
   {
      double price = (otype == ORDER_TYPE_BUY)
                     ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                     : SymbolInfoDouble(symbol, SYMBOL_BID);

      bool ok = trade.PositionOpen(symbol, otype, volume, price, sl, tps[i],
                                   "TP" + IntegerToString(i + 1));
      if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         Print("✅ TP", i+1, " placed. Ticket=", trade.ResultOrder());
         placed++;
      }
      else
         Print("❌ TP", i+1, " failed: ", trade.ResultComment(),
               " (retcode=", trade.ResultRetcode(), ")");
   }

   Print("📊 ", placed, "/3 orders placed for ", symbol, " ", order_type);

   lastProcessedTimestamp = timestamp;
   MarkSignalDone();
}

//+------------------------------------------------------------------+
void MarkSignalDone()
{
   // Read current file, replace "new" with "done", write back
   int fh = FileOpen(FileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE) return;
   string raw = "";
   while(!FileIsEnding(fh))
      raw += FileReadString(fh) + "\n";
   FileClose(fh);

   StringReplace(raw, "\"new\"", "\"done\"");

   fh = FileOpen(FileName, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, raw);
      FileClose(fh);
   }
}
//+------------------------------------------------------------------+
