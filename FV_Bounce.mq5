//+------------------------------------------------------------------+
//|                                                     FV_Bounce.mq5 |
//|  Отскок от дневных уровней (Camarilla / Pivot / DeMark)          |
//|  Лимитные ордера перед уровнем с ATR-множителями:                |
//|    Buy  Limit = S + buffer_atr_s * ATR   (лонг от поддержки S)   |
//|    Sell Limit = R - buffer_atr_r * ATR   (шорт от сопротивления) |
//|    SL = sl_atr * ATR, TP = tp_atr * ATR, трейлинг = trail * ATR  |
//|  Метод уровней выбирается отдельно для поддержки и сопротивления.|
//|  Уровни рассчитываются по D1 вручную - логика повторяет          |
//|  bounce_atr_opt.py (backtesting.py). На графике рисуются линии   |
//|  поддержки и сопротивления по выбранным методам, кнопка          |
//|  включает/выключает их отображение.                             |
//|  Дополнительная стратегия ПРОБОЙ: стоп-ордер ставится на уровне  |
//|  SL отскока +/- буфер, SL/TP/trail - свои множители (xATR).      |
//|  Пробой поддержки вниз -> Sell Stop, пробой сопротивления вверх  |
//|  -> Buy Stop. Ордера выставляются 1 раз в InpOrderIntervalHours. |
//|  Пробойный ордер НЕ снимается при открытой позиции отскока и     |
//|  может сработать вторым входом. Одновременно они не откроются:   |
//|  точка пробоя = SL отскока, поэтому отскок закроется по SL       |
//|  раньше, чем сработает пробой. Ничего не снимается из-за         |
//|  количества открытых позиций.                                    |
//|  v1.20: пробойные стопы ставятся только с правильной стороны     |
//|  рынка (Sell Stop ниже bid, Buy Stop выше ask).                  |
//|  v1.21: три кнопки снятия ордеров:                               |
//|    «Снять по паре» - все отложенные по текущему символу,         |
//|      без фильтра по магику (все советники);                      |
//|    «Снять все ордера» - ВСЕ отложенные ордера терминала          |
//|      (все символы, кто бы ни выставил);                          |
//|    «ЭКСТРЕННО» - экстренное снятие всех отложенных ордеров.      |
//|  В ManageOrders по-прежнему снимаются только СВОИ ордера (магик).|
//|  v1.22: советник НЕ зависит от таймфрейма графика: ATR и close   |
//|  считаются на фиксированном таймфрейме InpTF (по умолчанию H1)  |
//|  v1.23: при активации трейлинга TP снимается (InpTrailRemoveTP); |
//|  если InpNoRepeatSameDay=false, ордер, сработавший сегодня,      |
//|  повторно в этот день не выставляется.                           |
//+------------------------------------------------------------------+
//|  v1.24: при оптимизации пропускаются варианты с SL >= TP (xATR). |
#property copyright "FV_Bounce"
#property version   "1.24"

#include <Trade/Trade.mqh>
#include <ChartObjects/ChartObjectsTxtControls.mqh>

//--- методы дневных уровней
enum ENUM_METHOD
  {
   METHOD_CAMARILLA = 0,   // Camarilla
   METHOD_PIVOT     = 1,   // Pivot (классика)
   METHOD_DEMARK    = 2    // DeMark
  };

//--- входные параметры
input group           "Уровни"
input ENUM_TIMEFRAMES InpTF          = PERIOD_H1;      // Таймфрейм расчёта (ATR, close)
input int             InpAtrPeriod   = 14;            // Период ATR

input group           "Отскок от ПОДДЕРЖКИ S"
input ENUM_METHOD     InpMethodSup   = METHOD_DEMARK;  // Метод уровней поддержки
input bool            InpEnableSup   = true;           // Включить отскок от поддержки
input double          InpBufferSup   = 0.25;           // Буфер S (поддержка), xATR
input double          InpSlSup       = 3.00;           // SL S (поддержка), xATR
input double          InpTpSup       = 2.00;           // TP S (поддержка), xATR
input double          InpTrailSup    = 2.00;           // Трейлинг S (поддержка), xATR (0 = выкл)

input group           "Пробой от ПОДДЕРЖКИ (SL отскока)"
input bool            InpEnableBkSup = false;          // Включить пробой от поддержки
input double          InpBkBufferSup = 0.01;           // Буфер пробоя поддержки, xATR (от SL отскока)
input double          InpBkSlSup     = 3.00;           // SL пробоя поддержки, xATR
input double          InpBkTpSup     = 2.00;           // TP пробоя поддержки, xATR
input double          InpBkTrailSup  = 2.00;           // Трейлинг пробоя поддержки, xATR (0 = выкл)

