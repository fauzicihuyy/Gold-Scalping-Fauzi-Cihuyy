//+------------------------------------------------------------------+
//|                                                  GoldScalpPro.mq5 |
//|  Fresh MQL5 build designed from the results of a 9-day backtest   |
//|  analysis of a gold M1 basket scalper (2026.09.01 - 09.09):       |
//|   * pending STOP entries following Parabolic SAR direction        |
//|   * basket take-profit: close ALL when combined profit reached    |
//|     (this is the recovery engine behind a steady equity curve)    |
//|   * controlled grid (max positions) with loss-streak guard        |
//|   * basket stop-loss and optional per-position SL to cut tails    |
//|   * session window, spread / ATR / volatility / tick filters      |
//|   * daily profit / loss protection, optional news CSV filter      |
//|  Original code for personal backtesting - not a Market product.   |
//+------------------------------------------------------------------+
#property copyright   "Personal build - backtest driven"
#property link        "https://www.mql5.com"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- general
input long    InpMagic           = 67777;   // Magic number
input string  InpComment         = "GSP";   // Order comment
input int     InpTradeDirection  = 0;       // Direction (0=both, 1=buy only, 2=sell only)
input int     InpLotMode         = 0;       // Lot mode (0=fixed, 1=risk %)
input double  InpLots            = 0.01;    // Fixed lot size
input double  InpRiskPercent     = 0.0;     // Risk % per trade (LotMode=1)
input int     InpMaxSlippage     = 10;      // Max slippage (points)

//--- grid entries
input int     InpMaxOrders       = 5;       // Max simultaneous positions
input int     InpEntryDistance   = 40;      // Pending stop distance (points)
input int     InpOrderRefreshSec = 5;       // Pending refresh interval (seconds)

//--- basket management (recovery engine)
input double  InpBasketTP        = 6.0;     // Basket take-profit (currency, close ALL)
input double  InpBasketSL        = 10.0;    // Basket stop-loss (currency, 0=off)
input int     InpBasketSLPauseMin= 30;      // Cooldown after basket SL (minutes)
input int     InpPerPosSLPoints  = 120;     // Per-position SL (points, 0=off)

//--- loss-streak guard
input int     InpMaxLossStreak   = 3;       // Losing baskets before guard (0=off)
input int     InpGuardMaxOrders  = 2;       // Max positions while guarded
input int     InpGuardMinutes    = 25;      // Guard duration (minutes)

//--- direction
input bool    InpUseSAR          = true;    // Use Parabolic SAR direction
input int     InpATRPeriod       = 14;      // ATR period (SL/reference)

//--- market filters
input bool    InpFilterSpread    = true;    // Enable spread filter
input int     InpMaxSpreadPoints = 50;      // Max spread (points)
input bool    InpFilterATR       = true;    // Enable ATR band filter
input double  InpATRMinMult      = 0.5;     // Min ATR multiplier vs average
input double  InpATRMaxMult      = 2.5;     // Max ATR multiplier vs average
input int     InpATRLookback     = 50;      // ATR average lookback (bars)
input bool    InpFilterVol       = true;    // Enable volatility window filter
input int     InpVolCheckSec     = 10;      // Volatility check window (seconds)
input int     InpMaxVolDevPoints = 150;     // Max 2-way deviation (points)
input int     InpMinTicksPerMin  = 5;       // Min ticks per 60 seconds
input bool    InpFilterTicks     = true;    // Enable tick activity filter

//--- time rules
input bool    InpTrading24h      = false;   // Trade 24 hours (ignores window)
input string  InpSessionStart    = "08:00"; // Session start (server time)
input string  InpSessionEnd      = "18:00"; // Session end (server time)
input bool    InpTradeNonFarmFri = false;   // Trade on NFP Friday (first Friday)
input bool    InpTradeMonday     = true;    // Trade Monday
input bool    InpTradeTuesday    = true;    // Trade Tuesday
input bool    InpTradeWednesday  = true;    // Trade Wednesday
input bool    InpTradeThursday   = true;    // Trade Thursday
input bool    InpTradeFriday     = true;    // Trade Friday

