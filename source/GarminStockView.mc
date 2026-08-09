import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Math;

class GarminStockView extends WatchUi.WatchFace {

    private var _isLowPower as Boolean = true;
    private var _stockData as Dictionary or Null = null;
    private var _lastUpdateTime as Number or Null = null;

    private var _chartMin as Number or Null = null;
    private var _chartMax as Number or Null = null;
    private var _regStart as Number or Null = null;
    private var _postEnd as Number or Null = null;
    private var _countdownFont = null;

    function initialize() {
        WatchFace.initialize();
        loadStockData();
    }

    function loadStockData() as Void {
        var stockData = Application.Storage.getValue("stock_data") as Dictionary or Null;
        if (stockData != null) {
            var dict = stockData as Dictionary;
            if (dict.hasKey("ticker")) {
                var cachedTicker = dict["ticker"] as String;
                if (cachedTicker == null || !cachedTicker.equals("SNDK")) {
                    Application.Storage.setValue("stock_data", null);
                    stockData = null;
                }
            }
        }
        _stockData = stockData;
        _lastUpdateTime = Application.Storage.getValue("last_update_time") as Number or Null;

        // Calculate chart min and max once when loading data
        _chartMin = null;
        _chartMax = null;
        if (_stockData != null) {
            var chart = _stockData["chart"] as Array;
            if (chart != null && chart.size() > 0) {
                _chartMin = chart[0];
                _chartMax = chart[0];
                for (var i = 1; i < chart.size(); i++) {
                    var val = chart[i];
                    if (val != null) {
                        if (_chartMin == null || val < _chartMin) { _chartMin = val; }
                        if (_chartMax == null || val > _chartMax) { _chartMax = val; }
                    }
                }
            }
        }
        
        _regStart = null;
        _postEnd = null;
        if (_stockData != null) {
            if (_stockData.hasKey("reg_start")) { _regStart = _stockData["reg_start"] as Number; }
            if (_stockData.hasKey("post_end")) { _postEnd = _stockData["post_end"] as Number; }
        }
    }

    function handleBackgroundUpdate(data) as Void {
        System.println("handleBackgroundUpdate triggered. data: " + data);
        loadStockData();
    }

    function isMarketClosed(now as Number) as Boolean {
        if (_regStart != null && _postEnd != null) {
            var closedStart = _postEnd;
            var closedEnd = _regStart - 48600; // Sunday overnight open (13.5h before regular open)
            if (closedStart < closedEnd) {
                if (now >= closedStart && now < closedEnd) {
                    return true;
                }
                return false;
            }
        }
        
        // Fallback: Check if we are in the standard weekend closed period
        var nowMoment = Time.now();
        var info = Gregorian.info(nowMoment, Time.FORMAT_SHORT);
        var dayOfWeek = info.day_of_week; // 1 = Sunday, 2 = Monday, ..., 7 = Saturday
        var hour = info.hour;
        
        if (dayOfWeek == 7) {
            return true; // Saturday is always closed
        }
        if (dayOfWeek == 6 && hour >= 20) {
            return true; // Friday after 8:00 PM is closed
        }
        if (dayOfWeek == 1 && hour < 20) {
            return true; // Sunday before 8:00 PM is closed
        }
        return false;
    }

    function drawCountdownTimer(dc as Dc, now as Number) as Void {
        var target = null;
        if (_regStart != null && _postEnd != null) {
            var closedStart = _postEnd;
            var closedEnd = _regStart - 48600;
            if (closedStart < closedEnd) {
                target = closedEnd;
            }
        }
        
        if (target == null) {
            target = getNextSundayOvernightOpen();
        }

        var diff = target - now;
        if (diff < 0) {
            diff = 0;
        }

        var hours = diff / 3600;
        var minutes = (diff % 3600) / 60;
        var seconds = diff % 60;

        var timeStr = hours.format("%02d") + ":" + minutes.format("%02d") + ":" + seconds.format("%02d");

        var font = Graphics.FONT_TINY;
        var fontHeight = dc.getFontHeight(font);
        var y = 60 - fontHeight;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(12, y, font, timeStr, Graphics.TEXT_JUSTIFY_LEFT);
    }

