//+------------------------------------------------------------------+
//|  SignalExecutorFromJson.mq5                                      |
//|  Reads signal_zones.json with multiple zones, checks rejection   |
//|  per zone based on BarePips Rejection Candle Handbook.           |
//|  SL=10pts, TP=4pts from entry. Timeframe: M5 default.            |
//+------------------------------------------------------------------+
#include <JSON\index.mqh>

input string            FileName         = "signal_zones.json";  // JSON file path
input double            LotSize          = 0.01;           // Volume per trade
input double            SL_Points        = 10.0;           // SL distance in dollars
input double            TP_Points        = 4.0;            // TP distance in dollars
input ENUM_TIMEFRAMES   RejectionTF      = PERIOD_M5;      // Rejection candle timeframe (M5 or M15)
input double            MaxBodyRatio     = 0.30;           // Max body-to-range ratio (0.30 = 30%)
input double            MinWickRatio     = 0.40;           // Min wick into zone as % of total range

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
//| BarePips rejection candle check                                   |
//|                                                                   |
//| A valid rejection candle requires ALL of:                         |
//|  1. Wick penetrated the zone (price tested it)                   |
//|  2. Candle closed clearly OUTSIDE the zone (strong pushback)     |
//|  3. Directional close: bullish for BUY, bearish for SELL         |
//|  4. Small body: body <= MaxBodyRatio * total candle range        |
//|  5. Long wick into zone: wick >= MinWickRatio * total range      |
//+------------------------------------------------------------------+
bool CheckRejection(string symbol, ENUM_ORDER_TYPE orderType, double entry_min, double entry_max)
{
    double low   = iLow  (symbol, RejectionTF, 1);
    double high  = iHigh (symbol, RejectionTF, 1);
    double open  = iOpen (symbol, RejectionTF, 1);
    double close = iClose(symbol, RejectionTF, 1);

    double totalRange = high - low;
    if(totalRange <= 0) return false; // flat candle — skip

    double body      = MathAbs(close - open);
    double bodyRatio = body / totalRange;

    //--- [Rule 4] Small body required
    if(bodyRatio > MaxBodyRatio)
        return false;

    if(orderType == ORDER_TYPE_BUY)
    {
        //--- [Rule 1] Lower wick must have penetrated the zone
        if(low > entry_max) return false;

        //--- [Rule 2] Close must be clearly above the zone (pushed back out)
        if(close <= entry_max) return false;

        //--- [Rule 3] Bullish close (buyers won)
        if(close <= open) return false;

        //--- [Rule 5] Lower wick into zone must be significant
        //    Lower wick = bottom of body minus low
        double lowerWick = MathMin(open, close) - low;
        if(lowerWick / totalRange < MinWickRatio) return false;

        return true;
    }
    else // SELL
    {
        //--- [Rule 1] Upper wick must have penetrated the zone
        if(high < entry_min) return false;

        //--- [Rule 2] Close must be clearly below the zone (pushed back out)
        if(close >= entry_min) return false;

        //--- [Rule 3] Bearish close (sellers won)
        if(close >= open) return false;

        //--- [Rule 5] Upper wick into zone must be significant
        //    Upper wick = high minus top of body
        double upperWick = high - MathMax(open, close);
        if(upperWick / totalRange < MinWickRatio) return false;

        return true;
    }
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
        PrintFormat("🆕 New signal detected (%s) | %d zones | TF=%s",
                    timestamp_str, zone_count, EnumToString(RejectionTF));
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

        if(CheckRejection(symbol, orderType, entry_min, entry_max))
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

            PrintFormat("✅ BarePips rejection confirmed | Zone=%d | %s | zone=[%.2f-%.2f] | TF=%s",
                        i + 1, order_type, entry_min, entry_max, EnumToString(RejectionTF));

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

        PrintFormat("⏳ Watching signal from %s | %d/%d zones pending | TF=%s | MaxBody=%.0f%% | MinWick=%.0f%%",
                    timestamp_str, pending, zone_count,
                    EnumToString(RejectionTF),
                    MaxBodyRatio * 100,
                    MinWickRatio * 100);
        lastPrintTime = TimeCurrent();
    }

    delete obj;
}