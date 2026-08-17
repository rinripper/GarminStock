import Toybox.System;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;

// Momentum indicator thresholds (tunable). Direction comes from price, strength from volume.
(:background)
const MOVE_FLAT_THRESH = 0.0015; // <0.15% price change over the window => flat (bar)
(:background)
const MOVE_STRONG_PX   = 0.007;  // >=0.7% price change => strong move (double arrow)
(:background)
const MOVE_STRONG_VOL  = 1.8;    // recent volume >=1.8x session avg => strong move
(:background)
const MOVE_LOOKBACK    = 10;     // bars (~minutes) back to measure the price change

(:background)
class GarminStockServiceDelegate extends System.ServiceDelegate {

    function initialize() {
        ServiceDelegate.initialize();
    }

    // Triggered when the temporal event fires (at least every 5 minutes)
    function onTemporalEvent() as Void {
        System.println("onTemporalEvent started");
        var ticker = "SNDK";

        var now = Toybox.Time.now().value();
        var then = now - 3600; // 3600 seconds = 60 minutes

        // Make asynchronous web request to Yahoo Finance (using 1m interval for the last 60 minutes)
        Communications.makeWebRequest(
            "https://query1.finance.yahoo.com/v8/finance/chart/" + ticker + "?interval=1m&period1=" + then + "&period2=" + now + "&includePrePost=true",
            {},
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onWebResponse)
        );
        System.println("makeWebRequest sent");
    }

    // Callback when web request returns
    function onWebResponse(responseCode as Lang.Number, data as Null or Lang.Dictionary or Lang.String) as Void {
        System.println("onWebResponse called, responseCode: " + responseCode);
        if (responseCode == 200 && data != null) {
            System.println("Data is not null, parsing...");
            var dict = data as Dictionary;
            var chartObj = dict.get("chart") as Dictionary;
            if (chartObj != null) {
                var resultArr = chartObj.get("result") as Array;
                if (resultArr != null && resultArr.size() > 0) {
                    var result = resultArr[0] as Dictionary;
                    if (result != null) {
                        var meta = result.get("meta") as Dictionary;
                        var indicators = result.get("indicators") as Dictionary;
                        
                        var price = 1824;
                        if (meta != null) {
                            var rawPrice = null;
                            if (meta.hasKey("postMarketPrice")) {
                                rawPrice = meta.get("postMarketPrice");
                            }
                            if (rawPrice == null && meta.hasKey("preMarketPrice")) {
                                rawPrice = meta.get("preMarketPrice");
                            }
                            if (rawPrice == null && meta.hasKey("regularMarketPrice")) {
                                rawPrice = meta.get("regularMarketPrice");
                            }
                            if (rawPrice != null) {
                                price = (rawPrice as Number or Float or Double).toNumber();
                            }
                        }
                        System.println("Parsed price: " + price);
                        
                        var chartData = null;
                        var volData = null;
                        var lastValidIndex = -1;
                        if (indicators != null) {
                            var quoteArr = indicators.get("quote") as Array;
                            if (quoteArr != null && quoteArr.size() > 0) {
                                var quote = quoteArr[0] as Dictionary;
                                if (quote != null) {
                                    var closeArr = quote.get("close") as Array;
                                    var volArr = quote.get("volume") as Array;
                                    if (closeArr != null) {
                                        // Filter nulls and convert to integer array (cap at 60 points)
                                        chartData = [];
                                        volData = [];
                                        for (var i = 0; i < closeArr.size() && chartData.size() < 60; i++) {
                                            var val = closeArr[i] as Number or Float or Double or Null;
                                            if (val != null) {
                                                chartData.add(val.toNumber());
                                                var vv = (volArr != null && i < volArr.size()) ? volArr[i] : null;
                                                volData.add(vv == null ? 0 : (vv as Number or Float or Double).toNumber());
                                                lastValidIndex = i;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Momentum state (-2..2): direction from price change, strength from volume surge
                        var moveState = 0;
                        if (chartData != null && chartData.size() >= 3) {
                            var n = chartData.size();
                            var lastPx = chartData[n - 1];
                            var refIdx = n - 1 - MOVE_LOOKBACK;
                            if (refIdx < 0) { refIdx = 0; }
                            var refPx = chartData[refIdx];
                            var pxDelta = 0.0;
                            if (refPx != 0) { pxDelta = (lastPx - refPx).toFloat() / refPx.toFloat(); }
                            var volRatio = computeVolRatio(volData);
                            if (pxDelta >= MOVE_FLAT_THRESH) {
                                moveState = 1;
                                if (pxDelta >= MOVE_STRONG_PX || (volRatio != null && volRatio >= MOVE_STRONG_VOL)) { moveState = 2; }
                            } else if (pxDelta <= -MOVE_FLAT_THRESH) {
                                moveState = -1;
                                if (pxDelta <= -MOVE_STRONG_PX || (volRatio != null && volRatio >= MOVE_STRONG_VOL)) { moveState = -2; }
                            }
                        }
                        if (chartData != null) {
                            System.println("Parsed chart data points: " + chartData.size());
                        } else {
                            System.println("Chart data is null");
                        }

                        var lastTimestamp = null;
                        if (lastValidIndex != -1 && result.hasKey("timestamp")) {
                            var tsArr = result.get("timestamp") as Array;
                            if (tsArr != null && lastValidIndex < tsArr.size()) {
                                lastTimestamp = tsArr[lastValidIndex] as Number;
                            }
                        }
                        System.println("Parsed last timestamp: " + lastTimestamp);
                        
                        var tickerSymbol = "SNDK";
                        if (meta != null && meta.hasKey("symbol")) {
                            var sym = meta.get("symbol");
                            if (sym != null) {
                                tickerSymbol = sym as String;
                            }
                        }
                        
                        // Parse regular trading period start and post-market end timestamps
                        var regularStart = null;
                        var postEnd = null;
                        if (meta != null && meta.hasKey("currentTradingPeriod")) {
                            var currentTradingPeriod = meta.get("currentTradingPeriod") as Dictionary;
                            if (currentTradingPeriod != null) {
                                if (currentTradingPeriod.hasKey("regular")) {
                                    var regular = currentTradingPeriod.get("regular") as Dictionary;
                                    if (regular != null && regular.hasKey("start")) {
                                        regularStart = regular.get("start") as Number;
                                    }
                                }
                                if (currentTradingPeriod.hasKey("post")) {
                                    var post = currentTradingPeriod.get("post") as Dictionary;
                                    if (post != null && post.hasKey("end")) {
                                        postEnd = post.get("end") as Number;
                                    }
                                }
                            }
                        }
                        System.println("Parsed regularStart: " + regularStart + ", postEnd: " + postEnd);
                        
                        // Use the last element of the chart as the latest price (includes pre/post-market updates)
                        if (chartData != null && chartData.size() > 0) {
                            price = chartData[chartData.size() - 1];
                            System.println("Updated price from chart last point: " + price);
                        }

                        // If chart data is empty or too short, fill/pad it to 60 points
                        if (chartData != null && chartData.size() > 0) {
                            if (chartData.size() < 60) {
                                var origSize = chartData.size();
                                var lastVal = chartData[origSize - 1];
                                for (var i = origSize; i < 60; i++) {
                                    chartData.add(lastVal);
                                }
                            }
                        } else {
                            chartData = null;
                        }

                        var returnData = {
                            "price" => price,
                            "chart" => chartData,
                            "ticker" => tickerSymbol,
                            "time" => lastTimestamp,
                            "reg_start" => regularStart,
                            "post_end" => postEnd,
                            "move" => moveState
                        };

                        Background.exit(returnData);
                        return;
                    }
                }
            }
        }
        
        System.println("Exiting background with null (error)");
        // Exit with null on network or parsing error to clear cache and display empty state
        Background.exit(null);
    }

    // Ratio of recent (last ~5 valid bars) volume to the session average. Null if insufficient data
    // (e.g. pre/post-market where Yahoo reports 0 volume on the 1-minute feed).
    function computeVolRatio(volData as Array or Null) as Float or Null {
        if (volData == null) { return null; }
        var valid = [];
        for (var i = 0; i < volData.size(); i++) {
            var v = volData[i];
            if (v != null && v > 0) { valid.add(v); }
        }
        if (valid.size() < 6) { return null; }
        var total = 0.0;
        for (var i = 0; i < valid.size(); i++) { total += valid[i].toFloat(); }
        var base = total / valid.size();
        if (base <= 0) { return null; }
        var rc = 5;
        if (rc > valid.size()) { rc = valid.size(); }
        var rTotal = 0.0;
        for (var i = valid.size() - rc; i < valid.size(); i++) { rTotal += valid[i].toFloat(); }
        var recent = rTotal / rc;
        return recent / base;
    }
}
