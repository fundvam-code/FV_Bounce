//+------------------------------------------------------------------+
//|                                           level_reversal_ea.mq5 |
//|  Отскок от уровней с подтверждением разворотным паттерном (Pin Bar, Engulfing, Doji) |
//|  Старший ТФ (H4/D1) - поиск уровней и тренда                    |
//|  Младший ТФ (M5/M15) - вход и паттерны                          |
//|  SL по ATR, TP = SL * RR, только 1 позиция одновременно         |
//|  Депозит $700, лот до 0.1                                       |
//+------------------------------------------------------------------+
#property copyright "FV_Bounce Level Reversal"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// Таймфреймы
enum ENUM_TF_SELECT {
   TF_M5  = 5,    // 5 минут
   TF_M15 = 15,   // 15 минут
};

// Методы уровней (для совместимости, хотя будем использовать swing high/low)
enum ENUM_METHOD {
   METHOD_SWING = 0   // Swing high/low
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group             "=== УРОВНИ И ТРЕНД ==="
input ENUM_METHOD      InpLevelMethod      = METHOD_SWING;        // Метод определения уровней
input int              InpFractalDepth     = 2;                   // Глубина фрактала для swing high/low
input double           InpLevelBufferATR   = 1.0;                 // Буфер кластеризации уровней, xATR H4
input int              InpMinTouches       = 3;                   // Минимум касаний для "сильного" уровня
input int              InpLevelLookbackBar = 250;                 // Глубина поиска уровней (баров H4)
input double           InpBreakBufferATR   = 0.5;                 // Буфер пробоя уровня

input group             "=== ТРЕНД-ФИЛЬТР (EMA + ADX) ==="
input int              InpEmaFast          = 50;                  // Период EMA (быстрая)
input int              InpEmaSlow          = 200;                 // Период EMA (медленная)
input int              InpAdxPeriod        = 14;                  // Период ADX
input int              InpAdxFlatThreshold = 20;                  // Порог ADX для флэта (< порога = флэт)

input group             "=== ВХОД И ПАТТЕРНЫ ==="
input ENUM_TF_SELECT   InpEntryTF          = TF_M15;              // Таймфрейм входа (вход/паттерны)
input double           InpEntryZoneATR     = 0.5;                 // Зона входа от уровня, xATR младший ТФ
input bool             InpUsePinBar        = true;                // Использовать пин-бар
input bool             InpUseEngulfing     = true;                // Использовать поглощение
input bool             InpUseDoji          = true;                // Использовать доджи

input group             "=== РИСК-МЕНЕДЖМЕНТ ==="
input double           InpLot              = 0.1;                 // Объём сделки (лот)
input int              InpAtrPeriod        = 14;                  // Период ATR для SL (младший ТФ)
input double           InpSlAtrMult        = 2.0;                 // SL = xATR
input double           InpRR               = 2.0;                 // Risk/Reward (TP = SL * RR)
input bool             InpUseBreakEven     = false;               // Использовать безубыток (0 = выкл)
input double           InpBEAtrMult        = 1.0;                 // Безубыток при движении на xATR

input group             "=== ПРОЧЕЕ ==="
input long             InpMagic            = 260814;              // Magic число
input bool             InpVisualizeLevels  = true;                // Отрисовывать уровни на графике
input bool             InpKeepBrokenLevels = false;               // Оставлять сломанные уровни на графике

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                            |
//+------------------------------------------------------------------+
CTrade          g_trade;
int             g_atr_handle_h4 = INVALID_HANDLE;
int             g_atr_handle_entry = INVALID_HANDLE;
int             g_ema_fast_handle = INVALID_HANDLE;
int             g_ema_slow_handle = INVALID_HANDLE;
int             g_adx_handle = INVALID_HANDLE;

datetime        g_last_level_recalc = 0;
struct SLevel {
   double price;
   bool   is_support;
   int    touches;
   bool   is_broken;
   string label;
};

SLevel          g_levels[50];
int             g_level_count = 0;

//+------------------------------------------------------------------+
//| СЛУЖЕБНЫЕ ФУНКЦИИ                                                |
//+------------------------------------------------------------------+
double NormalizePrice(double price) {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeLot(double lot) {
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathMax(lot, min_lot);
   lot = MathMin(lot, max_lot);
   lot = MathMin(lot, 0.1);  // Кэп на 0.1 лот
   
   if(step > 0.0)
      lot = MathFloor(lot / step) * step;
   
   return NormalizeDouble(lot, 2);
}

ENUM_TIMEFRAMES GetEntryTF() {
   if(InpEntryTF == TF_M5)  return PERIOD_M5;
   if(InpEntryTF == TF_M15) return PERIOD_M15;
   return PERIOD_M15;
}

double GetAtr(ENUM_TIMEFRAMES tf, int period, int shift) {
   int handle = (tf == PERIOD_H4) ? g_atr_handle_h4 : g_atr_handle_entry;
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) == 1)
      return buf[0];
   return 0.0;
}