//--- daily protection
input double  InpDailyTarget     = 0.0;     // Daily profit target (currency, 0=off)
input double  InpDailyMaxLoss    = 0.0;     // Daily max loss (currency, 0=off)

//--- optional news filter (CSV: time|ccy|impact)
input bool    InpUseNewsFilter   = false;   // Enable news filter
input string  InpNewsFile        = "News\\NewsCalendar.csv";
input int     InpNewsBlockMin    = 60;      // Minutes blocked around news

//+------------------------------------------------------------------+
//| Enumerations and global state                                    |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE { LOT_FIXED = 0, LOT_RISK = 1 };

struct NewsEvent
  {
   datetime          time;
   string            ccy;
   int               impact;
  };

CTrade         trade;

int            hATR                = INVALID_HANDLE;
int            hSAR                = INVALID_HANDLE;

int            g_ticks             = 0;
datetime       g_tickWinStart      = 0;
bool           g_tickActive        = true;

datetime       g_volStart          = 0;
double         g_volHigh           = 0.0;
double         g_volLow            = 0.0;

datetime       g_lastBar           = 0;
datetime       g_basketPauseUntil  = 0;
datetime       g_guardUntil        = 0;
int            g_lossStreak        = 0;

int            g_dayOfYear         = -1;
double         g_dayRealized       = 0.0;
bool           g_haltToday         = false;

NewsEvent      g_news[];
int            g_newsCount         = 0;
bool           g_newsLoaded        = false;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double Pt()
  {
   return(SymbolInfoDouble(_Symbol, SYMBOL_POINT));
  }

double NormalizeVolume(double volume)
  {
   double minv  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepv > 0.0)
      volume = MathFloor(volume / stepv + 0.5) * stepv;
   return(MathMax(minv, MathMin(maxv, volume)));
  }

double NormPrice(double price)
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return(NormalizeDouble(price, digits));
  }

//+------------------------------------------------------------------+
//| Position helpers (own positions only)                            |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      count++;
     }
   return(count);
  }

double TotalFloating()
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      sum += PositionGetDouble(POSITION_PROFIT);
      sum += PositionGetDouble(POSITION_SWAP);
     }
   return(sum);
  }

void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Owned pending order helper                                       |
//+------------------------------------------------------------------+
ulong GetOwnPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      return(ticket);
     }
   return(0);
  }

//+------------------------------------------------------------------+
//| News file loading (CSV: time|ccy|impact)                         |
//+------------------------------------------------------------------+
void LoadNews()
  {
   g_newsLoaded = false;
   g_newsCount  = 0;
   if(!InpUseNewsFilter)
      return;

   int handle = FileOpen(InpNewsFile, FILE_READ | FILE_CSV | FILE_ANSI, '|');
   if(handle == INVALID_HANDLE)
     {
      Print("GoldScalpPro: news file not found (", InpNewsFile, ") - news filter inactive");
      return;
     }

   while(!FileIsEnding(handle) && g_newsCount < 500)
     {
      string parts[];
      int n = StringSplit(FileReadString(handle), '|', parts);
      if(n >= 3)
        {
         datetime t = StringToTime(parts[0]);
         string ccy = parts[1];
         int impact = (int)StringToInteger(parts[2]);
         if(t > 0 && ccy != "")
           {
            g_news[g_newsCount].time   = t;
            g_news[g_newsCount].ccy    = ccy;
            g_news[g_newsCount].impact = impact;
            g_newsCount++;
           }
        }
     }
   FileClose(handle);
   g_newsLoaded = (g_newsCount > 0);
   if(g_newsLoaded)
      Print("GoldScalpPro: news filter loaded ", IntegerToString(g_newsCount), " events");
  }

