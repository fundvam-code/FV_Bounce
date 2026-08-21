//+------------------------------------------------------------------+
//|                                                 FV_pattern_bounce.mq5 |
//|  Отскок от уровней (Pivot/Camarilla/DeMark/Swing) с подтверждением   |
//|  разворотными паттернами (pin bar, engulfing, doji)                   |
//|  Вариант C: чистый паттерн-подход (Pure Pattern) - только маркет-входы|
//|  Market Buy/Sell при подтверждении паттерна в зоне уровня             |
//|  SL = entry - sl_mult*ATR, TP = SL * rr_mult                          |
//|  Трейлинг по ATR, управление позициями, кнопки управления             |
//|  v1.00: первая версия с поддержкой паттернов и swing high/low уровней |
//+------------------------------------------------------------------+
#property copyright "FV_Bounce"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <ChartObjects/ChartObjectsTxtControls.mqh>

//--- методы определения уровней поддержки/сопротивления
enum ENUM_METHOD
  {
   METHOD_CAMARILLA = 0,   // Camarilla
   METHOD_PIVOT     = 1,   // Pivot (классика)
   METHOD_DEMARK    = 2,   // DeMark
   METHOD_SWING     = 3    // Swing High/Low (NEW)
  };

//--- входные параметры
input group           "Уровни"
input ENUM_TIMEFRAMES InpTF           = PERIOD_H1;       // Таймфрейм расчёта (ATR, close)
input int             InpAtrPeriod    = 14;              // Период ATR
input ENUM_METHOD     InpMethodSup    = METHOD_SWING;    // Метод уровней поддержки
input ENUM_METHOD     InpMethodRes    = METHOD_SWING;    // Метод уровней сопротивления
input int             InpSwingDepth   = 3;               // Глубина swing (количество баров влево/вправо)

input group           "Паттерны (подтверждение входов)"
input bool            InpUsePinBar    = true;            // Использовать pin bar
input bool            InpUseEngulfing = true;            // Использовать engulfing
input bool            InpUseDoji      = true;            // Использовать doji
input double          InpPinBarBodyRatio     = 0.3;      // Pin bar: макс тело / диапазон
input double          InpPinBarShadowRatio   = 0.6;      // Pin bar: мин тень / диапазон
input double          InpDojiBodyRatio       = 0.1;      // Doji: макс тело / диапазон

input group           "Торговля (маркет-входы)"
input double          InpEntryZoneBuffer = 0.5;          // Зона входа (буфер), xATR
input double          InpSlAttrMult      = 2.0;          // SL = entry ± sl_mult*ATR
input double          InpRiskReward      = 2.0;          // TP = SL * rr_mult (R:R)
input double          InpLot             = 0.01;         // Объём, лот
input long            InpMagic           = 260814;       // Magic (отличается от FV_Bounce)

input group           "Трейлинг"
input double          InpTrailMult     = 1.5;            // Трейлинг множитель xATR (0 = выкл)
input bool            InpTrailRemoveTP = true;           // Убирать TP при активации трейлинга

input group           "Фильтры"
input bool            InpEnableBuy     = true;           // Разрешить покупки
input bool            InpEnableSell    = true;           // Разрешить продажи
input bool            InpNoRepeatSameDay = false;        // Не входить повторно сегодня (false = запретить)

input group           "Линии"
input bool            InpShowLinesOnStart = true;        // Показывать линии при старте

input group           "Кнопки"
input bool            InpBtnEnable   = true;             // Показать кнопки управления
input int             InpBtnX        = 10;               // Кнопки: X от левого края
input int             InpBtnY        = 30;               // Кнопки: Y первой кнопки от верха
input int             InpBtnGap      = 28;               // Кнопки: расстояние между ними
input int             InpBtn2X       = 10;               // Кнопки Поддержка/Сопротивление: X от левого нижнего угла
input int             InpBtn2Y       = 30;               // Кнопки Поддержка/Сопротивление: Y от нижнего края