input group           "Отскок от СОПРОТИВЛЕНИЯ R"
input ENUM_METHOD     InpMethodRes   = METHOD_DEMARK;  // Метод уровней сопротивления
input bool            InpEnableRes   = true;           // Включить отскок от сопротивления
input double          InpBufferRes   = 1.00;           // Буфер R (сопротивление), xATR
input double          InpSlRes       = 2.00;           // SL R (сопротивление), xATR
input double          InpTpRes       = 1.00;           // TP R (сопротивление), xATR
input double          InpTrailRes    = 1.00;           // Трейлинг R (сопротивление), xATR (0 = выкл)

input group           "Пробой от СОПРОТИВЛЕНИЯ (SL отскока)"
input bool            InpEnableBkRes = false;          // Включить пробой от сопротивления
input double          InpBkBufferRes = 0.01;           // Буфер пробоя сопротивления, xATR (от SL отскока)
input double          InpBkSlRes     = 2.00;           // SL пробоя сопротивления, xATR
input double          InpBkTpRes     = 1.00;           // TP пробоя сопротивления, xATR
input double          InpBkTrailRes  = 1.00;           // Трейлинг пробоя сопротивления, xATR (0 = выкл)

input group           "Торговля"
input int             InpOrderIntervalHours = 4;       // Интервал постановки ордеров, часы
input double          InpLot         = 0.01;           // Объём, лот
input long            InpMagic       = 260813;         // Magic

input group           "Трейлинг"
input bool            InpTrailRemoveTP = true;         // Убирать TP при активации трейлинга

input group           "Повторные входы"
input bool            InpNoRepeatSameDay = false;      // Не выставлять повторно ордер, сработавший сегодня (false = не выставлять)

input group           "Линии"
input bool            InpShowLinesOnStart = true;      // Показывать линии при старте

input group           "Кнопки"
input bool            InpBtnEnable   = true;           // Показать кнопки управления
input int             InpBtnX        = 10;             // Кнопки: X от левого края
input int             InpBtnY        = 30;             // Кнопки: Y первой кнопки от верха
input int             InpBtnGap      = 28;             // Кнопки: расстояние между ними
input int             InpBtn2X       = 10;             // Кнопки Поддержка/Сопротивление: X от левого нижнего угла
input int             InpBtn2Y       = 30;             // Кнопки Поддержка/Сопротивление: Y от нижнего края

