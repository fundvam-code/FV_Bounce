//+------------------------------------------------------------------+
//|                                            FV_Bounce_Risk.mq5    |
//|     Панель риска по отложенным ордерам + кнопка "Обновить"       |
//+------------------------------------------------------------------+
#property copyright "FV_Bounce"
#property version   "1.04"
#property strict

input double InpAlertPercent = 5.0;    // Алерт при суммарном риске выше, % от баланса (0 = выкл)
input bool   InpSaveReport    = true;  // Сохранять отчёт в Files\FV_Bounce_Risk_report.txt
input color  InpPanelBg       = C'48,48,48';    // Цвет фона панели
input color  InpPanelBorder   = C'130,130,130'; // Цвет рамки панели

#define OBJ_PREFIX  "FVR_"
#define OBJ_PANEL   "FVR_PANEL"
#define OBJ_BTN     "FVR_BTN_REFRESH"
#define REPORT_FILE "FV_Bounce_Risk_report.txt"

int g_file = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Структура строки отчёта                                          |
//+------------------------------------------------------------------+
struct SReportLine
{
   string text;
   color  clr;
};

SReportLine g_lines[];
int     g_count        = 0;
double  g_totalVol     = 0.0;
double  g_totalRisk    = 0.0;
double  g_totalRiskPct = 0.0;
double  g_totalMargin  = 0.0;
double  g_balance      = 0.0;
int     g_noSlCount    = 0;
string  g_accountCur   = "USD";
string  g_noSlList     = "";

//+------------------------------------------------------------------+
//| Логирование: в файл отчёта и в журнал (вкладка Эксперты)         |
//+------------------------------------------------------------------+
void Log(const string s)
{
   if(g_file != INVALID_HANDLE)
      FileWrite(g_file, s);
   Print(s);
}

//+------------------------------------------------------------------+
//| Диагностика: только в файл отчёта (не показывается пользователю) |
//+------------------------------------------------------------------+
void Diag(const string s)
{
   if(g_file != INVALID_HANDLE)
      FileWrite(g_file, s);
}