bool IsNewsBlocked()
  {
   if(!InpUseNewsFilter || !g_newsLoaded)
      return(false);

   datetime now = TimeCurrent();
   long block = InpNewsBlockMin * 60;
   for(int i = 0; i < g_newsCount; i++)
     {
      if(now >= g_news[i].time - block && now <= g_news[i].time + block)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Time / session rules                                             |
//+------------------------------------------------------------------+
bool IsTradableDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   switch(dt.day_of_week)
     {
      case 1: return(InpTradeMonday);
      case 2: return(InpTradeTuesday);
      case 3: return(InpTradeWednesday);
      case 4: return(InpTradeThursday);
      case 5:
         // NFP Friday (US jobs report) usually falls on the first Friday
         if(!InpTradeNonFarmFri && dt.day <= 7)
            return(false);
         return(InpTradeFriday);
      default: return(false);
     }
  }

bool IsSessionOpen()
  {
   if(InpTrading24h)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int curMin = dt.hour * 60 + dt.min;

   string sp[], ep[];
   if(StringSplit(InpSessionStart, ':', sp) != 2)
      return(true);
   if(StringSplit(InpSessionEnd, ':', ep) != 2)
      return(true);
   int sMin = (int)StringToInteger(sp[0]) * 60 + (int)StringToInteger(sp[1]);
   int eMin = (int)StringToInteger(ep[0]) * 60 + (int)StringToInteger(ep[1]);
   if(eMin < sMin) // overnight window
      return(curMin >= sMin || curMin < eMin);
   return(curMin >= sMin && curMin < eMin);
  }

//+------------------------------------------------------------------+
//| Market filters                                                   |
//+------------------------------------------------------------------+
bool IsSpreadOk()
  {
   if(!InpFilterSpread)
      return(true);
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / Pt();
   return(spread <= InpMaxSpreadPoints);
  }

bool IsATROk()
  {
   if(!InpFilterATR || hATR == INVALID_HANDLE)
      return(true);

   double cur[1];
   if(CopyBuffer(hATR, 0, 1, 1, cur) < 1)
      return(true);

   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(hATR, 0, 1, InpATRLookback, arr) < InpATRLookback)
      return(true);

   double sum = 0.0;
   for(int i = 0; i < InpATRLookback; i++)
      sum += arr[i];
   double avg = sum / InpATRLookback;
   if(avg <= 0.0)
      return(true);
   return(cur[0] >= InpATRMinMult * avg && cur[0] <= InpATRMaxMult * avg);
  }