CTrade   trade;
CChartObjectButton g_btnPause;
CChartObjectButton g_btnCancel;
CChartObjectButton g_btnCancelAll;
CChartObjectButton g_btnEmergency;
CChartObjectButton g_btnPlace;
CChartObjectButton g_btnLines;
CChartObjectButton g_btnBuy;
CChartObjectButton g_btnSell;
string             g_btnPauseName     = "FV_Bounce_PauseBtn";
string             g_btnCancelName    = "FV_Bounce_CancelBtn";
string             g_btnCancelAllName = "FV_Bounce_CancelAllBtn";
string             g_btnEmergencyName = "FV_Bounce_EmergencyBtn";
string             g_btnPlaceName     = "FV_Bounce_PlaceBtn";
string             g_btnLinesName     = "FV_Bounce_LinesBtn";
string             g_btnBuyName       = "FV_Bounce_BuyBtn";
string             g_btnSellName      = "FV_Bounce_SellBtn";
datetime g_last_manage = 0;      // время последней постановки ордеров
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

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
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
//--- таймфрейм фиксированный (InpTF), не зависит от графика
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
//| Рисование линий поддержки и сопротивления                        |
//|  Линии строятся по тем же методам, что и торговля:               |
//|  поддержка - InpMethodSup, сопротивление - InpMethodRes          |
//+------------------------------------------------------------------+
void DrawLevelLines()
  {
   double close = iClose(_Symbol, InpTF, 1);

   //--- ближайшая поддержка (метод InpMethodSup)
   double s[];
   int ns = 0;
   CalcSupport((ENUM_METHOD)InpMethodSup, s, ns);
   double sup = 0.0;
   bool hasSup = (ns > 0 && NearestSupport(s, ns, close, sup));

   //--- ближайшее сопротивление (метод InpMethodRes)
   double r[];
   int nr = 0;
   CalcResistance((ENUM_METHOD)InpMethodRes, r, nr);
   double res = 0.0;
   bool hasRes = (nr > 0 && NearestResistance(r, nr, close, res));

   //--- старые линии удаляем
   ObjectDelete(0, "FV_Bounce_SupLine");
   ObjectDelete(0, "FV_Bounce_ResLine");

   if(hasSup)
     {
      if(ObjectCreate(0, "FV_Bounce_SupLine", OBJ_HLINE, 0, 0, NormalizePrice(sup)))
        {
         ObjectSetInteger(0, "FV_Bounce_SupLine", OBJPROP_COLOR, clrDodgerBlue);
         ObjectSetInteger(0, "FV_Bounce_SupLine", OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, "FV_Bounce_SupLine", OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, "FV_Bounce_SupLine", OBJPROP_BACK, false);
         ObjectSetString(0, "FV_Bounce_SupLine", OBJPROP_TEXT, "S");
        }
     }
   if(hasRes)
     {
      if(ObjectCreate(0, "FV_Bounce_ResLine", OBJ_HLINE, 0, 0, NormalizePrice(res)))
        {
         ObjectSetInteger(0, "FV_Bounce_ResLine", OBJPROP_COLOR, clrOrangeRed);
         ObjectSetInteger(0, "FV_Bounce_ResLine", OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, "FV_Bounce_ResLine", OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, "FV_Bounce_ResLine", OBJPROP_BACK, false);
         ObjectSetString(0, "FV_Bounce_ResLine", OBJPROP_TEXT, "R");
        }
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Снять линии с графика                                            |
//+------------------------------------------------------------------+
void RemoveLevelLines()
  {
   ObjectDelete(0, "FV_Bounce_SupLine");
   ObjectDelete(0, "FV_Bounce_ResLine");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Кнопка линий (включить/выключить отображение)                    |
//+------------------------------------------------------------------+
string LinesVarName()
  {
   return "FV_Bounce_Lines_" + _Symbol;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ToggleLines()
  {
   g_showLines = !g_showLines;
   GlobalVariableSet(LinesVarName(), g_showLines ? 1.0 : 0.0);
   if(g_showLines)
      DrawLevelLines();
   else
      RemoveLevelLines();
   UpdateLinesButton();
   PrintFormat("FV_Bounce: линии %s", g_showLines ? "ВКЛ" : "ВЫКЛ");
  }

//+------------------------------------------------------------------+
//| Обновление вида кнопки линий                                     |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Кнопки Поддержка/Сопротивление (слева внизу) - постановка ордеров|
//+------------------------------------------------------------------+
string BuyVarName()
  {
   return "FV_Bounce_Buy_" + _Symbol;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string SellVarName()
  {
   return "FV_Bounce_Sell_" + _Symbol;
  }

//+------------------------------------------------------------------+
//| Переключение постановки ордеров от ПОДДЕРЖКИ                    |
//+------------------------------------------------------------------+
void ToggleBuy()
  {
   g_enableBuy = !g_enableBuy;
   GlobalVariableSet(BuyVarName(), g_enableBuy ? 1.0 : 0.0);
   UpdateBuySellButtons();
   if(!g_paused)
      ManageOrders();            // применить сразу: снять лишнее, поставить разрешённое
   PrintFormat("FV_Bounce: постановка ордеров от ПОДДЕРЖКИ %s", g_enableBuy ? "ВКЛ" : "ВЫКЛ");
  }

//+------------------------------------------------------------------+
//| Переключение постановки ордеров от СОПРОТИВЛЕНИЯ                |
//+------------------------------------------------------------------+
void ToggleSell()
  {
   g_enableSell = !g_enableSell;
   GlobalVariableSet(SellVarName(), g_enableSell ? 1.0 : 0.0);
   UpdateBuySellButtons();
   if(!g_paused)
      ManageOrders();            // применить сразу
   PrintFormat("FV_Bounce: постановка ордеров от СОПРОТИВЛЕНИЯ %s", g_enableSell ? "ВКЛ" : "ВЫКЛ");
  }

//+------------------------------------------------------------------+
//| Обновление вида кнопок Поддержка/Сопротивление                  |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Создание кнопок Поддержка/Сопротивление (левый нижний угол)      |
//+------------------------------------------------------------------+
bool CreateBuySellButtons()
  {
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
   UpdateBuySellButtons();
   return true;
  }

//+------------------------------------------------------------------+
//| Поддержки метода из ПРЕДЫДУЩЕГО дня (D1, shift=1) - как в Python |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Сопротивления метода из ПРЕДЫДУЩЕГО дня (D1, shift=1) - как в Py |
//+------------------------------------------------------------------+
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

//--- отмена всех НАШИХ отложенных ордеров (по символу и магику)
//--- используется в ManageOrders при обновлении ордеров
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

//+------------------------------------------------------------------+
//| Кнопка «Снять по паре»: ВСЕ отложенные ордера по текущему символу|
//|  БЕЗ фильтра по магику - снимает ордера любого советника на паре |
//+------------------------------------------------------------------+
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
   PrintFormat("FV_Bounce: снято отложенных ордеров по %s: %d", _Symbol, n);
  }

//+------------------------------------------------------------------+
//| Снять ВСЕ отложенные ордера терминала (все символы, все магики)  |
//|  Используется кнопками «Снять все ордера» и «ЭКСТРЕННО»          |
//+------------------------------------------------------------------+
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
   PrintFormat("FV_Bounce: %s: снято отложенных ордеров всего: %d", reason, n);
  }

//+------------------------------------------------------------------+
//| Имя глобальной переменной для хранения паузы (по символу)        |
//+------------------------------------------------------------------+
string PauseVarName()
  {
   return "FV_Bounce_Pause_" + _Symbol;
  }

//+------------------------------------------------------------------+
//| Переключение паузы (кнопка)                                      |
//+------------------------------------------------------------------+
void TogglePause()
  {
   g_paused = !g_paused;
   GlobalVariableSet(PauseVarName(), g_paused ? 1.0 : 0.0);
   if(g_paused)
      SetStopsOnPause();            // при паузе ставим стопы на открытую позицию
   UpdatePauseButton();
   PrintFormat("FV_Bounce: пауза %s", g_paused ? "ВКЛ (новые ордера не ставятся, стопы установлены)" : "ВЫКЛ (торговля возобновлена)");
  }

//+------------------------------------------------------------------+
//| Установка стопа на одной открытой позиции (по тикету)            |
//+------------------------------------------------------------------+
void SetStopOnPause(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;

   double atr = GetAtr(0);
   if(atr <= 0.0 || !MathIsValidNumber(atr))
      return;

   long   type = PositionGetInteger(POSITION_TYPE);
   string cm   = PositionGetString(POSITION_COMMENT);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double new_sl = 0.0;

   //--- множители по стратегии позиции (по комментарию)
   bool isBk  = (StringFind(cm, "Bk") >= 0);
   bool isSup = (StringFind(cm, "Sup") >= 0);

   double trailMult = 0.0, slMult = 0.0;
   if(isBk)
     {
      trailMult = isSup ? InpBkTrailSup : InpBkTrailRes;
      slMult    = isSup ? InpBkSlSup    : InpBkSlRes;
     }
   else
     {
      trailMult = isSup ? InpTrailSup : InpTrailRes;
      slMult    = isSup ? InpSlSup    : InpSlRes;
     }
   double dist = (trailMult > 0.0 ? trailMult : slMult) * atr;

   if(type == POSITION_TYPE_BUY)
     {
      new_sl = bid - dist;
      if(sl > 0.0 && sl > new_sl)
         new_sl = sl;               // не ухудшаем текущий SL
     }
   else if(type == POSITION_TYPE_SELL)
     {
      new_sl = ask + dist;
      if(sl > 0.0 && sl < new_sl)
         new_sl = sl;               // не ухудшаем текущий SL
     }

   if(new_sl > 0.0)
      if(trade.PositionModify(_Symbol, NormalizePrice(new_sl), NormalizePrice(tp)))
         PrintFormat("FV_Bounce: стоп при паузе -> %.5f (comment=%s)", new_sl, cm);
  }

//+------------------------------------------------------------------+
//| Установка стопов на ВСЕХ наших открытых позициях при паузе       |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Обновление внешнего вида кнопки паузы по её состоянию            |
//|   зелёная = паузы нет, красная = пауза (стопы установлены)      |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Создание одной кнопки                                            |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Создание всех кнопок                                             |
//+------------------------------------------------------------------+
bool CreateButtons()
  {
   int y = InpBtnY;
   if(!CreateBtn(g_btnPause,     g_btnPauseName,     y, "Пауза: ВЫКЛ", clrGreen, clrDarkGreen))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnCancel,    g_btnCancelName,    y, "Снять по паре " + _Symbol, clrFireBrick, clrDarkRed))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnPlace,     g_btnPlaceName,     y, "Ставить ордера", clrRoyalBlue, clrMidnightBlue))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnLines,     g_btnLinesName,     y, "Линии: ВКЛ", clrGreen, clrDarkGreen))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnCancelAll, g_btnCancelAllName, y, "Снять все ордера", clrFireBrick, clrDarkRed))
      return false;
   y += InpBtnGap;
   if(!CreateBtn(g_btnEmergency, g_btnEmergencyName, y, "ЭКСТРЕННО", clrRed, clrMaroon))
      return false;
   UpdatePauseButton();
   UpdateLinesButton();
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DestroyButtons()
  {
   ObjectDelete(0, g_btnPauseName);
   ObjectDelete(0, g_btnCancelName);
   ObjectDelete(0, g_btnCancelAllName);
   ObjectDelete(0, g_btnEmergencyName);
   ObjectDelete(0, g_btnPlaceName);
   ObjectDelete(0, g_btnLinesName);
   ObjectDelete(0, g_btnBuyName);
   ObjectDelete(0, g_btnSellName);
  }

