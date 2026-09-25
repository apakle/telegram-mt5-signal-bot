//+------------------------------------------------------------------+
//|  SignalExecutorFromJson.mq5                                      |
//|  Reads signal_zones.json with multiple zones, checks rejection   |
//|  per zone based on BarePips Rejection Candle Handbook.           |
//|                                                                  |
//|  Two confirmation modes:                                         |
//|  - Pin Bar  : single candle with long wick + small body          |
//|  - Rollover : zone touched on candle A, bearish/bullish close    |
//|               outside zone on candle B (catches Gold grind-outs) |
//|                                                                  |
//|  RequirePinBar = true  → pin bar only                           |
//|  RequirePinBar = false → pin bar OR rollover (default)          |
//+------------------------------------------------------------------+
#include <JSON\index.mqh>

input string          FileName           = "signal_zones.json"; // JSON file path
input double          LotSize            = 0.01;                // Volume per trade
input double          SL_Points          = 10.0;                // SL distance in dollars
input double          TP_Points          = 4.0;                 // TP distance in dollars
input ENUM_TIMEFRAMES RejectionTF        = PERIOD_M5;           // Candle timeframe (M5 or M15)
input bool            RequirePinBar      = false;               // true = pin bar only | false = pin bar OR rollover
input double          MaxBodyRatio       = 0.20;                // [Pin bar] Max body / total range
input double          MinWickRatio       = 0.50;                // [Pin bar] Min rejection wick / total range
input double          MinZonePenetration = 1.0;                 // Min points wick must enter zone
input double          MinCandleRange     = 2.0;                 // Min total candle range (filters noise)
input int             LookbackCandles    = 10;                  // How many closed candles to scan per tick

//--- Global tracking arrays (indexed per zone, reset on new signal)
datetime activeSignalTime = 0;
bool     zoneExecuted[];   // zone already traded
bool     zoneTouched[];    // zone was tested by price (enables rollover)