//+------------------------------------------------------------------+
//| Является ли тип ордера отложенным                                |
//+------------------------------------------------------------------+
bool IsPendingType(const ENUM_ORDER_TYPE type)
{
   switch(type)
   {
      case ORDER_TYPE_BUY_LIMIT:
      case ORDER_TYPE_SELL_LIMIT:
      case ORDER_TYPE_BUY_STOP:
      case ORDER_TYPE_SELL_STOP:
      case ORDER_TYPE_BUY_STOP_LIMIT:
      case ORDER_TYPE_SELL_STOP_LIMIT:
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Рыночное направление для расчёта                                 |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE ToAction(const ENUM_ORDER_TYPE type)
{
   switch(type)
   {
      case ORDER_TYPE_BUY_LIMIT:
      case ORDER_TYPE_BUY_STOP:
      case ORDER_TYPE_BUY_STOP_LIMIT:
         return ORDER_TYPE_BUY;
      default:
         return ORDER_TYPE_SELL;
   }
}

//+------------------------------------------------------------------+
//| Имя типа ордера                                                   |
//+------------------------------------------------------------------+
string OrderTypeName(const ENUM_ORDER_TYPE type)
{
   switch(type)
   {
      case ORDER_TYPE_BUY_LIMIT:       return "BUY_LIMIT";
      case ORDER_TYPE_SELL_LIMIT:      return "SELL_LIMIT";
      case ORDER_TYPE_BUY_STOP:        return "BUY_STOP";
      case ORDER_TYPE_SELL_STOP:       return "SELL_STOP";
      case ORDER_TYPE_BUY_STOP_LIMIT:  return "BUY_STOP_LIMIT";
      case ORDER_TYPE_SELL_STOP_LIMIT: return "SELL_STOP_LIMIT";
   }
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
//| Получение тикета ордера по индексу (с повторами)                 |
//+------------------------------------------------------------------+
ulong GetOrderTicketWithRetry(const int index)
{
   for(int attempt = 0; attempt < 5; attempt++)
   {
      const ulong ticket = OrderGetTicket(index);
      if(ticket != 0)
         return ticket;
      Sleep(100);
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Выбор ордера: по тикету, при неудаче - по индексу (с повторами)  |
//+------------------------------------------------------------------+
bool SelectOrderReliable(const int index, ulong &ticket)
{
   ticket = GetOrderTicketWithRetry(index);
   if(ticket != 0 && OrderSelect(ticket))
      return true;

   //--- Запасной вариант: выбор по индексу
   for(int attempt = 0; attempt < 5; attempt++)
   {
      if(OrderSelect(index))
      {
         ticket = (ulong)OrderGetInteger(ORDER_TICKET);
         return true;
      }
      Sleep(100);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Ручной расчёт риска (если OrderCalcProfit недоступен)            |
//+------------------------------------------------------------------+
double CalcRiskManual(const string symbol, const double volume,
                      const double price, const double sl)
{
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0)
      return 0.0;
   return (MathAbs(price - sl) / tickSize) * tickValue * volume;
}

//+------------------------------------------------------------------+
//| Очистка объектов панели                                          |
//+------------------------------------------------------------------+
void CleanupObjects()
{
   for(int i = 0; i < 100; i++)
      ObjectDelete(0, OBJ_PREFIX + IntegerToString(i));
   ObjectDelete(0, OBJ_PANEL);
   ObjectDelete(0, OBJ_BTN);
}

//+------------------------------------------------------------------+
//| Отрисовка панели: серый фон + текст + кнопка "Обновить"          |
//+------------------------------------------------------------------+
void DrawPanel()
{
   CleanupObjects();

   const int n = ArraySize(g_lines);

   //--- Ширина панели по самой длинной строке
   int maxLen = 30;
   for(int i = 0; i < n; i++)
   {
      const int len = StringLen(g_lines[i].text);
      if(len > maxLen)
         maxLen = len;
   }

   const int panelX = 8;
   const int panelY = 20;
   const int lineH  = 16;
   const int pad    = 6;
   const int btnH   = 22;
   const int textH  = n * lineH;
   const int panelW = (int)(maxLen * 6.2) + 20;
   const int panelH = pad + textH + pad + btnH + pad;

   //--- Серый фон
   ObjectCreate(0, OBJ_PANEL, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_XSIZE, panelW);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_YSIZE, panelH);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_BGCOLOR, InpPanelBg);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_COLOR, InpPanelBorder);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, OBJ_PANEL, OBJPROP_HIDDEN, true);

   //--- Строки текста
   for(int i = 0; i < n; i++)
   {
      const string name = OBJ_PREFIX + IntegerToString(i);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, panelX + pad);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, panelY + pad + i * lineH);
      ObjectSetInteger(0, name, OBJPROP_COLOR, g_lines[i].clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
      ObjectSetString (0, name, OBJPROP_TEXT, g_lines[i].text);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }

   //--- Кнопка "Обновить"
   const int btnY = panelY + pad + textH + pad;
   ObjectCreate(0, OBJ_BTN, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_YDISTANCE, btnY);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_XSIZE, 100);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_YSIZE, btnH);
   ObjectSetString (0, OBJ_BTN, OBJPROP_TEXT, "Обновить");
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_BGCOLOR, C'70,70,70');
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_BORDER_COLOR, C'140,140,140');
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, OBJ_BTN, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Расчёт риска и обновление панели                                 |
//+------------------------------------------------------------------+
void Calculate()
{
   //--- Открываем файл отчёта (для диагностики)
   if(InpSaveReport)
   {
      g_file = FileOpen(REPORT_FILE, FILE_TXT | FILE_WRITE);
      if(g_file == INVALID_HANDLE)
         Print("Не удалось открыть файл отчёта, ошибка ", GetLastError());
   }

   g_balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   g_accountCur = AccountInfoString(ACCOUNT_CURRENCY);

   g_count       = 0;
   g_totalVol    = 0.0;
   g_totalRisk   = 0.0;
   g_totalMargin = 0.0;
   g_noSlCount   = 0;
   g_noSlList    = "";

   ArrayResize(g_lines, 0);
   int idx = 0;

   //--- Заголовок
   ArrayResize(g_lines, idx + 1);
   g_lines[idx].text = "FV_Bounce Risk: отложенные ордера на счёте";
   g_lines[idx].clr  = clrGold;
   idx++;
   Log(g_lines[0].text);

   ArrayResize(g_lines, idx + 1);
   g_lines[idx].text = StringFormat("Баланс: %.2f %s", g_balance, g_accountCur);
   g_lines[idx].clr  = clrAqua;
   idx++;
   Log(g_lines[1].text);

   //--- Диагностика: сколько ордеров возвращает терминал
   const int total = OrdersTotal();
   Diag(StringFormat("ДИАГНОСТИКА: OrdersTotal() = %d", total));

   //--- Перебор всех ордеров
   for(int i = 0; i < total; i++)
   {
      ulong ticket = 0;
      if(!SelectOrderReliable(i, ticket))
      {
         Diag(StringFormat("  i=%d: не удалось выбрать ордер, ошибка %d", i, GetLastError()));
         continue;
      }

      const ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const long            state = OrderGetInteger(ORDER_STATE);

      //--- Диагностика по каждому ордеру (только в файл)
      Diag(StringFormat("  i=%d: ticket=%I64d type=%d(%s) state=%d",
                        i, ticket, (int)otype, OrderTypeName(otype), (int)state));

      if(!IsPendingType(otype))
         continue;
      if((ENUM_ORDER_STATE)state != ORDER_STATE_PLACED)
         continue;

      const string symbol = OrderGetString(ORDER_SYMBOL);
      const double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      const double price  = OrderGetDouble(ORDER_PRICE_OPEN);
      const double sl     = OrderGetDouble(ORDER_SL);
      const ENUM_ORDER_TYPE action = ToAction(otype);

      //--- Риск = убыток при срабатывании SL
      double risk = 0.0;
      if(sl > 0.0)
      {
         double profit = 0.0;
         if(!OrderCalcProfit(action, symbol, volume, price, sl, profit))
            risk = CalcRiskManual(symbol, volume, price, sl);
         else
            risk = -profit;
         if(risk < 0.0)
            risk = 0.0;
         g_totalRisk += risk;
      }
      else
      {
         g_noSlCount++;
         g_noSlList += (g_noSlList == "" ? "" : ", ") +
                       "#" + IntegerToString(ticket) + " " + OrderTypeName(otype) + " " + symbol;
      }

      //--- Маржа
      double margin = 0.0;
      if(!OrderCalcMargin(action, symbol, volume, price, margin))
         margin = 0.0;
      g_totalMargin += margin;

      g_totalVol += volume;
      g_count++;
   }

   //--- Разделитель
   ArrayResize(g_lines, idx + 1);
   g_lines[idx].text = "------------------------------------------------";
   g_lines[idx].clr  = clrDarkGray;
   idx++;
   Log(g_lines[idx - 1].text);

   //--- Итоги
   g_totalRiskPct = (g_balance > 0.0) ? g_totalRisk / g_balance * 100.0 : 0.0;

   ArrayResize(g_lines, idx + 1);
   g_lines[idx].text = StringFormat("ИТОГО: ордеров %d, объём %.2f", g_count, g_totalVol);
   g_lines[idx].clr  = clrWhite;
   idx++;
   Log(g_lines[idx - 1].text);

   ArrayResize(g_lines, idx + 1);
   g_lines[idx].text = StringFormat("ИТОГО риск: %.2f %s (%.2f%% от баланса)", g_totalRisk, g_accountCur, g_totalRiskPct);
   g_lines[idx].clr  = (g_totalRiskPct >= InpAlertPercent && InpAlertPercent > 0.0) ? clrRed : clrLime;
   idx++;
   Log(g_lines[idx - 1].text);

   ArrayResize(g_lines, idx + 1);
   g_lines[idx].text = StringFormat("ИТОГО маржа: %.2f %s", g_totalMargin, g_accountCur);
   g_lines[idx].clr  = clrWhite;
   idx++;
   Log(g_lines[idx - 1].text);

   //--- Предупреждение об ордерах без SL (только если такие есть)
   if(g_noSlCount > 0)
   {
      ArrayResize(g_lines, idx + 1);
      g_lines[idx].text = StringFormat("ВНИМАНИЕ: %d ордер(ов) БЕЗ SL: %s", g_noSlCount, g_noSlList);
      g_lines[idx].clr  = clrRed;
      idx++;
      Log(g_lines[idx - 1].text);
   }

   //--- Отрисовка панели
   DrawPanel();

   //--- Алерт: только итоги и предупреждения
   string alertText = StringFormat("FV_Bounce Risk: ордеров %d, риск %.2f %s (%.2f%% от баланса %.2f %s), маржа %.2f %s",
                                   g_count, g_totalRisk, g_accountCur, g_totalRiskPct,
                                   g_balance, g_accountCur, g_totalMargin, g_accountCur);
   if(InpAlertPercent > 0.0 && g_totalRiskPct > InpAlertPercent)
      alertText += StringFormat("\nВНИМАНИЕ: риск превышает порог %.2f%%!", InpAlertPercent);
   if(g_noSlCount > 0)
      alertText += StringFormat("\nВНИМАНИЕ: %d ордер(ов) без SL!", g_noSlCount);
   Alert(alertText);

   //--- Закрываем файл отчёта
   if(g_file != INVALID_HANDLE)
   {
      FileClose(g_file);
      g_file = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Calculate();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanupObjects();
}

//+------------------------------------------------------------------+
//| Chart event function                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == OBJ_BTN)
      Calculate();
}
//+------------------------------------------------------------------+
