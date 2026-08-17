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
        // Keep the last good price instead of reverting. Once after-hours ends (8pm ET) a fresh poll
        // comes back either with an empty extended-hours window ("time" == null) or the regular 4pm
        // close (an older timestamp). In both cases we retain the last after-hours price; a genuinely
        // newer bar (e.g. next day's pre-market) has a newer timestamp and is accepted normally.
        var accept = true;
        if (data != null) {
            var dict = data as Dictionary;
            var newTime = dict.hasKey("time") ? dict.get("time") : null;
            var oldData = Application.Storage.getValue("stock_data");
            var oldTime = null;
            if (oldData != null) {
                var od = oldData as Dictionary;
                if (od.hasKey("time")) { oldTime = od.get("time"); }
            }
            if (newTime == null) {
                accept = (oldData == null);
            } else if (oldTime != null && (newTime as Number) < (oldTime as Number)) {
                accept = false;
            }
        }

        if (accept) {
            Application.Storage.setValue("stock_data", data);
            Application.Storage.setValue("last_update_time", Time.now().value());
            if (_view != null) {
                _view.handleBackgroundUpdate(data);
            }
        }

        // Dynamically adjust the background schedule to save battery
        adjustBackgroundSchedule(data);

        // Force the screen to redraw immediately
        WatchUi.requestUpdate();
    }

    function adjustBackgroundSchedule(data) as Void {
        if (!(System has :ServiceDelegate)) { return; }

        var regStart = null;
        var postEnd = null;
        if (data != null) {
            var dict = data as Dictionary;
            if (dict.hasKey("reg_start")) { regStart = dict["reg_start"] as Number; }
            if (dict.hasKey("post_end")) { postEnd = dict["post_end"] as Number; }
        }

        var now = Time.now().value();

        // Without trading-period metadata we can't tell open from closed: keep the 5-minute cadence.
        if (regStart == null || postEnd == null) {
            Background.registerForTemporalEvent(new Time.Duration(5 * 60));
            return;
        }

        // A stock's active window is pre-market open (~4:00 AM ET = regular open - 5.5h) through
        // post-market end (8:00 PM ET), so pre-market AND after-hours keep polling. Yahoo's
        // currentTradingPeriod already points at the next *real* trading day, so weekends and holidays
        // are skipped automatically — we only compare absolute epoch times here, no local-timezone
        // calendar math (which would break when the watch is not set to Eastern time).
        var activeStart = regStart - 19800;

        if (now >= activeStart && now <= postEnd) {
            // Pre-market, regular, or after-hours: poll every 5 minutes.
            Background.registerForTemporalEvent(new Time.Duration(5 * 60));
        } else if (now < activeStart) {
            // Closed, and the metadata already points at the upcoming session: sleep straight through
            // until pre-market open — zero network calls overnight, over weekends, and on holidays.
            var delay = activeStart - now;
            if (delay < 300) { delay = 300; }
            Background.registerForTemporalEvent(new Time.Duration(delay));
        } else {
            // now > postEnd: after-hours just ended but Yahoo hasn't rolled currentTradingPeriod to the
            // next session yet. Re-check in an hour; once it rolls, the branch above sleeps to next open.
            Background.registerForTemporalEvent(new Time.Duration(3600));
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