    function getNextSundayOvernightOpen() as Number {
        var nowMoment = Time.now();
        var info = Gregorian.info(nowMoment, Time.FORMAT_SHORT);
        var dayOfWeek = info.day_of_week; // 1 = Sunday, 2 = Monday, ..., 7 = Saturday
        
        var daysUntilSunday = 8 - dayOfWeek;
        if (dayOfWeek == 1) {
            if (info.hour >= 20) {
                daysUntilSunday = 7;
            } else {
                daysUntilSunday = 0;
            }
        }
        
        var targetDate = nowMoment.add(new Time.Duration(daysUntilSunday * 86400));
        var targetInfo = Gregorian.info(targetDate, Time.FORMAT_SHORT);
        
        var targetOptions = {
            :year   => targetInfo.year,
            :month  => targetInfo.month,
            :day    => targetInfo.day,
            :hour   => 20,
            :minute => 0,
            :second => 0
        };
        var targetMoment = Gregorian.moment(targetOptions);
        
        // Adjust for local timezone offset since Gregorian.moment assumes UTC input
        var clockTime = System.getClockTime();
        var offset = clockTime.timeZoneOffset; // Offset in seconds (e.g. -14400 for EDT)
        return targetMoment.value() - offset;
    }

    // Load resources
    function onLayout(dc as Dc) as Void {
        setLayout(Rez.Layouts.WatchFace(dc));
        _countdownFont = WatchUi.loadResource(Rez.Fonts.tiny_countdown_font);
    }

    // Called when this View is brought to the foreground.
    function onShow() as Void {
        loadStockData();
    }