//+------------------------------------------------------------------+
//| Есть ли открытая позиция с комментарием, содержащим фрагмент     |
//|  Например: "Sup" -> FV_B_Sup / FV_Bk_Sup                         |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Срабатывал ли ордер стратегии сегодня                             |
//|  Проверяется по истории текущего дня: входящая сделка            |
//|  (DEAL_ENTRY_IN) по нашему символу и магику с комментарием,      |
//|  содержащим фрагмент (например "FV_B_Sup"). Используется при     |
//|  InpNoRepeatSameDay=false, чтобы не выставлять повторно ордер,   |
//|  который уже сработал в этот день.                               |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Трейлинг одной открытой позиции (по тикету)                      |
//|  Использует множители той стратегии, которой открыта позиция:    |
//|  отскок (InpTrailSup/Res) или пробой (InpBkTrailSup/Res)         |
//|  При активации трейлинга TP снимается, если включено флагом      |
//|  InpTrailRemoveTP.                                               |
//+------------------------------------------------------------------+
void TrailOnePosition(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;

   double atr = GetAtr(0);
   if(atr <= 0.0 || !MathIsValidNumber(atr))
      return;

   long type = PositionGetInteger(POSITION_TYPE);
   string cm = PositionGetString(POSITION_COMMENT);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- множители трейлинга по стратегии позиции (по комментарию)
   bool isBk  = (StringFind(cm, "Bk") >= 0);
   bool isSup = (StringFind(cm, "Sup") >= 0);
   double trailMult = isBk ? (isSup ? InpBkTrailSup : InpBkTrailRes)
                           : (isSup ? InpTrailSup   : InpTrailRes);

   //--- трейлинг отключён, если множитель = 0 (выход только по SL/TP)
   if(trailMult <= 0.0)
      return;

   double new_sl = sl;
   if(type == POSITION_TYPE_BUY)
     {
      double trail = bid - trailMult * atr;
      if(trail > sl + _Point * 0.5)
         new_sl = trail;
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double trail = ask + trailMult * atr;
      if(trail < sl - _Point * 0.5)
         new_sl = trail;
     }

   if(new_sl != sl)
     {
      //--- при активации трейлинга убираем TP, если включено флагом
      bool tpRemoved = (InpTrailRemoveTP && tp > 0.0);
      double new_tp = tpRemoved ? 0.0 : tp;
      if(trade.PositionModify(_Symbol, NormalizePrice(new_sl), NormalizePrice(new_tp)))
         PrintFormat("Trailing SL -> %.5f%s (comment=%s)",
                     new_sl, tpRemoved ? ", TP убран" : "", cm);
     }
  }