//--- глобальные переменные
CTrade   trade;
CChartObjectButton g_btnPause;
CChartObjectButton g_btnCancel;
CChartObjectButton g_btnCancelAll;
CChartObjectButton g_btnEmergency;
CChartObjectButton g_btnPlace;
CChartObjectButton g_btnLines;
CChartObjectButton g_btnBuy;
CChartObjectButton g_btnSell;

string g_btnPauseName     = "FVPatBounce_PauseBtn";
string g_btnCancelName    = "FVPatBounce_CancelBtn";
string g_btnCancelAllName = "FVPatBounce_CancelAllBtn";
string g_btnEmergencyName = "FVPatBounce_EmergencyBtn";
string g_btnPlaceName     = "FVPatBounce_PlaceBtn";
string g_btnLinesName     = "FVPatBounce_LinesBtn";
string g_btnBuyName       = "FVPatBounce_BuyBtn";
string g_btnSellName      = "FVPatBounce_SellBtn";

datetime g_last_manage = 0;
int      g_atr_handle = INVALID_HANDLE;
bool     g_paused = false;
bool     g_showLines = true;
bool     g_enableBuy = true;
bool     g_enableSell = true;

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

double GetAtr(int shift)
  {
   if(g_atr_handle == INVALID_HANDLE)
      g_atr_handle = iATR(_Symbol, InpTF, InpAtrPeriod);
   double buf[1];
   if(CopyBuffer(g_atr_handle, 0, shift, 1, buf) == 1)
      return buf[0];
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Паттерны: детектирование на заданном баре                        |
//+------------------------------------------------------------------+

bool DetectPinBar(int shift)
  {
   double o = iOpen(_Symbol, InpTF, shift);
   double h = iHigh(_Symbol, InpTF, shift);
   double l = iLow(_Symbol, InpTF, shift);
   double c = iClose(_Symbol, InpTF, shift);
   
   double body = MathAbs(c - o);
   double range = h - l;
   double shadowUp = h - MathMax(o, c);
   double shadowDown = MathMin(o, c) - l;
   
   if(range <= 0.0)
      return false;
   
   //--- pin bar: маленькое тело, длинная тень в одну сторону
   bool isPinUp = (body <= InpPinBarBodyRatio * range) && (shadowDown >= InpPinBarShadowRatio * range) && (shadowUp < range * 0.1);
   bool isPinDown = (body <= InpPinBarBodyRatio * range) && (shadowUp >= InpPinBarShadowRatio * range) && (shadowDown < range * 0.1);
   
   return isPinUp || isPinDown;
  }

bool DetectEngulfing(int shift)
  {
   if(shift < 1)
      return false;
   
   double o0 = iOpen(_Symbol, InpTF, shift);
   double c0 = iClose(_Symbol, InpTF, shift);
   double o1 = iOpen(_Symbol, InpTF, shift + 1);
   double c1 = iClose(_Symbol, InpTF, shift + 1);
   
   double body0 = MathAbs(c0 - o0);
   double body1 = MathAbs(c1 - o1);
   
   if(body0 <= 0.0 || body1 <= 0.0)
      return false;
   
   //--- engulfing: текущая свеча поглощает предыдущую по телу
   bool engulfUp = (o0 < o1 && c0 > c1 && c0 > o0 && c1 < o1);   //бычий engulfing
   bool engulfDn = (o0 > o1 && c0 < c1 && c0 < o0 && c1 > o1);   //медвежий engulfing
   
   return engulfUp || engulfDn;
  }

bool DetectDoji(int shift)
  {
   double o = iOpen(_Symbol, InpTF, shift);
   double h = iHigh(_Symbol, InpTF, shift);
   double l = iLow(_Symbol, InpTF, shift);
   double c = iClose(_Symbol, InpTF, shift);
   
   double body = MathAbs(c - o);
   double range = h - l;
   
   if(range <= 0.0)
      return false;
   
   //--- doji: очень маленькое тело (близко к открытию/закрытию)
   return (body <= InpDojiBodyRatio * range);
  }

bool IsPatternConfirmed(int shift)
  {
   bool pinBar = InpUsePinBar && DetectPinBar(shift);
   bool engulfing = InpUseEngulfing && DetectEngulfing(shift);
   bool doji = InpUseDoji && DetectDoji(shift);
   
   return pinBar || engulfing || doji;
  }

//+------------------------------------------------------------------+
//| Определение уровней поддержки и сопротивления                    |
//+------------------------------------------------------------------+

void CalcSupport(ENUM_METHOD m, double &s[], int &ns)
  {
   if(m == METHOD_SWING)
     {
      CalcSwingSupport(s, ns, InpSwingDepth);
      return;
     }
   
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);
   double c = iClose(_Symbol, PERIOD_D1, 1);
   double o = iOpen(_Symbol, PERIOD_D1, 1);
   
   ArrayResize(s, 4);
   ns = 0;
   if(h <= 0.0 || l <= 0.0)
      return;
   
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
   else if(m == METHOD_DEMARK)
     {
      double x;
      if(c < o)      x = h + 2.0 * l + c;
      else if(c > o) x = 2.0 * h + l + c;
      else           x = h + l + 2.0 * c;
      s[0] = x / 2.0 - h;
      ns = 1;
     }
  }

