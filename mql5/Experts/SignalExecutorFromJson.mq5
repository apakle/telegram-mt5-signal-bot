//+------------------------------------------------------------------+
//|  SignalExecutorFromJson.mq5                                      |
//|  Reads signal_zones.json with multiple zones, checks rejection   |
//|  per zone based on BarePips Rejection Candle Handbook.           |
//|  Improved rejection logic for XAUUSD / high-volatility assets.  |
//+------------------------------------------------------------------+
#include <JSON\index.mqh>

input string            FileName            = "signal_zones.json"; // JSON file path
input double            LotSize             = 0.01;                // Volume per trade
input double            SL_Points           = 10.0;                // SL distance in dollars
input double            TP_Points           = 4.0;                 // TP distance in dollars
input ENUM_TIMEFRAMES   RejectionTF         = PERIOD_M5;           // Rejection candle timeframe
input double            MaxBodyRatio        = 0.20;                // Max body / total range (tightened for Gold)
input double            MinWickRatio        = 0.50;                // Min rejection wick / total range (tightened for Gold)
input double            MinZonePenetration  = 1.0;                 // Min points wick must enter zone (avoids edge clips)
input double            MinCandleRange      = 2.0;                 // Min total candle range in points (ignores tiny candles)
input int               LookbackCandles     = 3;                   // How many closed candles to check per zone per tick

//--- Track which zones have already been executed (by index, per signal timestamp)
datetime     activeSignalTime = 0;
bool         zoneExecuted[];

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
    {
        PrintFormat("❌ OrderSend failed | Zone=%d | retcode=%d", zoneIndex + 1, result.retcode);
    }
    else
    {
        PrintFormat("✅ Order placed | Zone=%d | %s | price=%.2f | SL=%.2f | TP=%.2f | ticket=%I64d",
                    zoneIndex + 1,
                    (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL",
                    price, sl, tp, result.order);
    }
}

//+------------------------------------------------------------------+
//| BarePips rejection check for a single candle (by bar index)      |
//|                                                                   |
//| Rules (all must pass):                                            |
//|  1. Candle range >= MinCandleRange  (not a tiny noise candle)    |
//|  2. Wick penetrated zone by >= MinZonePenetration points         |
//|  3. Candle closed clearly OUTSIDE the zone                       |
//|  4. Directional close: bullish for BUY, bearish for SELL         |
//|  5. Small body: body <= MaxBodyRatio * total range               |
//|  6. Rejection wick >= MinWickRatio * total range                 |
//+------------------------------------------------------------------+
bool CheckCandleRejection(string symbol, ENUM_ORDER_TYPE orderType,
                           double entry_min, double entry_max, int barIndex)
{
    double low   = iLow  (symbol, RejectionTF, barIndex);
    double high  = iHigh (symbol, RejectionTF, barIndex);
    double open  = iOpen (symbol, RejectionTF, barIndex);
    double close = iClose(symbol, RejectionTF, barIndex);

    double totalRange = high - low;

    //--- [Rule 1] Ignore tiny candles — no meaningful signal on Gold
    if(totalRange < MinCandleRange)
        return false;

    double body      = MathAbs(close - open);
    double bodyRatio = body / totalRange;

    //--- [Rule 5] Small body required — large body = momentum, not rejection
    if(bodyRatio > MaxBodyRatio)
        return false;

    if(orderType == ORDER_TYPE_BUY)
    {
        //--- [Rule 2] Lower wick must penetrate zone by minimum depth
        //    Penetration = how far into the zone the wick went
        double penetration = MathMin(entry_max, MathMax(entry_min, low));
        // Actually: how far below entry_max did the low reach?
        // If low > entry_max → didn't touch zone at all
        if(low > entry_max) return false;
        double zonePenetration = entry_max - low; // total depth into/through zone
        if(zonePenetration < MinZonePenetration) return false;

        //--- [Rule 3] Close must be clearly above the zone
        if(close <= entry_max) return false;

        //--- [Rule 4] Bullish close
        if(close <= open) return false;

        //--- [Rule 6] Lower wick (from bottom of body to candle low) is long
        double lowerWick = MathMin(open, close) - low;
        if(lowerWick / totalRange < MinWickRatio) return false;

        return true;
    }
    else // SELL
    {
        //--- [Rule 2] Upper wick must penetrate zone by minimum depth
        if(high < entry_min) return false;
        double zonePenetration = high - entry_min; // total depth into/through zone
        if(zonePenetration < MinZonePenetration) return false;

        //--- [Rule 3] Close must be clearly below the zone
        if(close >= entry_min) return false;

        //--- [Rule 4] Bearish close
        if(close >= open) return false;

        //--- [Rule 6] Upper wick (from top of body to candle high) is long
        double upperWick = high - MathMax(open, close);
        if(upperWick / totalRange < MinWickRatio) return false;

        return true;
    }
}