//+------------------------------------------------------------------+
//| Трейлинг ВСЕХ наших открытых позиций (каждый тик)                |
//+------------------------------------------------------------------+
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
//| Периодическая постановка ордеров (раз в InpOrderIntervalHours)   |
//|  Правила:                                                        |
//|   - пробойный ордер ставится, пока не открылась ЕГО позиция      |
//|   - отскокный ордер не ставится повторно, если позиция           |
//|     этой стратегии (отскок или пробой) уже открыта               |
//|  Ничего не снимается из-за количества открытых позиций:          |
//|  отскок и пробой не могут быть открыты одновременно (точка       |
//|  пробоя = SL отскока, отскок закроется по SL раньше пробоя).     |
//|  Пробойные стопы ставятся только с правильной стороны рынка:     |
//|  Sell Stop ниже bid, Buy Stop выше ask.                          |
//|  При обновлении снимаются ТОЛЬКО свои ордера (по магику).        |
//|  При InpNoRepeatSameDay=false ордер, сработавший сегодня,        |
//|  повторно в этот день не выставляется.                           |
//|  Расчёт (close, ATR) - на таймфрейме InpTF, не на графике.       |
//+------------------------------------------------------------------+
void ManageOrders()
  {
   //--- пауза включена: новые ордера не ставим
   if(g_paused)
     {
      PrintFormat("FV_Bounce: ManageOrders - ПАУЗА, ордера не ставятся");
      return;
     }

   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      PrintFormat("FV_Bounce: ManageOrders - нет доступа к торговле (conn=%d, trade=%d, mql=%d)",
                  TerminalInfoInteger(TERMINAL_CONNECTED),
                  TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),
                  MQLInfoInteger(MQL_TRADE_ALLOWED));
      return;
     }

   //--- сначала снимаем старые ордера (только свои, по магику)
   CancelPending();

   //--- данные последнего закрытого бара таймфрейма InpTF (в Python - бар i в next())
   double close = iClose(_Symbol, InpTF, 1);
   double atr   = GetAtr(1);
   if(atr <= 0.0 || !MathIsValidNumber(atr))
     {
      PrintFormat("FV_Bounce: ManageOrders - ATR=%.5f (нет данных), ордера не ставятся", atr);
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //=================================================================
   // ОТСКОК от ПОДДЕРЖКИ: Buy Limit = S + buffer_s * ATR
   //=================================================================
   if(InpEnableSup && g_enableBuy)
     {
      double s[];
      int ns = 0;
      CalcSupport((ENUM_METHOD)InpMethodSup, s, ns);
      if(ns > 0)
        {
         double sup = 0.0;
         if(NearestSupport(s, ns, close, sup))
           {
            double entry = sup + InpBufferSup * atr;
            double sl    = entry - InpSlSup * atr;
            double tp    = entry + InpTpSup * atr;

            //--- ОТСКОК: не ставим повторно, если позиция этой стратегии уже открыта
            //--- или (при InpNoRepeatSameDay=false) если ордер уже срабатывал сегодня
            bool condBounce = (close > entry && entry < bid);  // цена выше ордера и вне спреда
            bool trigToday  = (!InpNoRepeatSameDay && StrategyTriggeredToday("FV_B_Sup"));
            if(condBounce && !HasPositionComment("Sup") && !trigToday)
              {
               if(trade.BuyLimit(NormalizeLot(InpLot), NormalizePrice(entry), _Symbol,
                                 NormalizePrice(sl), NormalizePrice(tp), ORDER_TIME_GTC, 0, "FV_B_Sup"))
                  PrintFormat("BuyLimit(отскок поддержки) %.5f, SL %.5f, TP %.5f (S=%.5f, ATR=%.5f)",
                              entry, sl, tp, sup, atr);
               else
                  PrintFormat("BuyLimit fail, retcode=%d", trade.ResultRetcode());
              }
            else if(!condBounce)
               PrintFormat("FV_Bounce: BuyLimit условие не выполнено: close=%.5f entry=%.5f bid=%.5f", close, entry, bid);
            else if(HasPositionComment("Sup"))
               PrintFormat("FV_Bounce: BuyLimit пропущен - уже есть позиция стратегии ПОДДЕРЖКА");
            else
               PrintFormat("FV_Bounce: BuyLimit пропущен - ордер отскока уже срабатывал сегодня");

            //--- ПРОБОЙ от ПОДДЕРЖКИ: Sell Stop = SL отскока - буфер (пробой вниз)
            //--- остаётся стоять при открытой позиции отскока (отскок закроется по SL раньше)
            if(InpEnableBkSup && g_enableBuy)
              {
               if(HasPositionComment("FV_Bk_Sup"))
                  PrintFormat("FV_Bounce: SellStop(пробой поддержки) пропущен - позиция пробоя уже открыта");
               else if(!InpNoRepeatSameDay && StrategyTriggeredToday("FV_Bk_Sup"))
                  PrintFormat("FV_Bounce: SellStop(пробой поддержки) пропущен - пробой уже срабатывал сегодня");
               else
                 {
                  double bkEntry = sl - InpBkBufferSup * atr; // точка пробоя = SL отскока - буфер
                  if(bkEntry < bid)   // Sell Stop обязан стоять НИЖЕ рынка
                    {
                     double bkSl = bkEntry + InpBkSlSup * atr;   // SL шорта выше входа
                     double bkTp = bkEntry - InpBkTpSup * atr;   // TP шорта ниже входа
                     if(trade.SellStop(NormalizeLot(InpLot), NormalizePrice(bkEntry), _Symbol,
                                       NormalizePrice(bkSl), NormalizePrice(bkTp), ORDER_TIME_GTC, 0, "FV_Bk_Sup"))
                        PrintFormat("SellStop(пробой поддержки) %.5f, SL %.5f, TP %.5f (SL отскока=%.5f, буфер=%.3f, ATR=%.5f)",
                                    bkEntry, bkSl, bkTp, sl, InpBkBufferSup, atr);
                     else
                        PrintFormat("SellStop(пробой поддержки) fail, retcode=%d", trade.ResultRetcode());
                    }
                  else
                     PrintFormat("SellStop(пробой поддержки) пропущен: уровень %.5f не ниже рынка (bid=%.5f)", bkEntry, bid);
                 }
              }
           }
         else
            PrintFormat("FV_Bounce: нет ближайшей поддержки <= close=%.5f", close);
        }
      else
         PrintFormat("FV_Bounce: нет уровней поддержки (ns=%d)", ns);
     }
   else
      PrintFormat("FV_Bounce: отскок от поддержки ВЫКЛ (InpEnableSup=%d, кнопка=%d)", InpEnableSup, g_enableBuy);

   //=================================================================
   // ОТСКОК от СОПРОТИВЛЕНИЯ: Sell Limit = R - buffer_r * ATR
   //=================================================================
   if(InpEnableRes && g_enableSell)
     {
      double r[];
      int nr = 0;
      CalcResistance((ENUM_METHOD)InpMethodRes, r, nr);
      if(nr > 0)
        {
         double res = 0.0;
         if(NearestResistance(r, nr, close, res))
           {
            double entry = res - InpBufferRes * atr;
            double sl    = entry + InpSlRes * atr;
            double tp    = entry - InpTpRes * atr;

            //--- ОТСКОК: не ставим повторно, если позиция этой стратегии уже открыта
            //--- или (при InpNoRepeatSameDay=false) если ордер уже срабатывал сегодня
            bool condBounce = (close < entry && entry > ask);  // цена ниже ордера и вне спреда
            bool trigToday  = (!InpNoRepeatSameDay && StrategyTriggeredToday("FV_B_Res"));
            if(condBounce && !HasPositionComment("Res") && !trigToday)
              {
               if(trade.SellLimit(NormalizeLot(InpLot), NormalizePrice(entry), _Symbol,
                                  NormalizePrice(sl), NormalizePrice(tp), ORDER_TIME_GTC, 0, "FV_B_Res"))
                  PrintFormat("SellLimit(отскок сопротивления) %.5f, SL %.5f, TP %.5f (R=%.5f, ATR=%.5f)",
                              entry, sl, tp, res, atr);
               else
                  PrintFormat("SellLimit fail, retcode=%d", trade.ResultRetcode());
              }
            else if(!condBounce)
               PrintFormat("FV_Bounce: SellLimit условие не выполнено: close=%.5f entry=%.5f ask=%.5f", close, entry, ask);
            else if(HasPositionComment("Res"))
               PrintFormat("FV_Bounce: SellLimit пропущен - уже есть позиция стратегии СОПРОТИВЛЕНИЕ");
            else
               PrintFormat("FV_Bounce: SellLimit пропущен - ордер отскока уже срабатывал сегодня");

            //--- ПРОБОЙ от СОПРОТИВЛЕНИЯ: Buy Stop = SL отскока + буфер (пробой вверх)
            //--- остаётся стоять при открытой позиции отскока (отскок закроется по SL раньше)
            if(InpEnableBkRes && g_enableSell)
              {
               if(HasPositionComment("FV_Bk_Res"))
                  PrintFormat("FV_Bounce: BuyStop(пробой сопротивления) пропущен - позиция пробоя уже открыта");
               else if(!InpNoRepeatSameDay && StrategyTriggeredToday("FV_Bk_Res"))
                  PrintFormat("FV_Bounce: BuyStop(пробой сопротивления) пропущен - пробой уже срабатывал сегодня");
               else
                 {
                  double bkEntry = sl + InpBkBufferRes * atr; // точка пробоя = SL отскока + буфер
                  if(bkEntry > ask)   // Buy Stop обязан стоять ВЫШЕ рынка
                    {
                     double bkSl = bkEntry - InpBkSlRes * atr;   // SL лонга ниже входа
                     double bkTp = bkEntry + InpBkTpRes * atr;   // TP лонга выше входа
                     if(trade.BuyStop(NormalizeLot(InpLot), NormalizePrice(bkEntry), _Symbol,
                                      NormalizePrice(bkSl), NormalizePrice(bkTp), ORDER_TIME_GTC, 0, "FV_Bk_Res"))
                        PrintFormat("BuyStop(пробой сопротивления) %.5f, SL %.5f, TP %.5f (SL отскока=%.5f, буфер=%.3f, ATR=%.5f)",
                                    bkEntry, bkSl, bkTp, sl, InpBkBufferRes, atr);
                     else
                        PrintFormat("BuyStop(пробой сопротивления) fail, retcode=%d", trade.ResultRetcode());
                    }
                  else
                     PrintFormat("BuyStop(пробой сопротивления) пропущен: уровень %.5f не выше рынка (ask=%.5f)", bkEntry, ask);
                 }
              }
           }
         else
            PrintFormat("FV_Bounce: нет ближайшего сопротивления >= close=%.5f", close);
        }
      else
         PrintFormat("FV_Bounce: нет уровней сопротивления (nr=%d)", nr);
     }
   else
      PrintFormat("FV_Bounce: отскок от сопротивления ВЫКЛ (InpEnableRes=%d, кнопка=%d)", InpEnableRes, g_enableSell);

   //--- обновляем линии по текущим уровням
   if(g_showLines)
      DrawLevelLines();
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_atr_handle = iATR(_Symbol, InpTF, InpAtrPeriod);
   g_last_manage = 0;             // первый тик сразу выполнит ManageOrders()

   //--- состояние кнопок из глобальных переменных (live).
   //--- в тестере всегда берём входные параметры, чтобы тестер не зависел
   //--- от состояния кнопок/паузы, оставшегося с live-графика.
   if((bool)MQLInfoInteger(MQL_TESTER))
     {
      g_paused     = false;
      g_showLines  = InpShowLinesOnStart;
      g_enableBuy  = true;
      g_enableSell = true;
     }
   else
     {
      g_paused     = (GlobalVariableCheck(PauseVarName()) && GlobalVariableGet(PauseVarName()) > 0.5);
      g_showLines  = GlobalVariableCheck(LinesVarName()) ? (GlobalVariableGet(LinesVarName()) > 0.5) : InpShowLinesOnStart;
      g_enableBuy  = !GlobalVariableCheck(BuyVarName())  || GlobalVariableGet(BuyVarName())  > 0.5;
      g_enableSell = !GlobalVariableCheck(SellVarName()) || GlobalVariableGet(SellVarName()) > 0.5;
     }

   double minlot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(InpLot < minlot || InpAtrPeriod < 2 || InpOrderIntervalHours < 1)
      return INIT_PARAMETERS_INCORRECT;

   //--- оптимизация: пропускаем варианты, где дистанция SL >= дистанции TP
   //--- (по множителям xATR; проверка только для включённых стратегий)
   if((bool)MQLInfoInteger(MQL_OPTIMIZATION))
     {
      if(InpEnableSup   && InpSlSup   > 0.0 && InpTpSup   > 0.0 && InpSlSup   >= InpTpSup)
         return INIT_PARAMETERS_INCORRECT;
      if(InpEnableBkSup && InpBkSlSup > 0.0 && InpBkTpSup > 0.0 && InpBkSlSup >= InpBkTpSup)
         return INIT_PARAMETERS_INCORRECT;
      if(InpEnableRes   && InpSlRes   > 0.0 && InpTpRes   > 0.0 && InpSlRes   >= InpTpRes)
         return INIT_PARAMETERS_INCORRECT;
      if(InpEnableBkRes && InpBkSlRes > 0.0 && InpBkTpRes > 0.0 && InpBkSlRes >= InpBkTpRes)
         return INIT_PARAMETERS_INCORRECT;
     }

   PrintFormat("FV_Bounce: таймфрейм расчёта=%s, отскок поддержки %s (метод=%d), "
               "отскок сопротивления %s (метод=%d), пробой поддержки %s, "
               "пробой сопротивления %s, интервал ордеров=%dч",
               EnumToString(InpTF),
               InpEnableSup ? "ВКЛ" : "ВЫКЛ", (int)InpMethodSup,
               InpEnableRes ? "ВКЛ" : "ВЫКЛ", (int)InpMethodRes,
               InpEnableBkSup ? "ВКЛ" : "ВЫКЛ",
               InpEnableBkRes ? "ВКЛ" : "ВЫКЛ",
               InpOrderIntervalHours);
   PrintFormat("FV_Bounce: состояние: кнопка поддержка=%s, кнопка сопрот.=%s, пауза=%s, линии=%s",
               g_enableBuy ? "ВКЛ" : "ВЫКЛ",
               g_enableSell ? "ВКЛ" : "ВЫКЛ",
               g_paused ? "ВКЛ" : "ВЫКЛ",
               g_showLines ? "ВКЛ" : "ВЫКЛ");
   PrintFormat("FV_Bounce: трейлинг: снятие TP %s | повторные входы: %s",
               InpTrailRemoveTP ? "ВКЛ" : "ВЫКЛ",
               InpNoRepeatSameDay ? "разрешены" : "запрещены в течение дня");

   if(InpBtnEnable)
     {
      if(!CreateButtons())
         PrintFormat("FV_Bounce: не удалось создать кнопки");
      if(!CreateBuySellButtons())
         PrintFormat("FV_Bounce: не удалось создать кнопки Поддержка/Сопротивление");
     }

   if(g_showLines)
      DrawLevelLines();          // нарисовать линии при старте

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   DestroyButtons();
   RemoveLevelLines();
   PrintFormat("FV_Bounce deinit, reason=%d", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- постановка ордеров 1 раз в InpOrderIntervalHours часов.
   //--- Ничего не снимаем из-за открытых позиций: отскок и пробой
   //--- одновременно не откроются (точка пробоя = SL отскока).
   datetime now = TimeCurrent();
   if(now - g_last_manage >= InpOrderIntervalHours * 3600)
     {
      g_last_manage = now;
      ManageOrders();
     }

   //--- трейлинг всех открытых позиций
   TrailPosition();
  }

//+------------------------------------------------------------------+
//| Chart event function                                             |
//+------------------------------------------------------------------+
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
      CancelAllPending("ЭКСТРЕННО: снять все ордера");
     }
   else if(sparam == g_btnPlaceName)
     {
      g_btnPlace.State(false);
      ManageOrders();
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