void CalcResistance(ENUM_METHOD m, double &r[], int &nr)
  {
   if(m == METHOD_SWING)
     {
      CalcSwingResistance(r, nr, InpSwingDepth);
      return;
     }
   
   double h = iHigh(_Symbol, PERIOD_D1, 1);
   double l = iLow(_Symbol, PERIOD_D1, 1);
   double c = iClose(_Symbol, PERIOD_D1, 1);
   double o = iOpen(_Symbol, PERIOD_D1, 1);
   
   ArrayResize(r, 4);
   nr = 0;
   if(h <= 0.0 || l <= 0.0)
      return;
   
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
   else if(m == METHOD_DEMARK)
     {
      double x;
      if(c < o)      x = h + 2.0 * l + c;
      else if(c > o) x = 2.0 * h + l + c;
      else           x = h + l + 2.0 * c;
      r[0] = x / 2.0 - l;
      nr = 1;
     }
  }

void CalcSwingSupport(double &s[], int &ns, int depth)
  {
   ArrayResize(s, 10);
   ns = 0;
   
   double atr = GetAtr(0);
   if(atr <= 0.0)
      return;
   
   double swingBuffer = 0.5 * atr;  // буфер кластеризации
   
   //--- ищем swing low за последние 100 баров InpTF
   for(int i = depth + 1; i < MathMin(100, iBars(_Symbol, InpTF)); i++)
     {
      double l_curr = iLow(_Symbol, InpTF, i);
      bool isSwing = true;
      
      //--- проверка: текущий лоу ниже всех соседей на глубине depth
      for(int j = 1; j <= depth; j++)
        {
         if(iLow(_Symbol, InpTF, i - j) <= l_curr)
            isSwing = false;
         if(iLow(_Symbol, InpTF, i + j) <= l_curr)
            isSwing = false;
        }
      
      if(isSwing)
        {
         //--- проверка кластеризации: есть ли уже похожий уровень
         bool found = false;
         for(int j = 0; j < ns; j++)
           {
            if(MathAbs(s[j] - l_curr) <= swingBuffer)
             {
              found = true;
              break;
             }
           }
         
         if(!found && ns < 10)
            s[ns++] = l_curr;
        }
     }
  }

void CalcSwingResistance(double &r[], int &nr, int depth)
  {
   ArrayResize(r, 10);
   nr = 0;
   
   double atr = GetAtr(0);
   if(atr <= 0.0)
      return;
   
   double swingBuffer = 0.5 * atr;
   
   for(int i = depth + 1; i < MathMin(100, iBars(_Symbol, InpTF)); i++)
     {
      double h_curr = iHigh(_Symbol, InpTF, i);
      bool isSwing = true;
      
      for(int j = 1; j <= depth; j++)
        {
         if(iHigh(_Symbol, InpTF, i - j) >= h_curr)
            isSwing = false;
         if(iHigh(_Symbol, InpTF, i + j) >= h_curr)
            isSwing = false;
        }
      
      if(isSwing)
        {
         bool found = false;
         for(int j = 0; j < nr; j++)
           {
            if(MathAbs(r[j] - h_curr) <= swingBuffer)
             {
              found = true;
              break;
             }
           }
         
         if(!found && nr < 10)
            r[nr++] = h_curr;
        }
     }
  }

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

