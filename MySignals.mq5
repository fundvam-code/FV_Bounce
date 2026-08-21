//+------------------------------------------------------------------+
//|                                              MySignals.mq5        |
//|  Кнопки на графике:                                               |
//|   "ТЕСТ СИГНАЛ"        - push-уведомление на телефон (MQID)       |
//|   "СНЯТЬ ВСЕ ОРДЕРА"   - удаление всех ОТЛОЖЕННЫХ ордеров счёта   |
//|                         (позиции НЕ закрываются!)                 |
//|   "СНЯТЬ ПО ВРЕМЕНИ"   - автоснятие отложенных по времени         |
//|                         (клик = вкл/выкл, активна = зелёная)      |
//|  Напоминания: поле in_Reminders в параметрах советника.           |
//|   Каждая строка: ГГГГ.ММ.ДД ЧЧ:ММ:СС;Текст напоминания            |
//|   Когда наступает время - Alert + push на телефон.                |
//|  ATR-трейлинг (опционально): стоп позиций по ATR(M15).           |
//+------------------------------------------------------------------+
#property strict

input string in_Message        = "Тестовый сигнал с графика"; // Текст тестового сигнала
input bool   in_IncludeAccount = true;                        // Добавить данные счёта в тест
input string in_ButtonText     = "ТЕСТ СИГНАЛ";               // Текст кнопки теста
input string in_CancelText     = "СНЯТЬ ВСЕ ОРДЕРА";          // Текст кнопки снятия
input string in_CancelScope    = "all";                       // all - все символы | symbol - только текущий
input string in_Reminders      = "# Каждая строка: ГГГГ.ММ.ДД ЧЧ:ММ:СС;Текст напоминания\n2026.08.14 15:15:00;Снять все ордера перед новостями (15:30 МСК)\n2026.08.14 20:00:00;Проверить итог дня и состояние сетки"; // Напоминания (по строке: дата время;текст)
input int    in_ButtonX        = 20;                          // Отступ кнопок по X (px)
input int    in_ButtonY        = 20;                          // Отступ первой кнопки по Y (px)
input bool   in_TrailEnable    = false;                       // ATR-трейлинг стопа (вкл/выкл)
input int    in_TrailATRPeriod = 14;                          // Период ATR (M15)
input double in_TrailATRMult   = 1.5;                         // Дистанция трейла: множитель ATR
input bool   in_TimeCancelEnable = false;                     // Автоснятие ордеров по времени (вкл/выкл)
input string in_TimeCancel       = "15:15:00";                // Время автоснятия (ЧЧ:ММ:СС, серверное)

#define BTN_TEST      "TestSignalBtn"
#define BTN_CANCEL    "CancelOrdersBtn"
#define BTN_TIMECANCEL "TimeCancelBtn"
#define LBL_NAME      "StatusLbl"

color    g_baseTest      = clrDarkBlue;
color    g_baseCancel    = clrDarkRed;
color    g_baseTimeCancel = clrGray;
datetime g_revertTime    = 0;
datetime g_confirmUntil  = 0;
bool     g_cancelArmed   = false;
datetime g_startTime     = 0;
datetime g_fired[];
bool     g_timerLogged   = false;
bool     g_timeCancelActive = false;
datetime g_timeCancelFiredDate = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_startTime = TimeCurrent();
   CreateButton(BTN_TEST,       in_ButtonText, g_baseTest,       in_ButtonX, in_ButtonY);
   CreateButton(BTN_CANCEL,     in_CancelText, g_baseCancel,     in_ButtonX, in_ButtonY + 42);
   CreateButton(BTN_TIMECANCEL, "СНЯТЬ ПО ВРЕМЕНИ", g_baseTimeCancel, in_ButtonX, in_ButtonY + 84);
   CreateLabel();
   UpdateStatusLabel();
   EventSetTimer(5);
   PrintFormat("MySignals started. Timer set. Start time: %s", TimeToString(g_startTime));
   PrintFormat("MySignals: напоминаний в параметре: %d", CountReminders());
   if(in_TimeCancelEnable)
   {
      g_timeCancelActive = true;
      ObjectSetInteger(0, BTN_TIMECANCEL, OBJPROP_BGCOLOR, clrDarkGreen);
      PrintFormat("MySignals: автоснятие по времени АКТИВНО (%s)", in_TimeCancel);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectDelete(0, BTN_TEST);
   ObjectDelete(0, BTN_CANCEL);
   ObjectDelete(0, BTN_TIMECANCEL);
   ObjectDelete(0, LBL_NAME);
}

