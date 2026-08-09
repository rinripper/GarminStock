import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.System;
import Toybox.Background;
import Toybox.Time;

(:background)
class GarminStockApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
    }

    // Return the initial view of your application here
    private var _view as GarminStockView or Null = null;

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        // Register background service temporal events if supported
        if (System has :ServiceDelegate) {
            var stockData = Application.Storage.getValue("stock_data");
            if (stockData == null) {
                // First run: schedule immediately
                Background.registerForTemporalEvent(new Time.Duration(5 * 60));
            }
        }
        _view = new GarminStockView();
        return [ _view ];
    }

    // Return the service delegate object to handle background events
    function getServiceDelegate() as [System.ServiceDelegate] {
        return [ new GarminStockServiceDelegate() ];
    }

    // Return the view to show when a goal is completed
    function getGoalView(goal) {
        if (goal == Application.GOAL_TYPE_STEPS) {
            return [ new GarminStockGoalView() ];
        }
        return null;
    }

    // Handle data returned from the background ServiceDelegate
    function onBackgroundData(data) as Void {
        System.println("onBackgroundData called with data: " + data);
        Application.Storage.setValue("stock_data", data);
        Application.Storage.setValue("last_update_time", Time.now().value());
        
        if (_view != null) {
            _view.handleBackgroundUpdate(data);
        }

        // Dynamically adjust the background schedule to save battery
        adjustBackgroundSchedule(data);
        
        // Force the screen to redraw immediately
        WatchUi.requestUpdate();
    }

    function adjustBackgroundSchedule(data) as Void {
        if (System has :ServiceDelegate) {
            var regStart = null;
            var postEnd = null;
            if (data != null) {
                var dict = data as Dictionary;
                if (dict.hasKey("reg_start")) { regStart = dict["reg_start"] as Number; }
                if (dict.hasKey("post_end")) { postEnd = dict["post_end"] as Number; }
            }

            var now = Time.now().value();
            var nextPremarket = null;
            if (regStart != null) {
                nextPremarket = regStart - 19800; // 5.5 hours before regular open (4:00 AM EDT)
            }

            // Determine if the market is currently active (including overnight)
            var isMarketActive = false;
            if (regStart != null && postEnd != null) {
                var overnightStart = regStart - 48600; // 13.5 hours before regular open
                if (now >= overnightStart && now <= postEnd) {
                    isMarketActive = true;
                }
            }

            if (!isMarketActive && nextPremarket != null && nextPremarket > now) {
                var delay = nextPremarket - now;
                if (delay > 300) {
                    System.println("Market is closed. Sleeping background delegate for " + delay + " seconds until next pre-market open.");
                    Background.registerForTemporalEvent(new Time.Duration(delay));
                    return;
                }
            }

            // Fallback/standard: poll every 5 minutes (300 seconds)
            System.println("Market is active or next session is soon. Scheduling next check in 5 minutes.");
            Background.registerForTemporalEvent(new Time.Duration(5 * 60));
        }
    }
}

class GarminStockGoalView extends WatchUi.View {
    function initialize() {
        View.initialize();
    }
    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() / 2 + 20,
            Graphics.FONT_MEDIUM,
            "GOAL ACHIEVED!",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }
}

function getApp() as GarminStockApp {
    return Application.getApp() as GarminStockApp;
}