bool HasPositionComment(const string fragment)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), fragment) >= 0)
         return true;
     }
   return false;
  }

bool StrategyTriggeredToday(const string fragment)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);
   
   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return false;
   
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(StringFind(HistoryDealGetString(ticket, DEAL_COMMENT), fragment) >= 0)
         return true;
     }
   return false;
  }

void DrawLevelLines()
  {
   double close = iClose(_Symbol, InpTF, 1);
   
   double s[];
   int ns = 0;
   CalcSupport(InpMethodSup, s, ns);
   double sup = 0.0;
   bool hasSup = (ns > 0 && NearestSupport(s, ns, close, sup));
   
   double r[];
   int nr = 0;
   CalcResistance(InpMethodRes, r, nr);
   double res = 0.0;
   bool hasRes = (nr > 0 && NearestResistance(r, nr, close, res));
   
   ObjectDelete(0, "FVPatBounce_SupLine");
   ObjectDelete(0, "FVPatBounce_ResLine");
   
   if(hasSup)
     {
      if(ObjectCreate(0, "FVPatBounce_SupLine", OBJ_HLINE, 0, 0, NormalizePrice(sup)))
        {
         ObjectSetInteger(0, "FVPatBounce_SupLine", OBJPROP_COLOR, clrDodgerBlue);
         ObjectSetInteger(0, "FVPatBounce_SupLine", OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, "FVPatBounce_SupLine", OBJPROP_WIDTH, 2);
         ObjectSetString(0, "FVPatBounce_SupLine", OBJPROP_TEXT, "S");
        }
     }
   if(hasRes)
     {
      if(ObjectCreate(0, "FVPatBounce_ResLine", OBJ_HLINE, 0, 0, NormalizePrice(res)))
        {
         ObjectSetInteger(0, "FVPatBounce_ResLine", OBJPROP_COLOR, clrOrangeRed);
         ObjectSetInteger(0, "FVPatBounce_ResLine", OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, "FVPatBounce_ResLine", OBJPROP_WIDTH, 2);
         ObjectSetString(0, "FVPatBounce_ResLine", OBJPROP_TEXT, "R");
        }
     }
   ChartRedraw();
  }

void RemoveLevelLines()
  {
   ObjectDelete(0, "FVPatBounce_SupLine");
   ObjectDelete(0, "FVPatBounce_ResLine");
   ChartRedraw();
  }

//--- Кнопки и управление (копировано из FV_Bounce.mq5 с переименованием)
string PauseVarName() { return "FVPatBounce_Pause_" + _Symbol; }
string LinesVarName() { return "FVPatBounce_Lines_" + _Symbol; }
string BuyVarName() { return "FVPatBounce_Buy_" + _Symbol; }
string SellVarName() { return "FVPatBounce_Sell_" + _Symbol; }

void TogglePause()
  {
   g_paused = !g_paused;
   GlobalVariableSet(PauseVarName(), g_paused ? 1.0 : 0.0);
   if(g_paused) SetStopsOnPause();
   UpdatePauseButton();
  }

void ToggleLines()
  {
   g_showLines = !g_showLines;
   GlobalVariableSet(LinesVarName(), g_showLines ? 1.0 : 0.0);
   if(g_showLines)
      DrawLevelLines();
   else
      RemoveLevelLines();
   UpdateLinesButton();
  }

void ToggleBuy()
  {
   g_enableBuy = !g_enableBuy;
   GlobalVariableSet(BuyVarName(), g_enableBuy ? 1.0 : 0.0);
   UpdateBuySellButtons();
  }

void ToggleSell()
  {
   g_enableSell = !g_enableSell;
   GlobalVariableSet(SellVarName(), g_enableSell ? 1.0 : 0.0);
   UpdateBuySellButtons();
  }