//+------------------------------------------------------------------+
//| Expert timer function                                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_timerLogged)
   {
      g_timerLogged = true;
      Print("MySignals: timer tick OK (first tick received)");
   }
   CheckReminders();
   UpdateStatusLabel();
   if(in_TrailEnable)
      TrailPositions();
   CheckTimeCancel();

   //--- истекло время подтверждения снятия ордеров
   if(g_cancelArmed && TimeCurrent() > g_confirmUntil)
   {
      g_cancelArmed = false;
      ObjectSetString(0, BTN_CANCEL, OBJPROP_TEXT, in_CancelText);
      ObjectSetInteger(0, BTN_CANCEL, OBJPROP_BGCOLOR, g_baseCancel);
   }

   //--- вернуть кнопки в исходное состояние после результата
   if(g_revertTime != 0 && TimeCurrent() >= g_revertTime)
   {
      ObjectSetInteger(0, BTN_TEST,   OBJPROP_BGCOLOR, g_baseTest);
      ObjectSetString(0,  BTN_TEST,   OBJPROP_TEXT, in_ButtonText);
      ObjectSetInteger(0, BTN_CANCEL, OBJPROP_BGCOLOR, g_baseCancel);
      ObjectSetString(0,  BTN_CANCEL, OBJPROP_TEXT, in_CancelText);
      g_revertTime = 0;
      g_cancelArmed = false;
      EventKillTimer();
      EventSetTimer(5);
   }
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

   if(sparam == BTN_TEST)
      SendTestSignal();
   else if(sparam == BTN_CANCEL)
      OnCancelClick();
   else if(sparam == BTN_TIMECANCEL)
      OnTimeCancelClick();
}

