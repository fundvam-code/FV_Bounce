//+------------------------------------------------------------------+
//|                                                     FV_Bounce.mq5 |
//|  Отскок от дневных уровней (Camarilla / Pivot / DeMark)          |
//|  Лимитные ордера перед уровнем с ATR-множителями:                |
//|    Buy  Limit = S + buffer_atr_s * ATR   (лонг от поддержки S)   |
//|    Sell Limit = R - buffer_atr_r * ATR   (шорт от сопротивления) |
//|    SL = sl_atr * ATR, TP = tp_atr * ATR, трейлинг = trail * ATR  |
//|    Трейлинг отключается, если его множитель = 0.                 |
//|  Метод уровней выбирается отдельно для лонгов и шортов.          |
//|  Параметры по умолчанию - оптимум из Python-подбора 2020-2025:   |
//|  метод DeMark (лонг и шорт), лонг 0.25/3.0/2.0/2.0,             |
//|  шорт 1.0/2.0/1.0/1.0 (buffer/SL/TP/trail, xATR); TP вручную.   |
//|  Логика повторяет bounce_atr_opt.py (backtesting.py).            |
//+------------------------------------------------------------------+
#property copyright "FV_Bounce"
#property version   "1.03"

#include <Trade/Trade.mqh>

//--- методы дневных уровней
enum ENUM_METHOD
  {
   METHOD_CAMARILLA = 0,   // Camarilla
   METHOD_PIVOT     = 1,   // Pivot (классика)
   METHOD_DEMARK    = 2    // DeMark
  };

//--- входные параметры
input group           "Уровни"
input int             InpAtrPeriod   = 14;            // Период ATR (H1)

input group           "Лонг (от поддержки S)"
input ENUM_METHOD     InpMethodLong  = METHOD_DEMARK;  // Метод уровней для лонгов
input bool            InpEnableLong  = true;           // Включить лонги
input double          InpBufferS     = 0.25;           // Буфер S, xATR
input double          InpSlS         = 3.00;           // SL S, xATR
input double          InpTpS         = 2.00;           // TP S, xATR
input double          InpTrailS      = 2.00;           // Трейлинг S, xATR (0 = выкл)

input group           "Шорт (от сопротивления R)"
input ENUM_METHOD     InpMethodShort = METHOD_DEMARK;  // Метод уровней для шортов
input bool            InpEnableShort = true;           // Включить шорты
input double          InpBufferR     = 1.00;           // Буфер R, xATR
input double          InpSlR         = 2.00;           // SL R, xATR
input double          InpTpR         = 1.00;           // TP R, xATR
input double          InpTrailR      = 1.00;           // Трейлинг R, xATR (0 = выкл)

input group           "Торговля"
input double          InpLot         = 0.01;           // Объём, лот
input long            InpMagic       = 260813;         // Magic

CTrade   trade;
datetime g_last_bar = 0;
int      g_atr_handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Служебные функции                                                |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

double NormalizeLot(double lot)
  {
   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(lot, min);
   lot = MathMin(lot, max);
   if(step > 0.0)
      lot = MathFloor(lot / step) * step;
   return NormalizeDouble(lot, 2);
  }

//--- значение ATR(period) на баре shift (0 = текущий формирующийся)
double GetAtr(int shift)
  {
   if(g_atr_handle == INVALID_HANDLE)
      g_atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   double buf[1];
   if(CopyBuffer(g_atr_handle, 0, shift, 1, buf) == 1)
      return buf[0];
   return 0.0;
  }

