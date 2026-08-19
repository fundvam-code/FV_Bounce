//+------------------------------------------------------------------+
//|                                        export_rates.mq5          |
//|  Скрипт для экспорта исторических данных в CSV                  |
//|  Автоматически определяет таймфрейм по прикреплению             |
//|  Сохраняет в папку Files терминала                              |
//+------------------------------------------------------------------+
#property copyright "FV_Bounce"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input string       InpSymbol           = "EURUSD";           // Символ (оставить пусто = текущий)
input int          InpStartYear        = 2020;               // Год начала (например, 2020)
input int          InpStartMonth       = 1;                  // Месяц начала (1-12)
input int          InpStartDay         = 1;                  // День начала (1-31)
input int          InpEndYear          = 2025;               // Год конца
input int          InpEndMonth         = 12;                 // Месяц конца
input int          InpEndDay           = 31;                 // День конца

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                            |
//+------------------------------------------------------------------+
string             g_symbol = "";
ENUM_TIMEFRAMES    g_timeframe = PERIOD_CURRENT;
datetime           g_start_time = 0;
datetime           g_end_time = 0;

//+------------------------------------------------------------------+
//| OnStart - основная функция скрипта                               |
//+------------------------------------------------------------------+
void OnStart() {
   
   // Определяем символ
   if(InpSymbol == "" || InpSymbol == " ") {
      g_symbol = _Symbol;
   } else {
      g_symbol = InpSymbol;
   }
   
   // Определяем таймфрейм по текущему графику
   g_timeframe = _Period;
   string tf_name = GetTimeframeString(g_timeframe);
   
   Print("=== ЭКСПОРТ ДАННЫХ ===");
   Print("Символ: " + g_symbol);
   Print("Таймфрейм: " + tf_name + " (" + (string)g_timeframe + ")");
   
   // Формируем время начала и конца
   g_start_time = StringToTime(
      (string)InpStartYear + "." + 
      PadLeft((string)InpStartMonth, 2, '0') + "." + 
      PadLeft((string)InpStartDay, 2, '0') + " 00:00:00"
   );
   
   g_end_time = StringToTime(
      (string)InpEndYear + "." + 
      PadLeft((string)InpEndMonth, 2, '0') + "." + 
      PadLeft((string)InpEndDay, 2, '0') + " 23:59:59"
   );
   
   Print("Период: " + TimeToString(g_start_time) + " - " + TimeToString(g_end_time));
   
   // Запрашиваем данные
   MqlRates rates[];
   int bars = CopyRates(g_symbol, g_timeframe, g_start_time, g_end_time, rates);
   
   if(bars <= 0) {
      Print("❌ ОШИБКА: Не удалось загрузить данные.");
      Print("Код ошибки: " + (string)GetLastError());
      Print("Рекомендации:");
      Print("  1. Проверьте имя символа (например, EURUSD)");
      Print("  2. Убедитесь, что выбран правильный таймфрейм на графике");
      Print("  3. Загрузите данные в историю (Окно → Обозреватель данных)");
      return;
   }
   
   Print("✓ Загружено баров: " + (string)bars);
   
   // Формируем имя файла
   string filename = g_symbol + "_" + tf_name + "_" + 
                     (string)InpStartYear + "-" + 
                     PadLeft((string)InpStartMonth, 2, '0') + "-" + 
                     PadLeft((string)InpStartDay, 2, '0') + "_" +
                     (string)InpEndYear + "-" + 
                     PadLeft((string)InpEndMonth, 2, '0') + "-" + 
                     PadLeft((string)InpEndDay, 2, '0') + ".csv";
   
   // Сохраняем в CSV
   if(SaveToCSV(rates, filename)) {
      Print("✓ Файл сохранён: " + filename);
      Print("📁 Расположение: " + GetFileLocation());
      Print("\n📋 ИНСТРУКЦИИ:");
      Print("1. Откройте папку Files в папке терминала MT5");
      Print("2. Найдите файл: " + filename);
      Print("3. Скопируйте его в папку проекта: /workspaces/FV_Bounce/content/");
      Print("4. Откройте Jupyter notebook: level_reversal_opt.ipynb");
      Print("5. Запустите ячейку загрузки данных");
   } else {
      Print("❌ ОШИБКА: Не удалось сохранить файл");
   }
}

//+------------------------------------------------------------------+
//| SaveToCSV - сохранение данных в CSV файл                         |
//+------------------------------------------------------------------+
bool SaveToCSV(const MqlRates& rates[], string filename) {
   
   // Открываем файл для записи
   int handle = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   
   if(handle == INVALID_HANDLE) {
      Print("Ошибка при открытии файла. Код: " + (string)GetLastError());
      return false;
   }
   
   // Записываем заголовок
   FileWrite(handle, "Time,Open,High,Low,Close,Volume");
   
   // Записываем данные
   int total = ArraySize(rates);
   for(int i = 0; i < total; i++) {
      
      // Форматируем время (YYYY-MM-DD HH:MM:SS)
      string time_str = TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES);
      time_str = StringSubstr(time_str, 0, 10) + " " + StringSubstr(time_str, 11, 5) + ":00";
      
      // Записываем строку: Time,Open,High,Low,Close,Volume
      FileWrite(handle, 
         time_str, 
         (string)rates[i].open,
         (string)rates[i].high,
         (string)rates[i].low,
         (string)rates[i].close,
         (string)rates[i].tick_volume
      );
   }
   
   FileClose(handle);
   return true;
}

//+------------------------------------------------------------------+
//| GetTimeframeString - конвертирует период в строку               |
//+------------------------------------------------------------------+
string GetTimeframeString(ENUM_TIMEFRAMES period) {
   switch(period) {
      case PERIOD_M1:  return "M1";
      case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";
      case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";
      case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";
      case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";
      case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";
      case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";
      case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default: return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| GetFileLocation - возвращает полный путь к папке Files          |
//+------------------------------------------------------------------+
string GetFileLocation() {
   return TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";
}

//+------------------------------------------------------------------+
//| PadLeft - дополняет строку символом слева                       |
//+------------------------------------------------------------------+
string PadLeft(string str, int length, char pad_char) {
   while(StringLen(str) < length) {
      str = CharToString(pad_char) + str;
   }
   return str;
}

//+------------------------------------------------------------------+