void UpdatePauseButton()
  {
   if(g_paused)
     {
      g_btnPause.Description("Пауза: ВКЛ");
      g_btnPause.BackColor(clrRed);
      g_btnPause.BorderColor(clrDarkRed);
     }
   else
     {
      g_btnPause.Description("Пауза: ВЫКЛ");
      g_btnPause.BackColor(clrGreen);
      g_btnPause.BorderColor(clrDarkGreen);
     }
   ChartRedraw();
  }

void UpdateLinesButton()
  {
   if(g_showLines)
     {
      g_btnLines.Description("Линии: ВКЛ");
      g_btnLines.BackColor(clrGreen);
      g_btnLines.BorderColor(clrDarkGreen);
     }
   else
     {
      g_btnLines.Description("Линии: ВЫКЛ");
      g_btnLines.BackColor(clrDarkGray);
      g_btnLines.BorderColor(clrGray);
     }
   ChartRedraw();
  }

void UpdateBuySellButtons()
  {
   if(g_enableBuy)
     {
      g_btnBuy.Description("Поддержка: ВКЛ");
      g_btnBuy.BackColor(clrGreen);
      g_btnBuy.BorderColor(clrDarkGreen);
     }
   else
     {
      g_btnBuy.Description("Поддержка: ВЫКЛ");
      g_btnBuy.BackColor(clrDarkGray);
      g_btnBuy.BorderColor(clrGray);
     }
   if(g_enableSell)
     {
      g_btnSell.Description("Сопрот.: ВКЛ");
      g_btnSell.BackColor(clrGreen);
      g_btnSell.BorderColor(clrDarkGreen);
     }
   else
     {
      g_btnSell.Description("Сопрот.: ВЫКЛ");
      g_btnSell.BackColor(clrDarkGray);
      g_btnSell.BorderColor(clrGray);
     }
   ChartRedraw();
  }

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

void CancelSymbolPending()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(trade.OrderDelete(ticket))
         n++;
     }
   PrintFormat("FVPatBounce: снято отложенных ордеров по %s: %d", _Symbol, n);
  }

void CancelAllPending(const string reason)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(trade.OrderDelete(ticket))
         n++;
     }
   PrintFormat("FVPatBounce: %s: снято отложенных ордеров всего: %d", reason, n);
  }

void SetStopOnPause(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   
   double atr = GetAtr(0);
   if(atr <= 0.0)
      return;
   
   long type = PositionGetInteger(POSITION_TYPE);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double dist = InpTrailMult * atr;
   
   double new_sl = 0.0;
   if(type == POSITION_TYPE_BUY)
      new_sl = bid - dist;
   else if(type == POSITION_TYPE_SELL)
      new_sl = ask + dist;
   
   if(new_sl > 0.0 && new_sl != sl)
      trade.PositionModify(_Symbol, NormalizePrice(new_sl), NormalizePrice(tp));
  }

void SetStopsOnPause()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      SetStopOnPause(ticket);
     }
  }

void TrailOnePosition(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   
   if(InpTrailMult <= 0.0)
      return;
   
   double atr = GetAtr(0);
   if(atr <= 0.0)
      return;
   
   long type = PositionGetInteger(POSITION_TYPE);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double dist = InpTrailMult * atr;
   
   double new_sl = sl;
   if(type == POSITION_TYPE_BUY)
     {
      double trail = bid - dist;
      if(trail > sl)
         new_sl = trail;
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double trail = ask + dist;
      if(trail < sl)
         new_sl = trail;
     }
   
   if(new_sl != sl)
     {
      double new_tp = (InpTrailRemoveTP && tp > 0.0) ? 0.0 : tp;
      trade.PositionModify(_Symbol, NormalizePrice(new_sl), NormalizePrice(new_tp));
     }
  }

void TrailPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      TrailOnePosition(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Главная логика: маркет-входы при подтверждении паттерна         |
//+------------------------------------------------------------------+
void ManagePatternEntries()
  {
   if(g_paused)
      return;
   
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   
   double close = iClose(_Symbol, InpTF, 1);
   double atr   = GetAtr(1);
   if(atr <= 0.0)
      return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double zone = InpEntryZoneBuffer * atr;
   
   //--- проверяем паттерн на текущей свече (уже закрытой на графике)
   if(!IsPatternConfirmed(0))
      return;
   
   //=================================================================
   // Маркет-вход от ПОДДЕРЖКИ (Buy)
   //=================================================================
   if(InpEnableBuy && g_enableBuy && !HasPositionComment("FPB_Sup"))
     {
      double s[];
      int ns = 0;
      CalcSupport(InpMethodSup, s, ns);
      if(ns > 0)
        {
         double sup = 0.0;
         if(NearestSupport(s, ns, close, sup))
           {
            //--- цена должна быть в зоне уровня поддержки
            if(MathAbs(close - sup) <= zone)
              {
               if(!InpNoRepeatSameDay || !StrategyTriggeredToday("FPB_Sup"))
                 {
                  double entry = bid;
                  double sl    = entry - InpSlAttrMult * atr;
                  double tp    = entry + InpSlAttrMult * InpRiskReward * atr;
                  
                  if(trade.Buy(NormalizeLot(InpLot), _Symbol, entry, NormalizePrice(sl), NormalizePrice(tp), "FPB_Sup"))
                     PrintFormat("FVPatBounce: Buy (паттерн) @ %.5f, SL %.5f, TP %.5f (S=%.5f)", entry, sl, tp, sup);
                 }
              }
           }
        }
     }
   
   //=================================================================
   // Маркет-вход от СОПРОТИВЛЕНИЯ (Sell)
   //=================================================================
   if(InpEnableSell && g_enableSell && !HasPositionComment("FPB_Res"))
     {
      double r[];
      int nr = 0;
      CalcResistance(InpMethodRes, r, nr);
      if(nr > 0)
        {
         double res = 0.0;
         if(NearestResistance(r, nr, close, res))
           {
            if(MathAbs(close - res) <= zone)
              {
               if(!InpNoRepeatSameDay || !StrategyTriggeredToday("FPB_Res"))
                 {
                  double entry = ask;
                  double sl    = entry + InpSlAttrMult * atr;
                  double tp    = entry - InpSlAttrMult * InpRiskReward * atr;
                  
                  if(trade.Sell(NormalizeLot(InpLot), _Symbol, entry, NormalizePrice(sl), NormalizePrice(tp), "FPB_Res"))
                     PrintFormat("FVPatBounce: Sell (паттерн) @ %.5f, SL %.5f, TP %.5f (R=%.5f)", entry, sl, tp, res);
                 }
              }
           }
        }
     }
   
   if(g_showLines)
      DrawLevelLines();
  }

bool CreateBtn(CChartObjectButton &btn, string name, int y, string text, color bg, color border)
  {
   if(!btn.Create(0, name, 0, InpBtnX, y, 150, 26))
      return false;
   btn.Description(text);
   btn.Font("Arial");
   btn.FontSize(9);
   btn.Color(clrWhite);
   btn.BackColor(bg);
   btn.BorderColor(border);
   btn.Corner(CORNER_LEFT_UPPER);
   btn.Selectable(false);
   btn.Z_Order(0);
   btn.State(false);
   return true;
  }

bool CreateButtons()
  {
   int y = InpBtnY;
   if(!CreateBtn(g_btnPause, g_btnPauseName, y, "Пауза: ВЫКЛ", clrGreen, clrDarkGreen))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnCancel, g_btnCancelName, y, "Снять по паре", clrFireBrick, clrDarkRed))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnLines, g_btnLinesName, y, "Линии: ВКЛ", clrGreen, clrDarkGreen))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnCancelAll, g_btnCancelAllName, y, "Снять все ордера", clrFireBrick, clrDarkRed))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnEmergency, g_btnEmergencyName, y, "ЭКСТРЕННО", clrRed, clrMaroon))
      return false;
   
   if(!CreateBtn(g_btnBuy, g_btnBuyName, InpBtn2Y, "Поддержка: ВКЛ", clrGreen, clrDarkGreen))
      return false;
   if(!CreateBtn(g_btnSell, g_btnSellName, InpBtn2Y + InpBtnGap, "Сопрот.: ВКЛ", clrGreen, clrDarkGreen))
      return false;
   ObjectSetInteger(0, g_btnBuyName, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, g_btnBuyName, OBJPROP_XDISTANCE, InpBtn2X);
   ObjectSetInteger(0, g_btnBuyName, OBJPROP_YDISTANCE, InpBtn2Y);
   ObjectSetInteger(0, g_btnSellName, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, g_btnSellName, OBJPROP_XDISTANCE, InpBtn2X);
   ObjectSetInteger(0, g_btnSellName, OBJPROP_YDISTANCE, InpBtn2Y + InpBtnGap);
   
   UpdatePauseButton();
   UpdateLinesButton();
   UpdateBuySellButtons();
   return true;
  }