//--- поддержки метода из ПРЕДЫДУЩЕГО дня (D1, shift=1) - как lev.shift(1) в Python
void CalcSupport(ENUM_METHOD m, double &s[], int &ns)
  {
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);
   double c = iClose(_Symbol, PERIOD_D1, 1);
   double o = iOpen(_Symbol, PERIOD_D1, 1);

   ArrayResize(s, 4);
   ns = 0;
   if(h <= 0.0 || l <= 0.0)
      return;                       // нет истории D1 - уровней нет

   if(m == METHOD_CAMARILLA)
     {
      int divs[4] = {12, 6, 4, 2};
      double hl = h - l;
      for(int i = 0; i < 4; i++)
         s[i] = c - hl * 1.1 / divs[i];
      ns = 4;
     }
   else if(m == METHOD_PIVOT)
     {
      double p = (h + l + c) / 3.0;
      s[0] = 2.0 * p - h;
      s[1] = p - (h - l);
      s[2] = l - 2.0 * (h - p);
      ns = 3;
     }
   else   // METHOD_DEMARK
     {
      double x;
      if(c < o)      x = h + 2.0 * l + c;
      else if(c > o) x = 2.0 * h + l + c;
      else           x = h + l + 2.0 * c;
      s[0] = x / 2.0 - h;
      ns = 1;
     }
  }

//--- сопротивления метода из ПРЕДЫДУЩЕГО дня (D1, shift=1) - как lev.shift(1) в Python
void CalcResistance(ENUM_METHOD m, double &r[], int &nr)
  {
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);
   double c = iClose(_Symbol, PERIOD_D1, 1);
   double o = iOpen(_Symbol, PERIOD_D1, 1);

   ArrayResize(r, 4);
   nr = 0;
   if(h <= 0.0 || l <= 0.0)
      return;                       // нет истории D1 - уровней нет

   if(m == METHOD_CAMARILLA)
     {
      int divs[4] = {12, 6, 4, 2};
      double hl = h - l;
      for(int i = 0; i < 4; i++)
         r[i] = c + hl * 1.1 / divs[i];
      nr = 4;
     }
   else if(m == METHOD_PIVOT)
     {
      double p = (h + l + c) / 3.0;
      r[0] = 2.0 * p - l;
      r[1] = p + (h - l);
      r[2] = h + 2.0 * (p - l);
      nr = 3;
     }
   else   // METHOD_DEMARK
     {
      double x;
      if(c < o)      x = h + 2.0 * l + c;
      else if(c > o) x = 2.0 * h + l + c;
      else           x = h + l + 2.0 * c;
      r[0] = x / 2.0 - l;
      nr = 1;
     }
  }

//--- ближайшая поддержка: максимальный уровень <= price
bool NearestSupport(const double &s[], int ns, double price, double &out)
  {
   bool found = false;
   double best = -DBL_MAX;
   for(int i = 0; i < ns; i++)
     {
      double v = s[i];
      if(v <= price && v > best)
        {
         best = v;
         found = true;
        }
     }
   if(found)
      out = best;
   return found;
  }

//--- ближайшее сопротивление: минимальный уровень >= price
bool NearestResistance(const double &r[], int nr, double price, double &out)
  {
   bool found = false;
   double best = DBL_MAX;
   for(int i = 0; i < nr; i++)
     {
      double v = r[i];
      if(v >= price && v < best)
        {
         best = v;
         found = true;
        }
     }
   if(found)
      out = best;
   return found;
  }

//--- отмена всех наших отложенных ордеров
void CancelPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      trade.OrderDelete(ticket);
     }
  }

