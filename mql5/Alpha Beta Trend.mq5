//+------------------------------------------------------------------+
//|                                               Alpha Beta Trend   |
//|                                        Email : amarfx@gmail.com  |
//+------------------------------------------------------------------+
#property copyright "Amarnath Kondiyan Mohan"
#property link      "https://www.linkedin.com/in/amarnath-kondiyan-mohan-546293a/"
#property version   "1.00"
#property copyright "Amarnath Kondiyan Mohan"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   1

//--- Plot Settings (Color-Coded Line)
#property indicator_label1  "Alpha-Beta Trend"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrDodgerBlue, clrCrimson // Index 0 = Bullish (Blue), Index 1 = Bearish (Red)
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Input Parameters
input group "--- Filter Engine Settings ---"
input double               inpAlpha       = 0.2;            // Alpha (Price Sensitivity)
input double               inpBeta        = 0.05;           // Beta (Velocity Sensitivity)

input group "--- Dashboard Grid Settings ---"
input string               inpSymbols     = "EURUSD,GBPUSD,USDJPY,AUDUSD"; // Symbols (Comma Separated)
input bool                 showM5         = true;           // Show M5
input bool                 showM15        = true;           // Show M15
input bool                 showH1         = true;           // Show H1
input bool                 showH4         = true;           // Show H4
input bool                 showD1         = true;           // Show D1

//--- Indicator Buffers
double         PriceBuffer[];    // Plotted line coordinates
double         ColorBuffer[];    // Plotted line color index (0 or 1)
double         VelocityBuffer[]; // Internal tracking calculation buffer

//--- UI & Engine Global Variables
string         prefix = "AB_Matrix_";
string         arrSymbols[];
int            totalSymbols = 0;
ENUM_TIMEFRAMES arrTFs[5];
string         arrTFNames[5];
int            totalTFs = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Bind arrays to structural indicator buffers
   SetIndexBuffer(0, PriceBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, ColorBuffer, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, VelocityBuffer, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(PriceBuffer, true);
   ArraySetAsSeries(ColorBuffer, true);
   ArraySetAsSeries(VelocityBuffer, true);

//--- Parse Symbols Input List
   string cleanSymbols = inpSymbols;
   StringReplace(cleanSymbols, " ", ""); // Strip spaces
   totalSymbols = StringSplit(cleanSymbols, ',', arrSymbols);

//--- Configure Active Timeframes Array
   totalTFs = 0;
   if(showM5)
     {
      arrTFs[totalTFs] = PERIOD_M5;
      arrTFNames[totalTFs] = "M5";
      totalTFs++;
     }
   if(showM15)
     {
      arrTFs[totalTFs] = PERIOD_M15;
      arrTFNames[totalTFs] = "M15";
      totalTFs++;
     }
   if(showH1)
     {
      arrTFs[totalTFs] = PERIOD_H1;
      arrTFNames[totalTFs] = "H1";
      totalTFs++;
     }
   if(showH4)
     {
      arrTFs[totalTFs] = PERIOD_H4;
      arrTFNames[totalTFs] = "H4";
      totalTFs++;
     }
   if(showD1)
     {
      arrTFs[totalTFs] = PERIOD_D1;
      arrTFNames[totalTFs] = "D1";
      totalTFs++;
     }

//--- Initialize Graphic Dashboard Labels
   CreateDashboardObjects();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const int begin,
                const double &price[])
  {
   if(rates_total < 2)
      return(0);
   ArraySetAsSeries(price, true);

   int limit = rates_total - prev_calculated;

   if(prev_calculated == 0)
     {
      limit = rates_total - 2;
      PriceBuffer[limit+1] = price[limit+1];
      ColorBuffer[limit+1] = 0;
      VelocityBuffer[limit+1] = 0.0;
     }

//--- Main History Calculation Loop for Current Chart
   for(int i = limit; i >= 0; i--)
     {
      double pred_P = PriceBuffer[i+1] + VelocityBuffer[i+1];
      double error = price[i] - pred_P;

      PriceBuffer[i]    = pred_P + (inpAlpha * error);
      VelocityBuffer[i] = VelocityBuffer[i+1] + (inpBeta * error);

      // Assign line color based on velocity state
      ColorBuffer[i] = (VelocityBuffer[i] >= 0.0) ? 0 : 1;
     }

//--- Update Multi-Symbol Matrix Dashboard Elements
   UpdateDashboardMatrix();

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Helper Matrix Calculation: Fetches live data for external targets|
//+------------------------------------------------------------------+
int GetStateForTarget(string symbol, ENUM_TIMEFRAMES tf)
  {
   double closePrices[];
   ArraySetAsSeries(closePrices, true);

// We only need a shallow bar history depth to get current state safely
   int copied = CopyClose(symbol, tf, 0, 50, closePrices);
   if(copied < 2)
      return(-1); // Data not ready or invalid symbol

   double p = closePrices[copied-1];
   double v = 0.0;

   for(int i = copied-2; i >= 0; i--)
     {
      double pred_p = p + v;
      double err = closePrices[i] - pred_p;
      p += inpAlpha * err;
      v += inpBeta * err;
     }

   return (v >= 0.0) ? 0 : 1; // 0 = Bullish, 1 = Bearish
  }

//+------------------------------------------------------------------+
//| UI: Create Graphic Labels Hierarchy                              |
//+------------------------------------------------------------------+
void CreateDashboardObjects()
  {
   int startX = 20, startY = 30;
   int rowHeight = 22, colWidth = 65;

// Draw Column Headers (Timeframes)
   for(int t = 0; t < totalTFs; t++)
     {
      CreateLabel(prefix + "Head_" + arrTFNames[t], arrTFNames[t], startX + 90 + (t * colWidth), startY, clrSilver, 9, true);
     }

// Draw Row Layouts (Symbols & Placeholders)
   for(int s = 0; s < totalSymbols; s++)
     {
      int yPos = startY + 25 + (s * rowHeight);
      CreateLabel(prefix + "Row_" + arrSymbols[s], arrSymbols[s], startX, yPos, clrWhite, 10, true);

      for(int t = 0; t < totalTFs; t++)
        {
         string cellName = prefix + "Cell_" + arrSymbols[s] + "_" + arrTFNames[t];
         CreateLabel(cellName, "[---]", startX + 90 + (t * colWidth), yPos, clrGray, 9, false);
        }
     }
  }

//+------------------------------------------------------------------+
//| UI: Update Real-time Status Grid Values                          |
//+------------------------------------------------------------------+
void UpdateDashboardMatrix()
  {
   for(int s = 0; s < totalSymbols; s++)
     {
      for(int t = 0; t < totalTFs; t++)
        {
         string cellName = prefix + "Cell_" + arrSymbols[s] + "_" + arrTFNames[t];
         int state = GetStateForTarget(arrSymbols[s], arrTFs[t]);

         if(state == 0)
           {
            ObjectSetString(0, cellName, OBJPROP_TEXT, "BULL");
            ObjectSetInteger(0, cellName, OBJPROP_COLOR, clrLimeGreen);
           }
         else
            if(state == 1)
              {
               ObjectSetString(0, cellName, OBJPROP_TEXT, "BEAR");
               ObjectSetInteger(0, cellName, OBJPROP_COLOR, clrCrimson);
              }
            else
              {
               ObjectSetString(0, cellName, OBJPROP_TEXT, "WAIT");
               ObjectSetInteger(0, cellName, OBJPROP_COLOR, clrOrange);
              }
        }
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| UI UI Elements Wrapper Method                                    |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int size, bool bold)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Trebuchet MS Bold" : "Trebuchet MS");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }
//+------------------------------------------------------------------+