    // Update the view
    function onUpdate(dc as Dc) as Void {
        // 1. Clear the screen (MIP Monochrome Display uses Black background, White text)
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Fetch activity stats and sensor info once per frame
        var actMonitorInfo = ActivityMonitor.getInfo();
        var activityInfo = Activity.getActivityInfo();

        // 2. Use cached stock data (refreshed only on show, initialization, or background callback)
        var nowSeconds = Time.now().value();
        var ticker = "SNDK";
        var price = null;
        var chartData = null;

        if (_stockData != null) {
            var dict = _stockData as Dictionary;
            if (dict.hasKey("ticker")) { ticker = dict["ticker"] as String; }
            if (dict.hasKey("price")) { price = dict["price"] as Number; }
            if (dict.hasKey("chart")) { chartData = dict["chart"] as Array; }
        }



        // 3. Draw Stock Line Graph (Top-Left Box) or Countdown Timer if market is closed
        // Bounding box: x = 10, y = 16, width = 90, height = 26
        var graphX = 10;
        var graphY = 16;
        var graphW = 90;
        var graphH = 26;

        if (isMarketClosed(nowSeconds)) {
            drawCountdownTimer(dc, nowSeconds);
        } else {
            if (chartData != null && chartData.size() > 0) {
                // Use pre-calculated min/max values
                var minVal = _chartMin != null ? _chartMin : chartData[0];
                var maxVal = _chartMax != null ? _chartMax : chartData[0];
                var valRange = maxVal - minVal;
                if (valRange == 0) { valRange = 1; }

                // Plot the line graph (60 points mapped to 90px width)
                var lastX = graphX + 2;
                var firstValScaled = graphY + graphH - 2 - (((chartData[0] - minVal).toFloat() / valRange.toFloat()) * (graphH - 4));
                var lastY = firstValScaled.toNumber();

                for (var i = 1; i < chartData.size(); i++) {
                    var currentX = graphX + 2 + ((i.toFloat() / (chartData.size() - 1)) * (graphW - 4));
                    var currentYVal = graphY + graphH - 2 - (((chartData[i] - minVal).toFloat() / valRange.toFloat()) * (graphH - 4));
                    var currentY = currentYVal.toNumber();

                    dc.drawLine(lastX.toNumber(), lastY, currentX.toNumber(), currentY);

                    lastX = currentX;
                    lastY = currentY;
                }

                // 4. Draw Min and Max values of the graph at y=40 (Min first, separated by |, no labels, centered around x=52)
                var minString = minVal.format("%d");
                var maxString = maxVal.format("%d");
                var spacing = 6; // Spacing in pixels on each side of the bar '|'

                // Draw the bar '|' centered at exactly x=52
                dc.drawText(
                    52, 
                    40, 
                    Graphics.FONT_TINY, 
                    "|", 
                    Graphics.TEXT_JUSTIFY_CENTER
                );

                // Draw min value right-aligned to the left of the bar
                dc.drawText(
                    52 - spacing, 
                    40, 
                    Graphics.FONT_TINY, 
                    minString, 
                    Graphics.TEXT_JUSTIFY_RIGHT
                );

                // Draw max value left-aligned to the right of the bar
                dc.drawText(
                    52 + spacing, 
                    40, 
                    Graphics.FONT_TINY, 
                    maxString, 
                    Graphics.TEXT_JUSTIFY_LEFT
                );
            }
        }

        // 5. Draw BPM inside the top-right circular subscreen
        var subscreen = (WatchUi has :getSubscreen) ? WatchUi.getSubscreen() : null;
        var subX = 120;
        var subY = 8;
        var subW = 48;
        var subH = 48;

        if (subscreen != null) {
            subX = subscreen.x;
            subY = subscreen.y;
            subW = subscreen.width;
            subH = subscreen.height;
        }

        var subCenterX = subX + (subW / 2);
        var subCenterY = subY + (subH / 2);
        var subRadius = (subW < subH ? subW : subH) / 2;

        // Query Heart Rate
        var heartRate = null;
        if (activityInfo != null && activityInfo.currentHeartRate != null) {
            heartRate = activityInfo.currentHeartRate;
        } else {
            var hrHistory = ActivityMonitor.getHeartRateHistory(1, true);
            if (hrHistory != null) {
                var sample = hrHistory.next();
                if (sample != null && sample.heartRate != ActivityMonitor.INVALID_HR_SAMPLE) {
                    heartRate = sample.heartRate;
                }
            }
        }

        // Draw Heart Rate Value only (no BPM label, maximized font size)
        var hrString = heartRate != null ? heartRate.toString() : "--";
        var hrFont = (heartRate != null) ? Graphics.FONT_NUMBER_MILD : Graphics.FONT_LARGE;

        // Calculate countdown in seconds to the next background stock update (5 minutes = 300 seconds)
        var countdownString = "";
        if (_lastUpdateTime != null && _stockData != null) {
            var diff = (_lastUpdateTime + 300) - nowSeconds;
            if (diff >= 0) {
                countdownString = diff.toString();
            } else {
                countdownString = "0";
            }
        }

        // Draw stock price without decimal in the subscreen (circle) (or "--" if no data/offline)
        var priceIntString = "--";
        var priceFont = Graphics.FONT_LARGE;
        if (price != null) {
            priceIntString = price.toNumber().toString();
            priceFont = Graphics.FONT_NUMBER_MILD;
            if (priceIntString.length() >= 4) {
                priceFont = Graphics.FONT_LARGE;
            }
        }
        
        // Shift price slightly up to make room for the countdown text below it
        dc.drawText(
            subCenterX, 
            subCenterY - 6, 
            priceFont, 
            priceIntString, 
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
        
        // Draw the countdown to the next update (in seconds) below the price (only when market is open)
        if (!isMarketClosed(nowSeconds) && countdownString.length() > 0) {
            var font = _countdownFont != null ? _countdownFont : Graphics.FONT_XTINY;
            dc.drawText(
                subCenterX, 
                subCenterY + 12, 
                font, 
                countdownString, 
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
        // 6. Draw central Time display (Always show seconds HH:MM:SS centered, aligned to the baseline/floor)
        var clockTime = System.getClockTime();
        var hours = clockTime.hour;
        var settings = System.getDeviceSettings();
        if (!settings.is24Hour) {
            if (hours > 12) {
                hours = hours - 12;
            } else if (hours == 0) {
                hours = 12;
            }
        }

        var fontHM = Graphics.FONT_NUMBER_THAI_HOT;
        var fontS = Graphics.FONT_LARGE;

        var timeH = hours.format("%02d");
        var colon = ":";
        var timeM = clockTime.min.format("%02d");
        var timeS = Lang.format(":$1$", [clockTime.sec.format("%02d")]);

        var widthH = dc.getTextWidthInPixels(timeH, fontHM);
        var widthColon = dc.getTextWidthInPixels(colon, fontS);
        var widthM = dc.getTextWidthInPixels(timeM, fontHM);
        var widthS = dc.getTextWidthInPixels(timeS, fontS);

        var startX = 12;

        var heightHM = dc.getFontHeight(fontHM);
        var heightS = dc.getFontHeight(fontS);

        // Center the combined block vertically at y = 96 (shifted down to be well below the circle bottom)
        var yHM = 96 - (heightHM / 2);
        // Align colon and seconds to the bottom (floor) of hours/minutes
        var yS = yHM + heightHM - heightS;

        // Draw hours
        dc.drawText(
            startX, 
            yHM, 
            fontHM, 
            timeH, 
            Graphics.TEXT_JUSTIFY_LEFT
        );
        // Draw colon
        dc.drawText(
            startX + widthH, 
            yS, 
            fontS, 
            colon, 
            Graphics.TEXT_JUSTIFY_LEFT
        );
        // Draw minutes
        dc.drawText(
            startX + widthH + widthColon, 
            yHM, 
            fontHM, 
            timeM, 
            Graphics.TEXT_JUSTIFY_LEFT
        );
        // Draw seconds
        dc.drawText(
            startX + widthH + widthColon + widthM, 
            yS, 
            fontS, 
            timeS, 
            Graphics.TEXT_JUSTIFY_LEFT
        );

        // 6a. Draw Battery Progress Bar at y=67, from x=12 to x=116 using thin style
        var systemStats = System.getSystemStats();
        var battery = (systemStats != null && systemStats.battery != null) ? systemStats.battery : 0.0;
        var batteryRatio = battery / 100.0;
        if (batteryRatio > 1.0) { batteryRatio = 1.0; }
        if (batteryRatio < 0.0) { batteryRatio = 0.0; }

        var batX1 = 12;
        var batX2 = 116;
        var batWidth = batX2 - batX1; // 104 pixels
        var batY = 67;

        // Draw background slim line when empty (1 pixel high line)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(batX1, batY, batX2, batY);

        // Draw thick progress line when loading (4 pixels high, centered at y=67 spanning y=65 to y=68 inclusive)
        var batFillWidth = (batteryRatio * batWidth).toNumber();
        if (batFillWidth > 0) {
            dc.fillRectangle(batX1, batY - 2, batFillWidth, 4);
        }

        // 6b. Draw Step Progress Bar at y=70, from x=12 to x=116
        var stepsForBar = 0;
        var stepGoalForBar = 5000;
        if (actMonitorInfo != null) {
            if (actMonitorInfo.steps != null) { stepsForBar = actMonitorInfo.steps; }
            if (actMonitorInfo.stepGoal != null) { stepGoalForBar = actMonitorInfo.stepGoal; }
        }
        if (stepGoalForBar <= 0) { stepGoalForBar = 5000; }

        var barX1 = 12;
        var barX2 = 163;
        var barWidth = barX2 - barX1; // 151 pixels
        var barY = 126;

        // Draw background slim line when empty (1 pixel high line)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(barX1, barY, barX2, barY);

        // Draw thick progress line when loading (4 pixels high, centered at y=126 spanning y=124 to y=127 inclusive)
        var fillWidth = 0;
        if (stepsForBar >= stepGoalForBar) {
            fillWidth = barWidth;
        } else if (stepsForBar > 0) {
            fillWidth = (stepsForBar * barWidth) / stepGoalForBar;
        }

        if (fillWidth > 0) {
            dc.fillRectangle(barX1, barY - 2, fillWidth, 4);
        }

        // 7. Draw Steps, Altitude & BPM (Side-by-Side, values only, evenly distributed at y=140)
        // Steps (Left Third at x=30)
        var steps = 0;
        if (actMonitorInfo != null && actMonitorInfo.steps != null) {
            steps = actMonitorInfo.steps;
        }

        dc.drawText(
            30, 
            140, 
            Graphics.FONT_TINY, 
            steps.toString(), 
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Altitude (Middle Third at x=88, forced to meters, value in FONT_TINY, unit M custom drawn)
        var altitude = 0.0;
        if (activityInfo != null && activityInfo.altitude != null) {
            altitude = activityInfo.altitude;
        }
        var altValueString = altitude.format("%d");

        var fontVal = Graphics.FONT_TINY;
        var widthVal = dc.getTextWidthInPixels(altValueString, fontVal);
        var widthUnit = 5; // Custom M is 5 pixels wide
        var gap = 2; // 2 pixels gap
        var totalAltWidth = widthVal + gap + widthUnit;
        var altStartX = 88 - (totalAltWidth / 2);

        // Draw altitude value
        dc.drawText(
            altStartX, 
            140, 
            fontVal, 
            altValueString, 
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Custom draw capital 'M' (width 5, height 6, aligned to the baseline/floor of the number font)
        var x0 = altStartX + widthVal + gap;
        var fontHeight = dc.getFontHeight(fontVal);
        var floorY = 140 + (fontHeight / 2) - 2; // Align to visual floor of FONT_TINY
        var y0 = floorY - 5;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x0, y0, x0, y0 + 5);                 // Left vertical bar
        dc.drawLine(x0 + 4, y0, x0 + 4, y0 + 5);         // Right vertical bar
        dc.drawLine(x0, y0, x0 + 2, y0 + 3);             // Left diagonal
        dc.drawLine(x0 + 4, y0, x0 + 2, y0 + 3);         // Right diagonal

        // BPM (Right Third at x=146)
        dc.drawText(
            146, 
            140, 
            Graphics.FONT_TINY, 
            hrString, 
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // 8. Draw Date string (Bottom Center, forced to Uppercase, including Day, Date, Month)
        var now = Time.now();
        var dateInfo = Gregorian.info(now, Time.FORMAT_MEDIUM);
        var dateString = Lang.format("$1$ $2$ $3$", [dateInfo.day_of_week, dateInfo.day, dateInfo.month]).toUpper();

        dc.drawText(
            88, 
            164, 
            Graphics.FONT_TINY, 
            dateString, 
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );


    }

    // Called when this View is removed from the screen.
    function onHide() as Void {
    }

    // Entering low power mode
    function onEnterSleep() as Void {
        _isLowPower = true;
        WatchUi.requestUpdate();
    }

    // Exiting low power mode
    function onExitSleep() as Void {
        _isLowPower = false;
        WatchUi.requestUpdate();
    }
}