//+------------------------------------------------------------------+
//| Read JSON file into string                                        |
//+------------------------------------------------------------------+
bool ReadSignal(string fileName, string &json_signal)
{
    static datetime lastHandleErrorPrint = 0;
    static datetime lastEmptyPrint       = 0;

    int handle = FileOpen(fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if(handle == INVALID_HANDLE)
    {
        if(TimeCurrent() - lastHandleErrorPrint >= 120)
        {
            Print("❌ Failed to open JSON file: ", fileName, " | Error: ", GetLastError());
            lastHandleErrorPrint = TimeCurrent();
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
            Print("⚠️ JSON file empty or corrupted");
            lastEmptyPrint = TimeCurrent();
        }
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Place a single market order                                       |
//+------------------------------------------------------------------+
void PlaceOrder(string symbol, ENUM_ORDER_TYPE orderType, double sl, double tp, int zoneIndex)
{
    double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
    double price = (orderType == ORDER_TYPE_BUY) ? ask : bid;

    MqlTradeRequest request;
    MqlTradeResult  result;
    ZeroMemory(request);
    ZeroMemory(result);

    request.action       = TRADE_ACTION_DEAL;
    request.symbol       = symbol;
    request.volume       = LotSize;
    request.type         = orderType;
    request.price        = price;
    request.sl           = sl;
    request.tp           = tp;
    request.magic        = 0;
    request.comment      = "Zone" + IntegerToString(zoneIndex + 1);
    request.deviation    = 20;
    request.type_time    = ORDER_TIME_GTC;
    request.type_filling = ORDER_FILLING_IOC;

    if(!OrderSend(request, result))
        PrintFormat("❌ OrderSend failed | Zone=%d | retcode=%d", zoneIndex + 1, result.retcode);
    else
        PrintFormat("✅ Order placed | Zone=%d | %s | price=%.2f | SL=%.2f | TP=%.2f | ticket=%I64d",
                    zoneIndex + 1,
                    (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL",
                    price, sl, tp, result.order);
}

//+------------------------------------------------------------------+
//| MODE 1 — Pin bar                                                 |
//|                                                                  |
//| Single candle with all of:                                       |
//|  1. Range >= MinCandleRange                                      |
//|  2. Wick entered zone by >= MinZonePenetration pts               |
//|  3. Closed clearly outside the zone                             |
//|  4. Directional: bullish for BUY, bearish for SELL              |
//|  5. Body <= MaxBodyRatio * range                                 |
//|  6. Rejection wick >= MinWickRatio * range                      |
//+------------------------------------------------------------------+
bool CheckPinBar(string symbol, ENUM_ORDER_TYPE orderType,
                 double entry_min, double entry_max, int bar)
{
    double low   = iLow  (symbol, RejectionTF, bar);
    double high  = iHigh (symbol, RejectionTF, bar);
    double open  = iOpen (symbol, RejectionTF, bar);
    double close = iClose(symbol, RejectionTF, bar);

    double totalRange = high - low;
    if(totalRange < MinCandleRange)              return false; // [1]

    double bodyRatio = MathAbs(close - open) / totalRange;
    if(bodyRatio > MaxBodyRatio)                 return false; // [5]

    if(orderType == ORDER_TYPE_BUY)
    {
        if(low > entry_max)                      return false; // [2] no touch
        if(entry_max - low < MinZonePenetration) return false; // [2] too shallow
        if(close <= entry_max)                   return false; // [3] closed inside zone
        if(close <= open)                        return false; // [4] not bullish
        double lowerWick = MathMin(open, close) - low;
        if(lowerWick / totalRange < MinWickRatio) return false; // [6]
    }
    else
    {
        if(high < entry_min)                     return false; // [2] no touch
        if(high - entry_min < MinZonePenetration) return false; // [2] too shallow
        if(close >= entry_min)                   return false; // [3] closed inside zone
        if(close >= open)                        return false; // [4] not bearish
        double upperWick = high - MathMax(open, close);
        if(upperWick / totalRange < MinWickRatio) return false; // [6]
    }

    return true;
}

//+------------------------------------------------------------------+
//| MODE 2 — Rollover                                                |
//|                                                                  |
//| Two-candle confirmation for gradual rejections (common on Gold). |
//| Candle A (any earlier bar): wick entered the zone               |
//| Candle B (bar being checked): directional close outside zone    |
//|                                                                  |
//| Rules for candle B:                                              |
//|  1. Zone was previously touched (Candle A already logged)       |
//|  2. Range >= MinCandleRange                                      |
//|  3. Closed clearly outside the zone                             |
//|  4. Directional: bullish for BUY, bearish for SELL              |
//+------------------------------------------------------------------+
bool CheckRollover(string symbol, ENUM_ORDER_TYPE orderType,
                   double entry_min, double entry_max,
                   int bar, bool zoneWasTouched)
{
    if(!zoneWasTouched) return false; // [1] zone must have been tested first

    double low   = iLow  (symbol, RejectionTF, bar);
    double high  = iHigh (symbol, RejectionTF, bar);
    double open  = iOpen (symbol, RejectionTF, bar);
    double close = iClose(symbol, RejectionTF, bar);

    double totalRange = high - low;
    if(totalRange < MinCandleRange) return false; // [2]

    if(orderType == ORDER_TYPE_BUY)
    {
        if(low > entry_max)    return false; // [2] candle must have touched zone from below
        if(close <= entry_max) return false; // [3] must close above zone
        if(close <= open)      return false; // [4] must be bullish
    }
    else
    {
        if(high < entry_min)   return false; // [2] candle must have touched zone from above
        if(close >= entry_min) return false; // [3] must close below zone
        if(close >= open)      return false; // [4] must be bearish
    }

    return true;
}

//+------------------------------------------------------------------+
//| Scan lookback window for first confirming candle                 |
//| Pin bar is checked first; rollover only if RequirePinBar=false  |
//| Returns bar index on match, -1 if none found                    |
//| outMode set to "PinBar" or "Rollover" for logging               |
//+------------------------------------------------------------------+
int FindConfirmation(string symbol, ENUM_ORDER_TYPE orderType,
                     double entry_min, double entry_max,
                     bool zoneWasTouched, string &outMode)
{
    for(int bar = 1; bar <= LookbackCandles; bar++)
    {
        if(CheckPinBar(symbol, orderType, entry_min, entry_max, bar))
        {
            outMode = "PinBar";
            return bar;
        }
        if(!RequirePinBar &&
           CheckRollover(symbol, orderType, entry_min, entry_max, bar, zoneWasTouched))
        {
            outMode = "Rollover";
            return bar;
        }
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
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

    int zone_count = zones.getLength();

    //--- New signal: reset all tracking arrays
    if(signalTime > activeSignalTime)
    {
        PrintFormat("🆕 New signal (%s) | %d zones | TF=%s | Mode=%s | Lookback=%d bars",
                    timestamp_str, zone_count, EnumToString(RejectionTF),
                    RequirePinBar ? "PinBar only" : "PinBar + Rollover",
                    LookbackCandles);
        activeSignalTime = signalTime;
        ArrayResize(zoneExecuted, zone_count); ArrayInitialize(zoneExecuted, false);
        ArrayResize(zoneTouched,  zone_count); ArrayInitialize(zoneTouched,  false);
    }

    //--- Safety resize
    if(ArraySize(zoneExecuted) != zone_count)
    {
        ArrayResize(zoneExecuted, zone_count); ArrayInitialize(zoneExecuted, false);
        ArrayResize(zoneTouched,  zone_count); ArrayInitialize(zoneTouched,  false);
    }

    //--- Iterate each zone
    for(int i = 0; i < zone_count; i++)
    {
        if(zoneExecuted[i]) continue;

        JSON::Object* zone = zones.getObject(i);
        if(zone == NULL) continue;

        string  symbol     = zone.getString("symbol");
        string  order_type = zone.getString("order_type");
        double  entry_min  = zone.getNumber("entry_min");
        double  entry_max  = zone.getNumber("entry_max");

        ENUM_ORDER_TYPE orderType = (StringFind(order_type, "BUY") != -1)
                                    ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

        //--- Check if last closed candle touched the zone
        double cHigh  = iHigh (symbol, RejectionTF, 1);
        double cLow   = iLow  (symbol, RejectionTF, 1);
        double cOpen  = iOpen (symbol, RejectionTF, 1);
        double cClose = iClose(symbol, RejectionTF, 1);

        bool inZone = (orderType == ORDER_TYPE_BUY)
                      ? (cLow  <= entry_max)
                      : (cHigh >= entry_min);

        //--- Log first zone touch; keep zoneTouched=true once set
        if(inZone && !zoneTouched[i])
        {
            zoneTouched[i] = true;
            PrintFormat("📍 Zone touched | Zone=%d | %s | zone=[%.2f-%.2f] | time=%s | O=%.2f H=%.2f L=%.2f C=%.2f",
                        i + 1, order_type, entry_min, entry_max,
                        TimeToString(iTime(symbol, RejectionTF, 1), TIME_DATE|TIME_MINUTES),
                        cOpen, cHigh, cLow, cClose);
        }

        //--- Look for confirmation (pin bar first, then rollover)
        string confirmMode = "";
        int confirmedBar = FindConfirmation(symbol, orderType, entry_min, entry_max,
                                            zoneTouched[i], confirmMode);

        if(confirmedBar > 0)
        {
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

            double sl, tp;
            if(orderType == ORDER_TYPE_BUY)
            {
                sl = ask - SL_Points;
                tp = ask + TP_Points;
            }
            else
            {
                sl = bid + SL_Points;
                tp = bid - TP_Points;
            }

            //--- Log confirming candle details
            double rLow   = iLow  (symbol, RejectionTF, confirmedBar);
            double rHigh  = iHigh (symbol, RejectionTF, confirmedBar);
            double rOpen  = iOpen (symbol, RejectionTF, confirmedBar);
            double rClose = iClose(symbol, RejectionTF, confirmedBar);
            double range  = rHigh - rLow;
            double body   = MathAbs(rClose - rOpen);

            PrintFormat("✅ %s confirmed | Zone=%d | %s | zone=[%.2f-%.2f] | bar[%d] time=%s | O=%.2f H=%.2f L=%.2f C=%.2f | body=%.0f%% range=%.2f",
                        confirmMode, i + 1, order_type, entry_min, entry_max, confirmedBar,
                        TimeToString(iTime(symbol, RejectionTF, confirmedBar), TIME_DATE|TIME_MINUTES),
                        rOpen, rHigh, rLow, rClose,
                        (body / range) * 100, range);

            PlaceOrder(symbol, orderType, sl, tp, i);
            zoneExecuted[i] = true;
        }
    }

    //--- Periodic status log every 15 minutes
    static datetime lastPrintTime = 0;
    if(TimeCurrent() - lastPrintTime >= 900)
    {
        int pending = 0;
        for(int i = 0; i < zone_count; i++)
            if(!zoneExecuted[i]) pending++;

        PrintFormat("⏳ Watching | %s | %d/%d zones pending | TF=%s | Mode=%s | MaxBody=%.0f%% MinWick=%.0f%% MinPen=%.1f MinRange=%.1f Lookback=%d",
                    timestamp_str, pending, zone_count,
                    EnumToString(RejectionTF),
                    RequirePinBar ? "PinBar" : "PinBar+Rollover",
                    MaxBodyRatio * 100, MinWickRatio * 100,
                    MinZonePenetration, MinCandleRange, LookbackCandles);
        lastPrintTime = TimeCurrent();
    }

    delete obj;
}