bool IsVolOk()
  {
   if(!InpFilterVol)
      return(true);

   datetime now = TimeCurrent();
   if(now - g_volStart >= InpVolCheckSec)
     {
      bool ok = true;
      if(g_volStart > 0)
        {
         double range = (g_volHigh - g_volLow) / Pt();
         ok = (range <= InpMaxVolDevPoints);
        }
      g_volStart = now;
      g_volHigh  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_volLow   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return(ok);
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_volHigh = MathMax(g_volHigh, bid);
   g_volLow  = MathMin(g_volLow,  bid);
   return(true);
  }

bool IsTickActivityOk()
  {
   if(!InpFilterTicks)
      return(true);
   return(g_tickActive);
  }

//+------------------------------------------------------------------+
//| Combined entry gate                                              |
//+------------------------------------------------------------------+
bool CanEnter()
  {
   if(g_haltToday)
      return(false);
   if(TimeCurrent() < g_basketPauseUntil)
      return(false);
   if(!IsTradableDay())
      return(false);
   if(!IsSessionOpen())
      return(false);
   if(IsNewsBlocked())
      return(false);
   if(!IsSpreadOk())
      return(false);
   if(!IsATROk())
      return(false);
   if(!IsVolOk())
      return(false);
   if(!IsTickActivityOk())
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Direction signal from Parabolic SAR (last closed bar)            |
//+------------------------------------------------------------------+
int GetDirection()
  {
   if(InpUseSAR && hSAR != INVALID_HANDLE)
     {
      double sar[];
      ArraySetAsSeries(sar, true);
      if(CopyBuffer(hSAR, 0, 1, 2, sar) < 2)
         return(0);
      double cl[];
      if(CopyClose(_Symbol, _Period, 1, 2, cl) < 2)
         return(0);
      if(cl[1] > sar[1]) return(1);   // price above SAR on closed bar
      if(cl[1] < sar[1]) return(-1);
      return(0);
     }

   // fallback: momentum of last two closed bars
   double cl[];
   if(CopyClose(_Symbol, _Period, 2, 2, cl) < 2)
      return(0);
   if(cl[1] > cl[0]) return(1); // note cl[1] is older, cl[0] newer
   if(cl[1] < cl[0]) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Effective max positions (reduced while guard active)             |
//+------------------------------------------------------------------+
int EffectiveMaxOrders()
  {
   if(InpMaxLossStreak > 0 && TimeCurrent() < g_guardUntil)
      return(MathMin(InpMaxOrders, InpGuardMaxOrders));
   return(InpMaxOrders);
  }

//+------------------------------------------------------------------+
//| Base lot                                                         |
//+------------------------------------------------------------------+
double CalcLot()
  {
   if(InpLotMode == LOT_RISK && InpRiskPercent > 0.0)
     {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double stopDist  = (InpPerPosSLPoints > 0 ? InpPerPosSLPoints : 100) * Pt();
      if(tickValue <= 0.0 || tickSize <= 0.0 || stopDist <= 0.0)
         return(NormalizeVolume(InpLots));
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double lot = riskMoney * tickSize / (stopDist * tickValue);
      return(NormalizeVolume(lot));
     }
   return(NormalizeVolume(InpLots));
  }

//+------------------------------------------------------------------+
//| Place / refresh the pending stop order                           |
//+------------------------------------------------------------------+
void PlacePending()
  {
   if(CountPositions() >= EffectiveMaxOrders())
      return;

   int dir = GetDirection();
   if(dir == 0)
      return;
   if(InpTradeDirection == 1 && dir < 0) return;
   if(InpTradeDirection == 2 && dir > 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pt  = Pt();
   double stopPrice = (dir > 0) ? ask + InpEntryDistance * pt
                                : bid - InpEntryDistance * pt;
   stopPrice = NormPrice(stopPrice);

   // delete stale/diverged pending once per refresh interval or new bar
   datetime bar = iTime(_Symbol, _Period, 0);
   bool newBar = (bar != g_lastBar);
   if(newBar)
      g_lastBar = bar;

   ulong pending = GetOwnPending();
   if(pending != 0)
     {
      long   otype  = (long)OrderGetInteger(ORDER_TYPE);
      double oprice = OrderGetDouble(ORDER_PRICE_OPEN);
      bool wrongDir = (dir > 0 && otype != ORDER_TYPE_BUY_STOP) ||
                      (dir < 0 && otype != ORDER_TYPE_SELL_STOP);
      bool same     = !wrongDir && (MathAbs(oprice - stopPrice) < 300 * pt);
      bool stale    = (TimeCurrent() - (datetime)OrderGetInteger(ORDER_TIME_SETUP)) >= InpOrderRefreshSec;
      if(same && !newBar && !stale)
         return;
      trade.OrderDelete(pending);
     }

   double lot = CalcLot();
   if(lot <= 0.0)
      return;

   double sl = 0.0;
   if(InpPerPosSLPoints > 0)
      sl = NormPrice(stopPrice - (dir > 0 ? InpPerPosSLPoints * pt : -InpPerPosSLPoints * pt));

   if(dir > 0)
      trade.BuyStop(lot, stopPrice, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, InpComment);
   else
      trade.SellStop(lot, stopPrice, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, InpComment);
  }

//+------------------------------------------------------------------+
//| Basket management: TP close-all, basket SL, per-position SL      |
//+------------------------------------------------------------------+
void ManageBasket()
  {
   int total = CountPositions();
   if(total <= 0)
      return;

   double floating = TotalFloating();

   // basket stop-loss: protect the recovery engine from deep tails
   if(InpBasketSL > 0.0 && floating <= -InpBasketSL)
     {
      CloseAll();
      g_basketPauseUntil = TimeCurrent() + InpBasketSLPauseMin * 60;
      Print("GSP basket SL hit: floating=", DoubleToString(floating, 2),
            " -> pause ", IntegerToString(InpBasketSLPauseMin), " min");
      return;
     }

   // basket take-profit: close ALL (the recovery mechanism)
   if(InpBasketTP > 0.0 && floating >= InpBasketTP)
     {
      CloseAll();
      return;
     }

   // optional per-position SL placed once on each owned position
   if(InpPerPosSLPoints > 0)
     {
      double pt     = Pt();
      double level  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
            continue;
         if(PositionGetDouble(POSITION_SL) != 0.0)
            continue;

         long   type    = PositionGetInteger(POSITION_TYPE);
         double open    = PositionGetDouble(POSITION_PRICE_OPEN);
         double slPrice = (type == POSITION_TYPE_BUY)
                          ? open - InpPerPosSLPoints * pt
                          : open + InpPerPosSLPoints * pt;
         slPrice = NormPrice(slPrice);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double dist = (type == POSITION_TYPE_BUY) ? slPrice - bid : ask - slPrice;
         if(dist < level)
            continue;
         trade.PositionModify(ticket, slPrice, 0.0);
        }
     }
  }

//+------------------------------------------------------------------+
//| Daily profit / max loss protection                               |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayOfYear)
     {
      g_dayOfYear   = dt.day_of_year;
      g_dayRealized = 0.0;
      g_haltToday   = false;
     }

   if(g_haltToday)
      return(true);

   if(InpDailyTarget > 0.0 && g_dayRealized >= InpDailyTarget)
     {
      CloseAll();
      g_haltToday = true;
      Print("GSP daily target reached: ", DoubleToString(g_dayRealized, 2));
      return(true);
     }
   if(InpDailyMaxLoss > 0.0 && g_dayRealized <= -InpDailyMaxLoss)
     {
      CloseAll();
      g_haltToday = true;
      Print("GSP daily max loss reached: ", DoubleToString(g_dayRealized, 2));
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Realized PnL tracking + loss-streak guard                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;

   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   g_dayRealized += pnl;

   if(InpMaxLossStreak > 0)
     {
      if(pnl < 0.0)
        {
         g_lossStreak++;
         if(g_lossStreak >= InpMaxLossStreak)
           {
            g_guardUntil = TimeCurrent() + InpGuardMinutes * 60;
            Print("GSP loss streak ", IntegerToString(g_lossStreak),
                  " -> guard ", IntegerToString(InpGuardMinutes), " min (max orders ",
                  IntegerToString(InpGuardMaxOrders), ")");
           }
        }
      else
         g_lossStreak = 0;
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMaxOrders < 1)     { Print("InpMaxOrders must be >= 1");     return(INIT_PARAMETERS_INCORRECT); }
   if(InpEntryDistance < 1) { Print("InpEntryDistance must be >= 1"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpBasketTP < 0.0)    { Print("InpBasketTP must be >= 0");      return(INIT_PARAMETERS_INCORRECT); }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpFilterATR)
     {
      hATR = iATR(_Symbol, _Period, InpATRPeriod);
      if(hATR == INVALID_HANDLE)
        {
         Print("GoldScalpPro: failed to create ATR handle");
         return(INIT_FAILED);
        }
     }

   if(InpUseSAR)
     {
      hSAR = iSAR(_Symbol, _Period, 0.02, 0.2);
      if(hSAR == INVALID_HANDLE)
        {
         Print("GoldScalpPro: failed to create SAR handle");
         return(INIT_FAILED);
        }
     }

   LoadNews();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayOfYear    = dt.day_of_year;
   g_tickWinStart = TimeCurrent();
   g_lastBar      = iTime(_Symbol, _Period, 0);
   g_volStart     = TimeCurrent();
   g_volHigh      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_volLow       = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Print("GoldScalpPro v1.00 initialized: ", _Symbol, " ", EnumToString(_Period));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hATR != INVALID_HANDLE)
     {
      IndicatorRelease(hATR);
      hATR = INVALID_HANDLE;
     }
   if(hSAR != INVALID_HANDLE)
     {
      IndicatorRelease(hSAR);
      hSAR = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpFilterTicks)
     {
      g_ticks++;
      if(TimeCurrent() - g_tickWinStart >= 60)
        {
         g_tickActive   = (g_ticks >= InpMinTicksPerMin);
         g_ticks        = 0;
         g_tickWinStart = TimeCurrent();
        }
     }

   if(CheckDailyLimits())
      return;

   ManageBasket();

   if(!CanEnter())
      return;

   PlacePending();
  }
//+------------------------------------------------------------------+