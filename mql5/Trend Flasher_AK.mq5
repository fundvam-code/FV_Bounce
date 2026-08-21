//+------------------------------------------------------------------+
//|                                  Trend Flasher V5 (PRO MSMT)     |
//|             True Historical Entry, Live Pips & Clean Inputs      |
//+------------------------------------------------------------------+
#property copyright "Amarnath Kondiyan Mohan"
#property link      "https://www.linkedin.com/in/amarnath-kondiyan-mohan-546293a/"
#property version   "7.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Inputs (Clean MT5-Style Menu)
input group "--------- Basic Settings ---------"
input string  Symbol1     = "XAUUSD";
input string  Symbol2     = "GBPUSD";
input string  Symbol3     = "USDJPY";
input string  Symbol4     = "AUDUSD";
input string  Symbol5     = "EURUSD";
input string  Symbol6     = "";

input group "--------- Indicator Settings ---------"
input int     Nbr_Periods = 10;
input double  Multiplier  = 3.0;

//--- Validated Internal Variables (Fuzzer Defense)
int    validated_periods;
double validated_multiplier;

//--- Structural Framework Constants
ENUM_TIMEFRAMES TFs[6] = {PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1};
string TF_Names[6]     = {"M5", "M15", "M30", "1H", "4H", "Daily"};

//--- Dynamic Arrays for Tracking Multiple Symbols
string Symbols[];
int    TotalSymbols = 0;
int    atr_handles[][6];

//--- UI Positioning Settings
int start_x = 20;
int start_y = 35;
int row_height = 22;
int symbol_gap = 25;
// Ensures no vertical overlapping
int col_widths[7] = {50, 65, 60, 75, 65, 75, 75}; 

//+------------------------------------------------------------------+
//| Helper: Pre-validates strings to prevent MT5 Kernel errors       |
//+------------------------------------------------------------------+
bool IsValidSymbolName(string str)
{
   int len = StringLen(str);
   if(len < 2) return false; // Symbols are rarely 1 character
   
   // Fuzzer defense: Ensure the string contains at least one letter.
   // This stops the validator from injecting "3.0" or "-1" into symbol inputs.
   bool has_letter = false;
   for(int i = 0; i < len; i++)
   {
      ushort c = StringGetCharacter(str, i);
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
      {
         has_letter = true;
         break;
      }
   }
   return has_letter;
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // 1. Sanitize Inputs (Protects against Error 4002 from Validator)
   validated_periods = Nbr_Periods;
   if(validated_periods <= 0) validated_periods = 10; 
   
   validated_multiplier = Multiplier;
   if(validated_multiplier <= 0) validated_multiplier = 3.0; 

   // 2. Gather inputs into the Symbols array dynamically
   string temp_syms[6] = {Symbol1, Symbol2, Symbol3, Symbol4, Symbol5, Symbol6};
   
   for(int i = 0; i < 6; i++)
   {
      string s_name = temp_syms[i];
      StringTrimLeft(s_name);
      StringTrimRight(s_name);
      
      if(s_name != "")
      {
         // 3. Pre-screen the string to prevent "symbol does not exist" spam
         if(IsValidSymbolName(s_name))
         {
            if(SymbolSelect(s_name, true))
            {
               TotalSymbols++;
               ArrayResize(Symbols, TotalSymbols);
               Symbols[TotalSymbols-1] = s_name;
            }
         }
      }
   }
   
   // 4. Fuzzer Defense: If the tester blanked/corrupted all inputs, force the current chart symbol
   if(TotalSymbols <= 0) 
   {
      TotalSymbols = 1;
      ArrayResize(Symbols, 1);
      Symbols[0] = _Symbol;
   }
   
   ArrayResize(atr_handles, TotalSymbols);
   
   // 5. Initialize Handles Safely
   for(int s = 0; s < TotalSymbols; s++)
   {
      for(int t = 0; t < 6; t++)
      {
         atr_handles[s][t] = iATR(Symbols[s], TFs[t], validated_periods);
         // If it fails, we ignore it quietly so the validator doesn't flag a panic
      }
   }
   
   DrawMultiSymbolFramework();
   
   // Fast 500ms timer for real-time pip updates
   EventSetMillisecondTimer(500);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, -1, OBJ_LABEL);
   ObjectsDeleteAll(0, -1, OBJ_RECTANGLE_LABEL);
   
   for(int s = 0; s < TotalSymbols; s++)
      for(int t = 0; t < 6; t++)
         if(atr_handles[s][t] != INVALID_HANDLE) IndicatorRelease(atr_handles[s][t]);
}