//+------------------------------------------------------------------+
//| Create button                                                    |
//+------------------------------------------------------------------+
void CreateButton(const string name, const string text, const color bg, const int x, const int y)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 170);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 34);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrSilver);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| Create status label                                              |
//+------------------------------------------------------------------+
void CreateLabel()
{
   if(ObjectFind(0, LBL_NAME) >= 0)
      ObjectDelete(0, LBL_NAME);

   ObjectCreate(0, LBL_NAME, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, LBL_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, LBL_NAME, OBJPROP_XDISTANCE, in_ButtonX);
   ObjectSetInteger(0, LBL_NAME, OBJPROP_YDISTANCE, in_ButtonY + 122);
   ObjectSetInteger(0, LBL_NAME, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, LBL_NAME, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, LBL_NAME, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, LBL_NAME, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Update status label (push, orders, next reminder, time-cancel)   |
//+------------------------------------------------------------------+
void UpdateStatusLabel()
{
   bool on = TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED);
   int pending = CountPending();

   string nextText;
   datetime next = GetNextReminder(nextText);
   string txt = StringFormat("Push: %s | Ордеров: %d | Trail: %s | Авто: %s %s",
                             (on ? "ВКЛ" : "ВЫКЛ"), pending,
                             (in_TrailEnable ? "ATR" : "ВЫКЛ"),
                             (g_timeCancelActive ? "ВКЛ" : "ВЫКЛ"),
                             in_TimeCancel);
   if(next != 0)
      txt += StringFormat(" | След.: %s %s",
                          TimeToString(next, TIME_DATE | TIME_MINUTES),
                          StringSubstr(nextText, 0, 18));

   ObjectSetInteger(0, LBL_NAME, OBJPROP_COLOR, (on ? clrLime : clrOrangeRed));
   ObjectSetString(0, LBL_NAME, OBJPROP_TEXT, txt);
}

//+------------------------------------------------------------------+
//| Toggle time-cancel button                                        |
//+------------------------------------------------------------------+
void OnTimeCancelClick()
{
   g_timeCancelActive = !g_timeCancelActive;
   if(g_timeCancelActive)
   {
      g_timeCancelFiredDate = 0;
      ObjectSetInteger(0, BTN_TIMECANCEL, OBJPROP_BGCOLOR, clrDarkGreen);
      PrintFormat("Автоснятие по времени АКТИВНО (%s). В это время все отложенные ордера будут сняты.", in_TimeCancel);
      Alert("Автоснятие по времени АКТИВНО (" + in_TimeCancel + "). В это время все отложенные ордера будут сняты.");
   }
   else
   {
      ObjectSetInteger(0, BTN_TIMECANCEL, OBJPROP_BGCOLOR, clrGray);
      Print("Автоснятие по времени ВЫКЛЮЧЕНО.");
   }
   UpdateStatusLabel();
}

//+------------------------------------------------------------------+
//| Check and execute time-based cancel                              |
//+------------------------------------------------------------------+
void CheckTimeCancel()
{
   if(!g_timeCancelActive)
      return;

   datetime now = TimeCurrent();
   int target = TimeCancelSeconds(in_TimeCancel);
   if(target < 0)
   {
      PrintFormat("Ошибка формата времени автоснятия: '%s' (нужно ЧЧ:ММ:СС)", in_TimeCancel);
      g_timeCancelActive = false;
      ObjectSetInteger(0, BTN_TIMECANCEL, OBJPROP_BGCOLOR, clrGray);
      return;
   }

   int secs = (int)(now % 86400);
   if(secs < target)
      return;                                        // ещё рано

   datetime day = now - (now % 86400);
   if(g_timeCancelFiredDate == day)
      return;                                        // уже срабатывало сегодня

   int cancelled = CancelAllPending();
   string msg = StringFormat("АВТОСНЯТИЕ %s: снято отложенных ордеров: %d",
                             in_TimeCancel, cancelled);
   Print(msg);
   Alert(msg);
   if(TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(msg);

   g_timeCancelFiredDate = day;
   g_timeCancelActive = false;
   ObjectSetInteger(0, BTN_TIMECANCEL, OBJPROP_BGCOLOR, clrGray);
   UpdateStatusLabel();
}

//+------------------------------------------------------------------+
//| Parse "HH:MM:SS" to seconds of day; -1 on error                  |
//+------------------------------------------------------------------+
int TimeCancelSeconds(const string s)
{
   string c = s;
   StringTrimLeft(c);
   StringTrimRight(c);
   int p1 = StringFind(c, ":");
   if(p1 <= 0)
      return(-1);
   int p2 = StringFind(c, ":", p1 + 1);
   if(p2 < 0)
      return(-1);
   int hh = (int)StringToInteger(StringSubstr(c, 0, p1));
   int mm = (int)StringToInteger(StringSubstr(c, p1 + 1, p2 - p1 - 1));
   int ss = (int)StringToInteger(StringSubstr(c, p2 + 1));
   if(hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 59)
      return(-1);
   return(hh * 3600 + mm * 60 + ss);
}

//+------------------------------------------------------------------+
//| Count pending orders on the account                              |
//+------------------------------------------------------------------+
int CountPending()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_STOP_LIMIT || type == ORDER_TYPE_SELL_STOP_LIMIT)
         count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Send test push notification                                      |
//+------------------------------------------------------------------+
void SendTestSignal()
{
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
   {
      Alert("Push-уведомления ВЫКЛЮЧЕНЫ.\n"
            "Сервис -> Настройки -> Уведомления:\n"
            "1) Разрешить push-уведомления\n"
            "2) MetaQuotes ID: 4C91730F");
      return;
   }

   string msg = in_Message;
   if(in_IncludeAccount)
   {
      msg += StringFormat("\nВремя: %s\nСчёт: %I64d | Баланс: %.2f %s | Средства: %.2f %s",
                          TimeToString(TimeCurrent()),
                          AccountInfoInteger(ACCOUNT_LOGIN),
                          AccountInfoDouble(ACCOUNT_BALANCE),
                          AccountInfoString(ACCOUNT_CURRENCY),
                          AccountInfoDouble(ACCOUNT_EQUITY),
                          AccountInfoString(ACCOUNT_CURRENCY));
   }

   bool sent = SendNotification(msg);
   if(sent)
   {
      ObjectSetInteger(0, BTN_TEST, OBJPROP_BGCOLOR, clrDarkGreen);
      ObjectSetString(0, BTN_TEST, OBJPROP_TEXT, "ОТПРАВЛЕНО OK");
      g_revertTime = TimeCurrent() + 3;
      EventSetTimer(1);
      Print("Тестовый сигнал отправлен на телефон.");
   }
   else
   {
      int err = GetLastError();
      ObjectSetInteger(0, BTN_TEST, OBJPROP_BGCOLOR, clrDarkRed);
      ObjectSetString(0, BTN_TEST, OBJPROP_TEXT, "ОШИБКА");
      g_revertTime = TimeCurrent() + 3;
      EventSetTimer(1);
      PrintFormat("Ошибка отправки push-уведомления, код ошибки: %d", err);
      Alert("Не удалось отправить push-уведомление (код " + IntegerToString(err) + ").");
   }
}

//+------------------------------------------------------------------+
//| Cancel orders button logic (double-click confirm)                |
//+------------------------------------------------------------------+
void OnCancelClick()
{
   //--- первый клик: запросить подтверждение
   if(!g_cancelArmed)
   {
      g_cancelArmed = true;
      g_confirmUntil = TimeCurrent() + 5;
      ObjectSetString(0, BTN_CANCEL, OBJPROP_TEXT, "ПОДТВЕРДИТЬ?");
      ObjectSetInteger(0, BTN_CANCEL, OBJPROP_BGCOLOR, clrOrange);
      EventSetTimer(1);
      Print("Для снятия ордеров нажмите кнопку ещё раз в течение 5 сек.");
      return;
   }

   //--- время подтверждения истекло - начинаем заново
   if(TimeCurrent() > g_confirmUntil)
   {
      g_cancelArmed = false;
      OnCancelClick();
      return;
   }

   //--- второй клик: выполняем
   g_cancelArmed = false;
   int cancelled = CancelAllPending();
   string result;
   if(cancelled >= 0)
   {
      result = StringFormat("Снято отложенных ордеров: %d", cancelled);
      ObjectSetString(0, BTN_CANCEL, OBJPROP_TEXT, "СНЯТО: " + IntegerToString(cancelled));
      ObjectSetInteger(0, BTN_CANCEL, OBJPROP_BGCOLOR, clrDarkGreen);
      Print(result);
      Alert(result);
      if(TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
         SendNotification(result);
   }
   else
   {
      result = StringFormat("Ошибка при снятии ордеров (код %d). Проверьте 'Алгоритмическую торговлю'.", GetLastError());
      ObjectSetString(0, BTN_CANCEL, OBJPROP_TEXT, "ОШИБКА");
      ObjectSetInteger(0, BTN_CANCEL, OBJPROP_BGCOLOR, clrGray);
      Print(result);
      Alert(result);
   }
   g_revertTime = TimeCurrent() + 3;
   EventSetTimer(1);
}

//+------------------------------------------------------------------+
//| Delete ALL PENDING orders (scope by input)                       |
//| ВНИМАНИЕ: удаляются ТОЛЬКО отложенные ордера.                    |
//| Открытые позиции (PositionsTotal) НЕ затрагиваются.              |
//+------------------------------------------------------------------+
int CancelAllPending()
{
   int count = 0;
   int failed = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      bool isPending = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP ||
                        type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP ||
                        type == ORDER_TYPE_BUY_STOP_LIMIT || type == ORDER_TYPE_SELL_STOP_LIMIT);
      if(!isPending)
         continue;
      if(in_CancelScope == "symbol" && OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      //--- удаление ордера через "сырое" API (без стандартной библиотеки)
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      req.symbol = OrderGetString(ORDER_SYMBOL);

      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
         count++;
      else
      {
         failed++;
         PrintFormat("Не удалось снять ордер %I64u, retcode=%u", ticket, res.retcode);
      }
   }
   if(failed > 0)
      PrintFormat("Итого не удалось снять: %d ордеров.", failed);
   return(count);
}

//+------------------------------------------------------------------+
//| Parse reminders from in_Reminders parameter                      |
//+------------------------------------------------------------------+
int ParseReminders(datetime &tm[], string &txt[])
{
   string lines[];
   int n = StringSplit(in_Reminders, '\n', lines);
   if(n <= 0)
      return(0);
   int cnt = 0;
   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      StringReplace(line, "\r", "");
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "" || StringGetCharacter(line, 0) == '#')
         continue;
      int pos = StringFind(line, ";");
      if(pos <= 0)
         continue;
      string dt = StringSubstr(line, 0, pos);
      string t  = StringSubstr(line, pos + 1);
      datetime tmv = ParseDT(dt);
      if(tmv == 0)
         continue;
      ArrayResize(tm, cnt + 1);
      ArrayResize(txt, cnt + 1);
      tm[cnt] = tmv;
      txt[cnt] = t;
      cnt++;
   }
   return(cnt);
}

