//+------------------------------------------------------------------+
//|  SignalExecutor.mq5                                              |
//|  BarePips zone-based rejection EA for XAUUSD                    |
//|                                                                  |
//|  State machine per zone:                                         |
//|    IDLE → TOUCHED → CONFIRMED → EXECUTED                        |
//|                                                                  |
//|  Confirmation logic (M5 primary, M1 early trigger):             |
//|    M5: first candle that closes outside zone after touch         |
//|    M1: same rule, faster — only used if M1 confirms first       |
//|                                                                  |
//|  SL = 6 pts from entry, TP = 4 pts from entry                  |
//+------------------------------------------------------------------+
#include <JSON\index.mqh>

//--- Inputs
input string          FileName        = "signal_zones.json"; // JSON file
input double          LotSize         = 0.01;                // Lot size
input double          SL_Points       = 6.0;                 // SL distance in $
input double          TP_Points       = 4.0;                 // TP distance in $
input bool            UseM1Trigger    = true;                // Enable M1 early trigger
input double          MinRangeM5      = 2.0;                 // Min M5 candle range to confirm (filters noise)
input double          MinRangeM1      = 0.5;                 // Min M1 candle range to confirm

//--- Zone states
enum ZONE_STATE
{
    STATE_IDLE      = 0, // zone not yet reached
    STATE_TOUCHED   = 1, // price wicked into zone, waiting for close outside
    STATE_EXECUTED  = 2  // trade placed, zone done
};

//--- Per-zone tracking
datetime  activeSignalTime = 0;
int       zoneCount        = 0;
ZONE_STATE zoneState[];   // state machine per zone
string    zoneSymbol[];
string    zoneOrderType[];
double    zoneEntryMin[];
double    zoneEntryMax[];
datetime  zoneTouchTime[]; // open time of the M5 candle that touched the zone
bool      newM5Bar = false; // true on first tick of a new M5 bar
bool      newM1Bar = false; // true on first tick of a new M1 bar

