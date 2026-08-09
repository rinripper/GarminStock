import Toybox.System;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;

(:background)
const PUSHOVER_APP_TOKEN = "YOUR_PUSHOVER_APP_TOKEN";
(:background)
const PUSHOVER_USER_KEY  = "YOUR_PUSHOVER_USER_KEY";

(:background)
class GarminStockServiceDelegate extends System.ServiceDelegate {

    private var _pendingSuccessData as Dictionary or Null = null;

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
                        var lastValidIndex = -1;
                        if (indicators != null) {
                            var quoteArr = indicators.get("quote") as Array;
                            if (quoteArr != null && quoteArr.size() > 0) {
                                var quote = quoteArr[0] as Dictionary;
                                if (quote != null) {
                                    var closeArr = quote.get("close") as Array;
                                    if (closeArr != null) {
                                        // Filter nulls and convert to integer array (cap at 60 points)
                                        chartData = [];
                                        for (var i = 0; i < closeArr.size() && chartData.size() < 60; i++) {
                                            var val = closeArr[i] as Number or Float or Double or Null;
                                            if (val != null) {
                                                chartData.add(val.toNumber());
                                                lastValidIndex = i;
                                            }
                                        }
                                    }
                                }
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
                            "post_end" => postEnd
                        };

                        // Compare the new price to the chart bounds of the preceding points to detect a breakout
                        var sentPush = false;
                        if (price != null && chartData != null && chartData.size() > 1) {
                            var prevMin = (chartData as Array<Number>)[0];
                            var prevMax = (chartData as Array<Number>)[0];
                            for (var i = 1; i < chartData.size() - 1; i++) {
                                var val = (chartData as Array<Number>)[i];
                                if (val != null) {
                                    if (prevMin == null || val < prevMin) { prevMin = val; }
                                    if (prevMax == null || val > prevMax) { prevMax = val; }
                                }
                            }
                            
                            if (prevMin != null && prevMax != null) {
                                if (price > prevMax) {
                                    _pendingSuccessData = returnData;
                                    sentPush = sendPushNotification("New high: " + price);
                                } else if (price < prevMin) {
                                    _pendingSuccessData = returnData;
                                    sentPush = sendPushNotification("New low: " + price);
                                }
                            }
                        }

                        if (!sentPush) {
                            System.println("Exiting background with success data");
                            Background.exit(returnData);
                        }
                        return;
                    }
                }
            }
        }
        
        System.println("Exiting background with null (error)");
        // Exit with null on network or parsing error to clear cache and display empty state
        Background.exit(null);
    }

    function sendPushNotification(message as String) as Boolean {
        if (PUSHOVER_APP_TOKEN.equals("your_pushover_app_token_here") || PUSHOVER_USER_KEY.equals("your_pushover_user_key_here")) {
            System.println("Pushover credentials not configured; skipping push notification.");
            return false;
        }

        var url = "https://api.pushover.net/1/messages.json";
        var params = {
            "token" => PUSHOVER_APP_TOKEN,
            "user" => PUSHOVER_USER_KEY,
            "message" => message,
            "title" => "Garmin Stock Alert",
            "priority" => 1
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_URL_ENCODED
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        Communications.makeWebRequest(
            url,
            params,
            options,
            method(:onPushResponse)
        );
        return true;
    }

    function onPushResponse(responseCode as Number, data as Dictionary or Null) as Void {
        System.println("Push notification response code: " + responseCode);
        // Now that the web request has completed, exit the background process with success data
        Background.exit(_pendingSuccessData);
    }
}