//+------------------------------------------------------------------+
//| Count valid reminders in parameter                               |
//+------------------------------------------------------------------+
int CountReminders()
{
   datetime tm[];
   string txt[];
   return(ParseReminders(tm, txt));
}

//+------------------------------------------------------------------+
//| Reminders: fire due lines (only those that became due after start)|
//+------------------------------------------------------------------+
void CheckReminders()
{
   datetime tm[];
   string txt[];
   int n = ParseReminders(tm, txt);
   if(n <= 0)
      return;

   datetime now = TimeCurrent();
   for(int i = 0; i < n; i++)
   {
      if(tm[i] == 0)
         continue;
      if(tm[i] > now)
         continue;              // ещё не наступило
      if(tm[i] <= g_startTime)
         continue;              // было просрочено уже при старте - пропускаем
      if(IsFired(tm[i]))
         continue;              // уже сработало в этой сессии
      FireReminder(txt[i]);
      MarkFired(tm[i]);
   }
}

//+------------------------------------------------------------------+
//| Fire reminder: Print + Alert + push                              |
//+------------------------------------------------------------------+
void FireReminder(const string txt)
{
   string msg = "НАПОМИНАНИЕ: " + txt;
   Print(msg);
   Alert(msg);
   if(TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(msg);
}

//+------------------------------------------------------------------+
//| Find next (future) reminder                                      |
//+------------------------------------------------------------------+
datetime GetNextReminder(string &outText)
{
   outText = "";
   datetime tm[];
   string txt[];
   int n = ParseReminders(tm, txt);
   if(n <= 0)
      return(0);

   datetime now = TimeCurrent();
   datetime best = 0;
   string bestText = "";
   for(int i = 0; i < n; i++)
   {
      if(tm[i] == 0 || tm[i] <= now)
         continue;
      if(best == 0 || tm[i] < best)
      {
         best = tm[i];
         bestText = txt[i];
      }
   }
   outText = bestText;
   return(best);
}

//+------------------------------------------------------------------+
//| Parse datetime string "YYYY.MM.DD HH:MM:SS"                      |
//+------------------------------------------------------------------+
datetime ParseDT(const string s)
{
   string c = s;
   StringTrimLeft(c);
   StringTrimRight(c);
   if(StringLen(c) < 19)
      return(0);
   int y  = (int)StringToInteger(StringSubstr(c, 0, 4));
   int m  = (int)StringToInteger(StringSubstr(c, 5, 2));
   int d  = (int)StringToInteger(StringSubstr(c, 8, 2));
   int hh = (int)StringToInteger(StringSubstr(c, 11, 2));
   int mm = (int)StringToInteger(StringSubstr(c, 14, 2));
   int ss = (int)StringToInteger(StringSubstr(c, 17, 2));
   if(y < 2000 || m < 1 || m > 12 || d < 1 || d > 31 || hh > 23 || mm > 59 || ss > 59)
      return(0);
   return(StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d:%02d", y, m, d, hh, mm, ss)));
}

//+------------------------------------------------------------------+
//| Fired reminders tracking (per session)                           |
//+------------------------------------------------------------------+
bool IsFired(const datetime tm)
{
   for(int i = 0; i < ArraySize(g_fired); i++)
      if(g_fired[i] == tm)
         return(true);
   return(false);
}

void MarkFired(const datetime tm)
{
   int n = ArraySize(g_fired);
   ArrayResize(g_fired, n + 1);
   g_fired[n] = tm;
}

//+------------------------------------------------------------------+
//| ATR handle cache                                                 |
//+------------------------------------------------------------------+
string g_atrSym[];
int    g_atrHnd[];

int ATRHandle(const string symbol)
{
   for(int i = 0; i < ArraySize(g_atrSym); i++)
      if(g_atrSym[i] == symbol)
         return(g_atrHnd[i]);
   int h = iATR(symbol, PERIOD_M15, in_TrailATRPeriod);
   int n = ArraySize(g_atrSym);
   ArrayResize(g_atrSym, n + 1);
   ArrayResize(g_atrHnd, n + 1);
   g_atrSym[n] = symbol;
   g_atrHnd[n] = h;
   return(h);
}

double ATRValue(const string symbol)
{
   int h = ATRHandle(symbol);
   if(h == INVALID_HANDLE)
      return(0.0);
   double buf[1];
   if(CopyBuffer(h, 0, 0, 1, buf) < 1)
      return(0.0);
   return(buf[0]);
}

//+------------------------------------------------------------------+
//| ATR-based trailing stop for all open positions                   |
//+------------------------------------------------------------------+
void TrailPositions()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   type   = PositionGetInteger(POSITION_TYPE);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);

      double atr = ATRValue(symbol);
      if(atr <= 0.0)
         continue;

      double trailDist = atr * in_TrailATRMult;
      double newSL = 0.0;
      bool   doModify = false;

      if(type == POSITION_TYPE_BUY)
      {
         double price = SymbolInfoDouble(symbol, SYMBOL_BID);
         if(price - entry >= trailDist)
         {
            double cand = price - trailDist;
            if(cand > sl)
            {
               newSL = cand;
               doModify = true;
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         if(entry - price >= trailDist)
         {
            double cand = price + trailDist;
            if(sl == 0.0 || cand < sl)
            {
               newSL = cand;
               doModify = true;
            }
         }
      }

      if(doModify && newSL > 0.0)
      {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = symbol;
         req.position = ticket;
         req.sl       = NormalizeDouble(newSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
         req.tp       = tp;
         if(OrderSend(req, res))
            PrintFormat("ATR-трейлинг %s %s: SL %.5f -> %.5f (retcode %u)",
                        symbol, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                        sl, req.sl, res.retcode);
      }
   }
}
//+------------------------------------------------------------------+