//+------------------------------------------------------------------+
//| Read JSON file                                                    |
//+------------------------------------------------------------------+
bool ReadSignal(string fileName, string &json_signal)
{
    static datetime lastErrorPrint = 0;
    static datetime lastEmptyPrint = 0;

    int handle = FileOpen(fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if(handle == INVALID_HANDLE)
    {
        if(TimeCurrent() - lastErrorPrint >= 120)
        {
            Print("❌ Cannot open JSON: ", fileName, " error=", GetLastError());
            lastErrorPrint = TimeCurrent();
        }
        return false;
    }

    json_signal = "";
    while(!FileIsEnding(handle))
        json_signal += FileReadString(handle);
    FileClose(handle);

    if(StringLen(json_signal) < 10)
    {
        if(TimeCurrent() - lastEmptyPrint >= 900)
        {
            Print("⚠️ JSON empty or corrupted");
            lastEmptyPrint = TimeCurrent();
        }
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Place market order                                                |
//+------------------------------------------------------------------+
void PlaceOrder(int zoneIdx)
{
    string          symbol    = zoneSymbol[zoneIdx];
    ENUM_ORDER_TYPE orderType = (StringFind(zoneOrderType[zoneIdx], "BUY") != -1)
                                ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

    double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
    double price = (orderType == ORDER_TYPE_BUY) ? ask : bid;
    double sl    = (orderType == ORDER_TYPE_BUY) ? price - SL_Points : price + SL_Points;
    double tp    = (orderType == ORDER_TYPE_BUY) ? price + TP_Points : price - TP_Points;

    MqlTradeRequest req; MqlTradeResult res;
    ZeroMemory(req); ZeroMemory(res);

    req.action       = TRADE_ACTION_DEAL;
    req.symbol       = symbol;
    req.volume       = LotSize;
    req.type         = orderType;
    req.price        = price;
    req.sl           = sl;
    req.tp           = tp;
    req.magic        = 0;
    req.comment      = "Zone" + IntegerToString(zoneIdx + 1);
    req.deviation    = 20;
    req.type_time    = ORDER_TIME_GTC;
    req.type_filling = ORDER_FILLING_IOC;

    if(!OrderSend(req, res))
        PrintFormat("❌ OrderSend failed | Zone=%d | retcode=%d", zoneIdx + 1, res.retcode);
    else
        PrintFormat("✅ Order placed | Zone=%d | %s | price=%.2f | SL=%.2f | TP=%.2f | ticket=%I64d",
                    zoneIdx + 1, zoneOrderType[zoneIdx], price, sl, tp, res.order);
}

//+------------------------------------------------------------------+
//| Check if price wicked into zone on this candle                   |
//+------------------------------------------------------------------+
bool CandleTouchedZone(string symbol, ENUM_TIMEFRAMES tf, int bar,
                       ENUM_ORDER_TYPE orderType, double entry_min, double entry_max)
{
    double high = iHigh(symbol, tf, bar);
    double low  = iLow (symbol, tf, bar);

    // Candle must overlap the zone. A candle fully beyond the zone is NOT a touch.
    return (low <= entry_max && high >= entry_min);
}

//+------------------------------------------------------------------+
//| Check if candle closed back outside zone (confirmation)          |
//| For SELL: close < entry_min AND bearish                         |
//| For BUY:  close > entry_max AND bullish                         |
//+------------------------------------------------------------------+
bool CandleConfirmsRejection(string symbol, ENUM_TIMEFRAMES tf, int bar,
                              ENUM_ORDER_TYPE orderType,
                              double entry_min, double entry_max,
                              double minRange)
{
    double high  = iHigh (symbol, tf, bar);
    double low   = iLow  (symbol, tf, bar);
    double open  = iOpen (symbol, tf, bar);
    double close = iClose(symbol, tf, bar);

    if((high - low) < minRange) return false; // ignore noise candles

    if(orderType == ORDER_TYPE_BUY)
    {
        // Wick into zone + bullish close above zone
        if(low > entry_max)    return false; // didn't touch zone
        if(close <= entry_max) return false; // didn't close above zone
        if(close <= open)      return false; // not bullish
    }
    else
    {
        // Wick into zone + bearish close below zone
        if(high < entry_min)   return false; // didn't touch zone
        if(close >= entry_min) return false; // didn't close below zone
        if(close >= open)      return false; // not bearish
    }

    return true;
}

//+------------------------------------------------------------------+
//| Process one zone through the state machine                       |
//+------------------------------------------------------------------+
void ProcessZone(int i)
{
    string          symbol    = zoneSymbol[i];
    ENUM_ORDER_TYPE orderType = (StringFind(zoneOrderType[i], "BUY") != -1)
                                ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    double entry_min = zoneEntryMin[i];
    double entry_max = zoneEntryMax[i];

    //------------------------------------------------------------------
    // STATE: IDLE — watch for zone touch on last closed M5 candle
    //------------------------------------------------------------------
    if(zoneState[i] == STATE_IDLE)
    {
        if(!newM5Bar) return; // evaluate once per closed M5 candle
        if(CandleTouchedZone(symbol, PERIOD_M5, 1, orderType, entry_min, entry_max))
        {
            zoneState[i]     = STATE_TOUCHED;
            zoneTouchTime[i] = iTime(symbol, PERIOD_M5, 1);

            double o = iOpen (symbol, PERIOD_M5, 1);
            double h = iHigh (symbol, PERIOD_M5, 1);
            double l = iLow  (symbol, PERIOD_M5, 1);
            double c = iClose(symbol, PERIOD_M5, 1);

            PrintFormat("📍 Zone touched [M5] | Zone=%d | %s | zone=[%.2f-%.2f] | time=%s | O=%.2f H=%.2f L=%.2f C=%.2f",
                        i + 1, zoneOrderType[i], entry_min, entry_max,
                        TimeToString(iTime(symbol, PERIOD_M5, 1), TIME_DATE|TIME_MINUTES),
                        o, h, l, c);

            // Also check if the touch candle itself already confirms (pin bar on M5)
            if(CandleConfirmsRejection(symbol, PERIOD_M5, 1, orderType,
                                       entry_min, entry_max, MinRangeM5))
            {
                PrintFormat("✅ M5 pin bar on touch candle | Zone=%d | Entering...", i + 1);
                PlaceOrder(i);
                zoneState[i] = STATE_EXECUTED;
            }
        }
        return;
    }

    //------------------------------------------------------------------
    // STATE: TOUCHED — wait for a candle to close outside the zone
    //------------------------------------------------------------------
    if(zoneState[i] == STATE_TOUCHED)
    {
        // --- M1 early trigger (bar[1] = last closed M1 candle)
        if(UseM1Trigger && newM1Bar && iTime(symbol, PERIOD_M1, 1) >= zoneTouchTime[i] + 300)
        {
            if(CandleConfirmsRejection(symbol, PERIOD_M1, 1, orderType,
                                       entry_min, entry_max, MinRangeM1))
            {
                double o = iOpen (symbol, PERIOD_M1, 1);
                double h = iHigh (symbol, PERIOD_M1, 1);
                double l = iLow  (symbol, PERIOD_M1, 1);
                double c = iClose(symbol, PERIOD_M1, 1);

                PrintFormat("✅ M1 rejection confirmed | Zone=%d | %s | zone=[%.2f-%.2f] | time=%s | O=%.2f H=%.2f L=%.2f C=%.2f",
                            i + 1, zoneOrderType[i], entry_min, entry_max,
                            TimeToString(iTime(symbol, PERIOD_M1, 1), TIME_DATE|TIME_MINUTES),
                            o, h, l, c);
                PlaceOrder(i);
                zoneState[i] = STATE_EXECUTED;
                return;
            }
        }

        // --- M5 primary confirmation (bar[1] = last closed M5 candle)
        if(newM5Bar && iTime(symbol, PERIOD_M5, 1) > zoneTouchTime[i] &&
           CandleConfirmsRejection(symbol, PERIOD_M5, 1, orderType,
                                   entry_min, entry_max, MinRangeM5))
        {
            double o = iOpen (symbol, PERIOD_M5, 1);
            double h = iHigh (symbol, PERIOD_M5, 1);
            double l = iLow  (symbol, PERIOD_M5, 1);
            double c = iClose(symbol, PERIOD_M5, 1);

            PrintFormat("✅ M5 rejection confirmed | Zone=%d | %s | zone=[%.2f-%.2f] | time=%s | O=%.2f H=%.2f L=%.2f C=%.2f",
                        i + 1, zoneOrderType[i], entry_min, entry_max,
                        TimeToString(iTime(symbol, PERIOD_M5, 1), TIME_DATE|TIME_MINUTES),
                        o, h, l, c);
            PlaceOrder(i);
            zoneState[i] = STATE_EXECUTED;
            return;
        }

        // --- Guard: if price has moved far away from zone, reset to IDLE
        // This prevents stale TOUCHED state from triggering on a much later candle
        double currentPrice = (orderType == ORDER_TYPE_BUY)
                              ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(symbol, SYMBOL_BID);
        double distanceFromZone = (orderType == ORDER_TYPE_BUY)
                                  ? (entry_min - currentPrice)   // how far below zone BUY is
                                  : (currentPrice - entry_max);  // how far above zone SELL is

        if(distanceFromZone > 20.0) // price moved 20+ pts away — zone is no longer relevant
        {
            PrintFormat("🔄 Zone reset (price moved away) | Zone=%d | distance=%.2f pts", i + 1, distanceFromZone);
            zoneState[i] = STATE_IDLE;
        }
    }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
    string json_signal;
    if(!ReadSignal(FileName, json_signal))
        return;

    JSON::Object* obj = new JSON::Object(json_signal);
    if(obj == NULL) return;

    string   timestamp_str = obj.getString("timestamp");
    datetime signalTime    = StringToTime(timestamp_str);

    JSON::Array* zones = obj.getArray("zones");
    if(zones == NULL) { delete obj; return; }

    int count = zones.getLength();

    //--- New signal: reinitialise all arrays
    if(signalTime > activeSignalTime)
    {
        PrintFormat("🆕 New signal (%s) | %d zones | SL=%.1f | TP=%.1f | M1trigger=%s",
                    timestamp_str, count, SL_Points, TP_Points,
                    UseM1Trigger ? "ON" : "OFF");

        activeSignalTime = signalTime;
        zoneCount        = count;

        ArrayResize(zoneState,     count); ArrayInitialize(zoneState,     STATE_IDLE);
        ArrayResize(zoneSymbol,    count);
        ArrayResize(zoneOrderType, count);
        ArrayResize(zoneEntryMin,  count);
        ArrayResize(zoneEntryMax,  count);
        ArrayResize(zoneTouchTime, count); ArrayInitialize(zoneTouchTime, 0);

        for(int i = 0; i < count; i++)
        {
            JSON::Object* z = zones.getObject(i);
            if(z == NULL) continue;
            zoneSymbol[i]    = z.getString("symbol");
            zoneOrderType[i] = z.getString("order_type");
            zoneEntryMin[i]  = z.getNumber("entry_min");
            zoneEntryMax[i]  = z.getNumber("entry_max");
            PrintFormat("   Zone %d | %s | %s | [%.2f - %.2f]",
                        i + 1, zoneSymbol[i], zoneOrderType[i],
                        zoneEntryMin[i], zoneEntryMax[i]);
        }
    }

    //--- Detect new closed bars (state machine runs once per bar, not per tick)
    string refSym = (count > 0) ? zoneSymbol[0] : _Symbol;
    static datetime lastM5Bar = 0, lastM1Bar = 0;
    datetime m5 = iTime(refSym, PERIOD_M5, 0);
    datetime m1 = iTime(refSym, PERIOD_M1, 0);
    newM5Bar = (m5 != lastM5Bar);
    newM1Bar = (m1 != lastM1Bar);
    lastM5Bar = m5;
    lastM1Bar = m1;

    //--- Run state machine for each pending zone
    for(int i = 0; i < zoneCount; i++)
    {
        if(zoneState[i] == STATE_EXECUTED) continue;
        ProcessZone(i);
    }

    //--- Periodic status log every 15 min
    static datetime lastPrintTime = 0;
    if(TimeCurrent() - lastPrintTime >= 900)
    {
        int pending = 0;
        for(int i = 0; i < zoneCount; i++)
            if(zoneState[i] != STATE_EXECUTED) pending++;

        string stateStr = "";
        for(int i = 0; i < zoneCount; i++)
        {
            string s = (zoneState[i] == STATE_IDLE)     ? "IDLE"
                     : (zoneState[i] == STATE_TOUCHED)  ? "TOUCHED"
                     : "DONE";
            stateStr += "Z" + IntegerToString(i+1) + ":" + s + " ";
        }
        PrintFormat("⏳ %s | %d/%d pending | %s", timestamp_str, pending, zoneCount, stateStr);
        lastPrintTime = TimeCurrent();
    }

    delete obj;
}