bool HasPosition()
  {
   if(!PositionSelect(_Symbol))
      return false;
   return ((long)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

//+------------------------------------------------------------------+
//| Трейлинг открытой позиции (каждый тик)                           |
//+------------------------------------------------------------------+
void TrailPosition()
  {
   if(!PositionSelect(_Symbol))
      return;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return;

   double atr = GetAtr(0);
   if(atr <= 0.0 || !MathIsValidNumber(atr))
      return;

   long type = PositionGetInteger(POSITION_TYPE);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- трейлинг отключён, если множитель = 0 (выход только по SL/TP)
   if((type == POSITION_TYPE_BUY && InpTrailS <= 0.0) ||
      (type == POSITION_TYPE_SELL && InpTrailR <= 0.0))
      return;

   double new_sl = sl;
   if(type == POSITION_TYPE_BUY)
     {
      double trail = bid - InpTrailS * atr;
      if(trail > sl + _Point * 0.5)
         new_sl = trail;
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double trail = ask + InpTrailR * atr;
      if(trail < sl - _Point * 0.5)
         new_sl = trail;
     }

   if(new_sl != sl)
      if(trade.PositionModify(_Symbol, NormalizePrice(new_sl), NormalizePrice(tp)))
         PrintFormat("Trailing SL -> %.5f", new_sl);
  }

//+------------------------------------------------------------------+
//| Новый бар: отмена старых ордеров и постановка новых лимитников   |
//+------------------------------------------------------------------+
void ManageOrders()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   //--- сначала снимаем старые лимитники
   CancelPending();

   //--- если позиция уже открыта - новые ордера не ставим
   if(HasPosition())
      return;

   //--- данные последнего закрытого H1-бара (в Python - бар i в next())
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double atr   = GetAtr(1);
   if(atr <= 0.0 || !MathIsValidNumber(atr))
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- лонг: Buy Limit = S + buffer_s * ATR, SL/TP от ATR (метод для лонгов)
   if(InpEnableLong)
     {
      double s[];
      int ns = 0;
      CalcSupport((ENUM_METHOD)InpMethodLong, s, ns);
      if(ns > 0)
        {
         double sup = 0.0;
         if(NearestSupport(s, ns, close, sup))
           {
            double entry = sup + InpBufferS * atr;
            if(close > entry && entry < bid)          // цена выше ордера и вне спреда
              {
               double sl = entry - InpSlS * atr;
               double tp = entry + InpTpS * atr;
               if(trade.BuyLimit(NormalizeLot(InpLot), NormalizePrice(entry), _Symbol,
                                 NormalizePrice(sl), NormalizePrice(tp), ORDER_TIME_GTC, 0, "FV_B_L"))
                  PrintFormat("BuyLimit %.5f, SL %.5f, TP %.5f (S=%.5f, ATR=%.5f)",
                              entry, sl, tp, sup, atr);
               else
                  PrintFormat("BuyLimit fail, retcode=%d", trade.ResultRetcode());
              }
           }
        }
     }

   //--- шорт: Sell Limit = R - buffer_r * ATR, SL/TP от ATR (метод для шортов)
   if(InpEnableShort)
     {
      double r[];
      int nr = 0;
      CalcResistance((ENUM_METHOD)InpMethodShort, r, nr);
      if(nr > 0)
        {
         double res = 0.0;
         if(NearestResistance(r, nr, close, res))
           {
            double entry = res - InpBufferR * atr;
            if(close < entry && entry > ask)          // цена ниже ордера и вне спреда
              {
               double sl = entry + InpSlR * atr;
               double tp = entry - InpTpR * atr;
               if(trade.SellLimit(NormalizeLot(InpLot), NormalizePrice(entry), _Symbol,
                                  NormalizePrice(sl), NormalizePrice(tp), ORDER_TIME_GTC, 0, "FV_B_S"))
                  PrintFormat("SellLimit %.5f, SL %.5f, TP %.5f (R=%.5f, ATR=%.5f)",
                              entry, sl, tp, res, atr);
               else
                  PrintFormat("SellLimit fail, retcode=%d", trade.ResultRetcode());
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   g_last_bar = 0;                // первый тик сразу выполнит ManageOrders()

   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(InpLot < minlot || InpAtrPeriod < 2)
      return INIT_PARAMETERS_INCORRECT;

   PrintFormat("FV_Bounce: метод лонг=%d, метод шорт=%d, лонг %.2f/%.2f/%.2f/%.2f, шорт %.2f/%.2f/%.2f/%.2f (buffer/SL/TP/trail, xATR), лот %.2f",
               (int)InpMethodLong, (int)InpMethodShort,
               InpBufferS, InpSlS, InpTpS, InpTrailS,
               InpBufferR, InpSlR, InpTpR, InpTrailR, InpLot);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   PrintFormat("FV_Bounce deinit, reason=%d", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- снимаем лимитники, если вдруг открылась позиция
   if(HasPosition())
      CancelPending();

   //--- новый бар: пересчёт условий и постановка ордеров
   datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar_time != g_last_bar)
     {
      g_last_bar = bar_time;
      ManageOrders();
     }

   //--- трейлинг открытой позиции
   TrailPosition();
  }
//+------------------------------------------------------------------+