//+------------------------------------------------------------------+
//| ОПРЕДЕЛЕНИЕ УРОВНЕЙ (Swing High/Low)                             |
//+------------------------------------------------------------------+
void RecalculateLevels() {
   if(TimeCurrent() - g_last_level_recalc < 3600)  // Пересчет каждый час
      return;
   
   g_last_level_recalc = TimeCurrent();
   g_level_count = 0;
   
   // Получаем историю H4
   int lookback = InpLevelLookbackBar;
   MqlRates rates_h4[500];
   int bars = CopyRates(_Symbol, PERIOD_H4, 0, lookback, rates_h4);
   
   if(bars < InpFractalDepth * 2 + 5)
      return;
   
   double atr_h4 = GetAtr(PERIOD_H4, InpAtrPeriod, 0);
   if(atr_h4 <= 0)
      return;
   
   double buffer_atr = InpLevelBufferATR * atr_h4;
   
   // Поиск swing high (локальные максимумы)
   for(int i = InpFractalDepth; i < bars - InpFractalDepth; i++) {
      bool is_high = true;
      for(int j = 1; j <= InpFractalDepth; j++) {
         if(rates_h4[i].high < rates_h4[i-j].high || rates_h4[i].high < rates_h4[i+j].high) {
            is_high = false;
            break;
         }
      }
      
      if(is_high) {
         // Проверяем, не близко ли уже есть такой уровень
         bool found = false;
         for(int k = 0; k < g_level_count; k++) {
            if(g_levels[k].is_support == false &&
               MathAbs(g_levels[k].price - rates_h4[i].high) <= buffer_atr) {
               g_levels[k].touches++;
               found = true;
               break;
            }
         }
         
         if(!found && g_level_count < 50) {
            g_levels[g_level_count].price = NormalizePrice(rates_h4[i].high);
            g_levels[g_level_count].is_support = false;
            g_levels[g_level_count].touches = 1;
            g_levels[g_level_count].is_broken = false;
            g_level_count++;
         }
      }
   }
   
   // Поиск swing low (локальные минимумы)
   for(int i = InpFractalDepth; i < bars - InpFractalDepth; i++) {
      bool is_low = true;
      for(int j = 1; j <= InpFractalDepth; j++) {
         if(rates_h4[i].low > rates_h4[i-j].low || rates_h4[i].low > rates_h4[i+j].low) {
            is_low = false;
            break;
         }
      }
      
      if(is_low) {
         bool found = false;
         for(int k = 0; k < g_level_count; k++) {
            if(g_levels[k].is_support == true &&
               MathAbs(g_levels[k].price - rates_h4[i].low) <= buffer_atr) {
               g_levels[k].touches++;
               found = true;
               break;
            }
         }
         
         if(!found && g_level_count < 50) {
            g_levels[g_level_count].price = NormalizePrice(rates_h4[i].low);
            g_levels[g_level_count].is_support = true;
            g_levels[g_level_count].touches = 1;
            g_levels[g_level_count].is_broken = false;
            g_level_count++;
         }
      }
   }
}

bool GetNearestSupportLevel(double& out_price) {
   double current_price = iClose(_Symbol, PERIOD_CURRENT, 0);
   double best_support = -DBL_MAX;
   bool found = false;
   
   for(int i = 0; i < g_level_count; i++) {
      if(g_levels[i].is_support && !g_levels[i].is_broken &&
         g_levels[i].touches >= InpMinTouches &&
         g_levels[i].price <= current_price &&
         g_levels[i].price > best_support) {
         best_support = g_levels[i].price;
         found = true;
      }
   }
   
   if(found) {
      out_price = best_support;
      return true;
   }
   return false;
}