//+------------------------------------------------------------------+
//| Check rejection across last N closed candles                     |
//| Returns bar index of first confirming candle, or -1 if none     |
//+------------------------------------------------------------------+
int FindRejectionCandle(string symbol, ENUM_ORDER_TYPE orderType,
                         double entry_min, double entry_max)
{
    for(int bar = 1; bar <= LookbackCandles; bar++)
    {
        if(CheckCandleRejection(symbol, orderType, entry_min, entry_max, bar))
            return bar;
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

    //--- Parse top-level object
    JSON::Object* obj = new JSON::Object(json_signal);
    if(obj == NULL) return;

    string   timestamp_str = obj.getString("timestamp");
    datetime signalTime    = StringToTime(timestamp_str);

    JSON::Array* zones = obj.getArray("zones");
    if(zones == NULL) { delete obj; return; }

    int zone_count = zones.getLength();

    //--- New signal detected: reset tracking array
    if(signalTime > activeSignalTime)
    {
        PrintFormat("🆕 New signal (%s) | %d zones | TF=%s | Lookback=%d bars",
                    timestamp_str, zone_count, EnumToString(RejectionTF), LookbackCandles);
        activeSignalTime = signalTime;
        ArrayResize(zoneExecuted, zone_count);
        ArrayInitialize(zoneExecuted, false);
    }

    //--- Safety resize if zone count changed
    if(ArraySize(zoneExecuted) != zone_count)
        ArrayResize(zoneExecuted, zone_count);

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
                                    ? ORDER_TYPE_BUY
                                    : ORDER_TYPE_SELL;

        //--- Zone touch log: fires once when price first enters the zone
        double currentHigh = iHigh(symbol, RejectionTF, 1);
        double currentLow  = iLow (symbol, RejectionTF, 1);
        double currentOpen = iOpen(symbol, RejectionTF, 1);
        double currentClose= iClose(symbol, RejectionTF, 1);
        bool   inZone      = (orderType == ORDER_TYPE_BUY)
                             ? (currentLow  <= entry_max)   // BUY: low touched zone from above
                             : (currentHigh >= entry_min);  // SELL: high touched zone from below

        static bool zoneTouched[];
        if(ArraySize(zoneTouched) != zone_count)
        {
            ArrayResize(zoneTouched, zone_count);
            ArrayInitialize(zoneTouched, false);
        }

        if(inZone && !zoneTouched[i])
        {
            zoneTouched[i] = true;
            PrintFormat("📍 Zone touched | Zone=%d | %s | zone=[%.2f-%.2f] | time=%s | O=%.2f H=%.2f L=%.2f C=%.2f",
                        i + 1, order_type, entry_min, entry_max,
                        TimeToString(iTime(symbol, RejectionTF, 1), TIME_DATE|TIME_MINUTES),
                        currentOpen, currentHigh, currentLow, currentClose);
        }
        else if(!inZone)
        {
            zoneTouched[i] = false; // reset so re-entry into zone is logged again
        }

        int confirmedBar = FindRejectionCandle(symbol, orderType, entry_min, entry_max);

        if(confirmedBar > 0)
        {
            double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

            double sl, tp;
            if(orderType == ORDER_TYPE_BUY)
            {
                double entry = ask;
                sl = entry - SL_Points;
                tp = entry + TP_Points;
            }
            else
            {
                double entry = bid;
                sl = entry + SL_Points;
                tp = entry - TP_Points;
            }

            //--- Log full candle details for review
            double cLow   = iLow  (symbol, RejectionTF, confirmedBar);
            double cHigh  = iHigh (symbol, RejectionTF, confirmedBar);
            double cOpen  = iOpen (symbol, RejectionTF, confirmedBar);
            double cClose = iClose(symbol, RejectionTF, confirmedBar);
            double range  = cHigh - cLow;
            double body   = MathAbs(cClose - cOpen);

            PrintFormat("✅ Rejection confirmed | Zone=%d | %s | zone=[%.2f-%.2f] | bar[%d] O=%.2f H=%.2f L=%.2f C=%.2f | body=%.0f%% range=%.2f",
                        i + 1, order_type, entry_min, entry_max, confirmedBar,
                        cOpen, cHigh, cLow, cClose,
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

        PrintFormat("⏳ Watching | %s | %d/%d zones pending | TF=%s | MaxBody=%.0f%% MinWick=%.0f%% MinPen=%.1f MinRange=%.1f Lookback=%d",
                    timestamp_str, pending, zone_count,
                    EnumToString(RejectionTF),
                    MaxBodyRatio * 100, MinWickRatio * 100,
                    MinZonePenetration, MinCandleRange, LookbackCandles);
        lastPrintTime = TimeCurrent();
    }

    delete obj;
}