void DestroyButtons()
  {
   ObjectDelete(0, g_btnPauseName);
   ObjectDelete(0, g_btnCancelName);
   ObjectDelete(0, g_btnCancelAllName);
   ObjectDelete(0, g_btnEmergencyName);
   ObjectDelete(0, g_btnLinesName);
   ObjectDelete(0, g_btnBuyName);
   ObjectDelete(0, g_btnSellName);
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_atr_handle = iATR(_Symbol, InpTF, InpAtrPeriod);
   g_last_manage = 0;
   
   if((bool)MQLInfoInteger(MQL_TESTER))
     {
      g_paused     = false;
      g_showLines  = InpShowLinesOnStart;
      g_enableBuy  = InpEnableBuy;
      g_enableSell = InpEnableSell;
     }
   else
     {
      g_paused     = GlobalVariableCheck(PauseVarName()) && GlobalVariableGet(PauseVarName()) > 0.5;
      g_showLines  = !GlobalVariableCheck(LinesVarName()) || GlobalVariableGet(LinesVarName()) > 0.5;
      g_enableBuy  = !GlobalVariableCheck(BuyVarName()) || GlobalVariableGet(BuyVarName()) > 0.5;
      g_enableSell = !GlobalVariableCheck(SellVarName()) || GlobalVariableGet(SellVarName()) > 0.5;
     }
   
   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(InpLot < minlot || InpAtrPeriod < 2 || InpSlAttrMult < 0.1)
      return INIT_PARAMETERS_INCORRECT;
   
   PrintFormat("FVPatBounce: паттерны (pin bar=%s, engulfing=%s, doji=%s), "
               "методы уровней (поддержка=%d, сопротивление=%d), "
               "swing depth=%d",
               InpUsePinBar ? "ВКЛ" : "ВЫКЛ",
               InpUseEngulfing ? "ВКЛ" : "ВЫКЛ",
               InpUseDoji ? "ВКЛ" : "ВЫКЛ",
               (int)InpMethodSup, (int)InpMethodRes,
               InpSwingDepth);
   
   if(InpBtnEnable)
     {
      if(!CreateButtons())
         PrintFormat("FVPatBounce: ошибка создания кнопок");
     }
   
   if(g_showLines)
      DrawLevelLines();
   
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   DestroyButtons();
   RemoveLevelLines();
   PrintFormat("FVPatBounce: deinit, reason=%d", reason);
  }

void OnTick()
  {
   //--- проверяем паттерны каждый тик
   ManagePatternEntries();
   
   //--- трейлинг всех позиций
   TrailPosition();
  }

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   
   if(sparam == g_btnPauseName)
     {
      g_btnPause.State(false);
      TogglePause();
     }
   else if(sparam == g_btnCancelName)
     {
      g_btnCancel.State(false);
      CancelSymbolPending();
     }
   else if(sparam == g_btnCancelAllName)
     {
      g_btnCancelAll.State(false);
      CancelAllPending("снять все ордера");
     }
   else if(sparam == g_btnEmergencyName)
     {
      g_btnEmergency.State(false);
      CancelAllPending("ЭКСТРЕННО");
     }
   else if(sparam == g_btnLinesName)
     {
      g_btnLines.State(false);
      ToggleLines();
     }
   else if(sparam == g_btnBuyName)
     {
      g_btnBuy.State(false);
      ToggleBuy();
     }
   else if(sparam == g_btnSellName)
     {
      g_btnSell.State(false);
      ToggleSell();
     }
  }
//+------------------------------------------------------------------+
//| Конец                                                            |
//+------------------------------------------------------------------+