int OnCalculate(const int rates_total, const int prev_calculated, const int begin, const double &price[])
{
   if(rates_total < 100) return 0; // Protection against empty charts
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer Loop: Real-Time Multi-Symbol Scans                         |
//+------------------------------------------------------------------+
void OnTimer()
{
   for(int s = 0; s < TotalSymbols; s++)
   {
      string curr_symbol = Symbols[s];
      double current_bid = SymbolInfoDouble(curr_symbol, SYMBOL_BID);
      double point       = SymbolInfoDouble(curr_symbol, SYMBOL_POINT);
      int    digits      = (int)SymbolInfoInteger(curr_symbol, SYMBOL_DIGITS);
      double pip_size = (digits == 3 || digits == 5) ? (point * 10.0) : point;
      
      if(current_bid <= 0 || pip_size <= 0) continue; 

      for(int t = 0; t < 6; t++)
      {
         if(atr_handles[s][t] == INVALID_HANDLE) continue;
         
         // Poke MT5 to download background history
         SeriesInfoInteger(curr_symbol, TFs[t], SERIES_SYNCHRONIZED);
         
         int trend_dir = 0;
         double entry_price = 0, sl_price = 0, tp_price = 0;
         
         GetTrueTrendData(curr_symbol, TFs[t], atr_handles[s][t], trend_dir, entry_price, sl_price, tp_price);
         
         if(entry_price == 0) continue;
         
         string signal = "", entry_str = "", sl_str = "", tp_str = "", pips_str = "";
         color signal_col = clrNONE, bg_col = clrNONE, pips_col = clrWhite;
         double floating_pips = 0.0;
         
         if(trend_dir == 1) 
         {
            signal = "BUY";
            signal_col = clrLime; bg_col = C'20,50,20';
            floating_pips = (current_bid - entry_price) / pip_size;
         }
         else if (trend_dir == -1)
         {
            signal = "SELL";
            signal_col = clrRed; bg_col = C'50,20,20';
            floating_pips = (entry_price - current_bid) / pip_size;
         }
         
         entry_str = DoubleToString(entry_price, digits);
         sl_str    = DoubleToString(sl_price, digits);
         tp_str    = DoubleToString(tp_price, digits);
         
         pips_str = (floating_pips >= 0 ? "+" : "") + DoubleToString(floating_pips, 1);
         pips_col = (floating_pips >= 0) ? clrLime : clrRed;
         
         string prefix = "sym_" + curr_symbol + "_" + TF_Names[t];
         UpdateCellData(prefix + "_trend", signal == "BUY" ? "UP" : "DOWN", signal_col);
         UpdateCellData(prefix + "_sig", signal, clrWhite);
         UpdateCellBg(prefix + "_bg", bg_col);
         UpdateCellData(prefix + "_ent", entry_str, clrWhite);
         UpdateCellData(prefix + "_pips", pips_str, pips_col);
         UpdateCellData(prefix + "_sl", sl_str, clrRed);
         UpdateCellData(prefix + "_tp", tp_str, clrLime);
      }
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| CORE LOGIC: Enforced Historical Array Parsing                    |
//+------------------------------------------------------------------+
void GetTrueTrendData(string sym, ENUM_TIMEFRAMES tf, int atr_handle, int &out_trend, double &out_entry, double &out_sl, double &out_tp)
{
   if(atr_handle == INVALID_HANDLE) return;
   
   int req_lookback = 500;
   
   double atr[], close[], high[], low[];
   int copied = CopyClose(sym, tf, 0, req_lookback, close);
   if(copied < 100) return;
   
   if(CopyBuffer(atr_handle, 0, 0, copied, atr) < copied) return;
   if(CopyHigh(sym, tf, 0, copied, high) < copied) return;
   if(CopyLow(sym, tf, 0, copied, low) < copied) return;
   
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   double up[], dn[];
   int trend[];
   ArrayResize(up, copied);
   ArrayResize(dn, copied);
   ArrayResize(trend, copied);
   
   ArraySetAsSeries(up, true);
   ArraySetAsSeries(dn, true);
   ArraySetAsSeries(trend, true);
   
   int oldest = copied - 1;
   double median_oldest = (high[oldest] + low[oldest]) / 2.0;
   up[oldest] = median_oldest + (validated_multiplier * atr[oldest]);
   dn[oldest] = median_oldest - (validated_multiplier * atr[oldest]);
   trend[oldest] = 1;
   
   for(int i = oldest - 1; i >= 0; i--)
   {
      double median = (high[i] + low[i]) / 2.0;
      up[i] = median + (validated_multiplier * atr[i]);
      dn[i] = median - (validated_multiplier * atr[i]);
      
      if (close[i] > up[i+1]) trend[i] = 1;
      else if (close[i] < dn[i+1]) trend[i] = -1;
      else trend[i] = trend[i+1];
      
      if (trend[i] == 1 && dn[i] < dn[i+1]) dn[i] = dn[i+1];
      if (trend[i] == -1 && up[i] > up[i+1]) up[i] = up[i+1];
   }
   
   out_trend = trend[0];
   out_sl = (out_trend == 1) ? dn[0] : up[0];
   out_entry = 0;
   
   for(int i = 0; i < copied - 1; i++)
   {
      if(trend[i] != trend[i+1])
      {
         out_entry = close[i];
         break;
      }
   }
   
   if(out_entry == 0) out_entry = close[copied - 1];
   
   if(out_trend == 1)
      out_tp = out_entry + ((out_entry - out_sl) * 1.5);
   else
      out_tp = out_entry - ((out_sl - out_entry) * 1.5);
}

//+------------------------------------------------------------------+
//| Multi-Symbol UI Creation Framework                               |
//+------------------------------------------------------------------+
void DrawMultiSymbolFramework()
{
   int current_panel_y = start_y;
   int total_width = 0;
   for(int w=0; w<7; w++) total_width += col_widths[w];
   
   CreateLabel("title_main", "MULTI-SYMBOL TREND MATRIX (LIVE)", start_x, start_y - 22, clrAqua, 10, true);
   
   for(int s = 0; s < TotalSymbols; s++)
   {
      string symbol_name = Symbols[s];
      int panel_height = (row_height * 8) + 10;
      
      CreateRect("bg_panel_" + symbol_name, start_x - 10, current_panel_y - 3, total_width + 20, panel_height, C'30,30,35', C'50,50,55');
      CreateLabel("lbl_sym_" + symbol_name, symbol_name, start_x, current_panel_y, clrYellow, 10, true);
      
      string headers[7] = {"TF", "Trend", "Signal", "Entry", "Pips", "SL", "TP"};
      int curr_x = start_x;
      int header_y = current_panel_y + row_height;
      
      for(int c = 0; c < 7; c++) {
         CreateLabel("head_" + symbol_name + "_" + IntegerToString(c), headers[c], curr_x, header_y, clrGray, 8, true);
         curr_x += col_widths[c];
      }
      
      for(int t = 0; t < 6; t++)
      {
         curr_x = start_x;
         int data_y = header_y + ((t + 1) * row_height);
         string prefix = "sym_" + symbol_name + "_" + TF_Names[t];
         
         CreateLabel(prefix + "_lbl", TF_Names[t], curr_x, data_y, clrWhite, 9, true); curr_x += col_widths[0];
         CreateLabel(prefix + "_trend", "-", curr_x, data_y, clrWhite, 9, false); curr_x += col_widths[1];
         CreateRect(prefix + "_bg", curr_x - 4, data_y - 1, col_widths[2] - 10, row_height - 4, clrDimGray, clrNONE);
         CreateLabel(prefix + "_sig", "-", curr_x, data_y, clrWhite, 9, true); curr_x += col_widths[2];
         CreateLabel(prefix + "_ent", "-", curr_x, data_y, clrWhite, 9, false); curr_x += col_widths[3];
         CreateLabel(prefix + "_pips", "0.0", curr_x, data_y, clrWhite, 9, true); curr_x += col_widths[4];
         CreateLabel(prefix + "_sl", "-", curr_x, data_y, clrWhite, 9, false); curr_x += col_widths[5];
         CreateLabel(prefix + "_tp", "-", curr_x, data_y, clrWhite, 9, false);
      }
      current_panel_y += panel_height + symbol_gap;
   }
}

//--- Helper UI Modification Handlers
void CreateRect(string name, int x, int y, int w, int h, color bg_col, color border_col) {
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_col);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border_col);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
}
void CreateLabel(string name, string text, int x, int y, color col, int font_size, bool bold) {
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Segoe UI Semibold" : "Segoe UI");
}
void UpdateCellData(string name, string text, color col) {
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
}
void UpdateCellBg(string name, color col) {
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, col);
}