bool GetNearestResistanceLevel(double& out_price) {
   double current_price = iClose(_Symbol, PERIOD_CURRENT, 0);
   double best_resistance = DBL_MAX;
   bool found = false;
   
   for(int i = 0; i < g_level_count; i++) {
      if(!g_levels[i].is_support && !g_levels[i].is_broken &&
         g_levels[i].touches >= InpMinTouches &&
         g_levels[i].price >= current_price &&
         g_levels[i].price < best_resistance) {
         best_resistance = g_levels[i].price;
         found = true;
      }
   }
   
   if(found) {
      out_price = best_resistance;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ОПРЕДЕЛЕНИЕ ТРЕНДА (EMA + ADX)                                   |
//+------------------------------------------------------------------+
int GetTrendDirection() {
   // EMA fast vs EMA slow
   double ema_fast = iMA(_Symbol, PERIOD_H4, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema_slow = iMA(_Symbol, PERIOD_H4, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 0);
   
   // ADX
   double adx = iADX(_Symbol, PERIOD_H4, InpAdxPeriod, 0);
   
   if(adx < InpAdxFlatThreshold)
      return 0;  // Флэт
   
   if(ema_fast > ema_slow)
      return 1;   // Восходящий
   else
      return -1;  // Нисходящий
}

//+------------------------------------------------------------------+
//| ОПРЕДЕЛЕНИЕ ПАТТЕРНОВ                                             |
//+------------------------------------------------------------------+
bool DetectPinBar(double open_p, double high, double low, double close) {
   double body = MathAbs(close - open_p);
   double range_size = high - low;
   
   if(range_size == 0.0)
      return false;
   
   double upper_shadow = high - MathMax(open_p, close);
   double lower_shadow = MathMin(open_p, close) - low;
   
   // Тело мало, одна тень длинная
   if(body / range_size < 0.3) {
      if(lower_shadow > upper_shadow * 2 || upper_shadow > lower_shadow * 2)
         return true;
   }
   
   return false;
}

bool DetectEngulfing(double prev_open, double prev_close, double curr_open, 
                     double curr_close, double curr_high, double curr_low) {
   double prev_high = MathMax(prev_open, prev_close);
   double prev_low  = MathMin(prev_open, prev_close);
   double curr_high_body = MathMax(curr_open, curr_close);
   double curr_low_body  = MathMin(curr_open, curr_close);
   
   if(curr_high_body > prev_high && curr_low_body < prev_low)
      return true;
   
   return false;
}

bool DetectDoji(double open_p, double high, double low, double close) {
   double body = MathAbs(close - open_p);
   double range_size = high - low;
   
   if(range_size == 0.0)
      return false;
   
   if(body / range_size < 0.1)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| ВИЗУАЛИЗАЦИЯ УРОВНЕЙ                                              |
//+------------------------------------------------------------------+
void VisualizeLevels() {
   if(!InpVisualizeLevels)
      return;
   
   // Удаляем старые объекты
   for(int i = ObjectsTotal(); i >= 0; i--) {
      string obj_name = ObjectName(i);
      if(StringFind(obj_name, "FVLR_") >= 0)
         ObjectDelete(obj_name);
   }
   
   // Рисуем уровни
   for(int i = 0; i < g_level_count; i++) {
      if(g_levels[i].touches < InpMinTouches)
         continue;
      
      string obj_name = "FVLR_" + (string)i;
      color line_color = g_levels[i].is_support ? clrGreen : clrRed;
      
      if(g_levels[i].is_broken)
         line_color = clrGray;
      
      ObjectCreate(obj_name, OBJ_HLINE, 0, TimeCurrent(), g_levels[i].price);
      ObjectSetInteger(obj_name, OBJPROP_COLOR, line_color);
      ObjectSetInteger(obj_name, OBJPROP_WIDTH, g_levels[i].touches >= 3 ? 2 : 1);
      
      // Подпись
      string label_text = (g_levels[i].is_support ? "S" : "R") + 
                          " | touches=" + (string)g_levels[i].touches;
      ObjectSetString(obj_name, OBJPROP_TEXT, label_text);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit() {
   g_trade.SetExpertMagicNumber(InpMagic);
   
   // Инициализация handles
   g_atr_handle_h4 = iATR(_Symbol, PERIOD_H4, InpAtrPeriod);
   ENUM_TIMEFRAMES entry_tf = GetEntryTF();
   g_atr_handle_entry = iATR(_Symbol, entry_tf, InpAtrPeriod);
   
   g_ema_fast_handle = iMA(_Symbol, PERIOD_H4, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_handle = iMA(_Symbol, PERIOD_H4, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_adx_handle = iADX(_Symbol, PERIOD_H4, InpAdxPeriod);
   
   // Расчёт уровней
   RecalculateLevels();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // Уже есть открытая позиция
   if(PositionSelect(_Symbol)) {
      return;
   }
   
   // Пересчет уровней на каждом баре H4
   static datetime last_h4_bar = 0;
   datetime current_h4_bar = iTime(_Symbol, PERIOD_H4, 0);
   if(current_h4_bar != last_h4_bar) {
      RecalculateLevels();
      VisualizeLevels();
      last_h4_bar = current_h4_bar;
   }
   
   // Получаем данные
   double current_price = iClose(_Symbol, PERIOD_CURRENT, 0);
   int trend = GetTrendDirection();
   ENUM_TIMEFRAMES entry_tf = GetEntryTF();
   
   double atr_entry = GetAtr(entry_tf, InpAtrPeriod, 0);
   if(atr_entry <= 0.0)
      return;
   
   // Проверяем лонги от поддержки
   double support_level = 0.0;
   if(GetNearestSupportLevel(support_level)) {
      double zone_dist = InpEntryZoneATR * atr_entry;
      
      if(MathAbs(current_price - support_level) <= zone_dist &&
         (trend == 1 || trend == 0)) {  // восходящий или флэт
         
         // Проверяем паттерн на младшем ТФ
         double o = iOpen(_Symbol, entry_tf, 0);
         double h = iHigh(_Symbol, entry_tf, 0);
         double l = iLow(_Symbol, entry_tf, 0);
         double c = iClose(_Symbol, entry_tf, 0);
         
         double prev_o = iOpen(_Symbol, entry_tf, 1);
         double prev_c = iClose(_Symbol, entry_tf, 1);
         
         bool pin_bar = InpUsePinBar && DetectPinBar(o, h, l, c);
         bool engulfing = InpUseEngulfing && DetectEngulfing(prev_o, prev_c, o, c, h, l);
         bool doji = InpUseDoji && DetectDoji(o, h, l, c);
         
         if(pin_bar || engulfing || doji) {
            // Вход в лонг
            double sl_distance = InpSlAtrMult * atr_entry;
            double sl_price = current_price - sl_distance;
            double tp_price = current_price + sl_distance * InpRR;
            
            double lot = NormalizeLot(InpLot);
            
            g_trade.Buy(lot, _Symbol, 0, sl_price, tp_price, "Level Reversal Long");
            return;
         }
      }
   }
   
   // Проверяем шорты от сопротивления
   double resistance_level = 0.0;
   if(GetNearestResistanceLevel(resistance_level)) {
      double zone_dist = InpEntryZoneATR * atr_entry;
      
      if(MathAbs(current_price - resistance_level) <= zone_dist &&
         (trend == -1 || trend == 0)) {  // нисходящий или флэт
         
         double o = iOpen(_Symbol, entry_tf, 0);
         double h = iHigh(_Symbol, entry_tf, 0);
         double l = iLow(_Symbol, entry_tf, 0);
         double c = iClose(_Symbol, entry_tf, 0);
         
         double prev_o = iOpen(_Symbol, entry_tf, 1);
         double prev_c = iClose(_Symbol, entry_tf, 1);
         
         bool pin_bar = InpUsePinBar && DetectPinBar(o, h, l, c);
         bool engulfing = InpUseEngulfing && DetectEngulfing(prev_o, prev_c, o, c, h, l);
         bool doji = InpUseDoji && DetectDoji(o, h, l, c);
         
         if(pin_bar || engulfing || doji) {
            // Вход в шорт
            double sl_distance = InpSlAtrMult * atr_entry;
            double sl_price = current_price + sl_distance;
            double tp_price = current_price - sl_distance * InpRR;
            
            double lot = NormalizeLot(InpLot);
            
            g_trade.Sell(lot, _Symbol, 0, sl_price, tp_price, "Level Reversal Short");
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   // Удаляем объекты с графика
   for(int i = ObjectsTotal(); i >= 0; i--) {
      string obj_name = ObjectName(i);
      if(StringFind(obj_name, "FVLR_") >= 0)
         ObjectDelete(obj_name);
   }
}

//+------------------------------------------------------------------+
