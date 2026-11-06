package in.cit.smartattendance;

import android.app.NotificationManager;
import android.content.pm.PackageManager;
import android.os.Build;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "in.cit.smartattendance/permissions";
    private static final String POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS";
    private static final int NOTIFICATION_REQUEST = 4711;

    /** Waiting for the worker's answer to the notification permission dialog. */
    private MethodChannel.Result pendingNotificationResult;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if ("requestNotifications".equals(call.method)) {
                        requestNotifications(result);
                    } else if ("notificationsEnabled".equals(call.method)) {
                        result.success(notificationsEnabled());
                    } else {
                        result.notImplemented();
                    }
                });
    }

    /**
     * Replies true only when this app's notifications can actually be shown.
     * On Android 13+ the system dialog is shown first and the reply is sent
     * only after the worker answers.
     */
    private void requestNotifications(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < 33
                || checkSelfPermission(POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(notificationsEnabled());
            return;
        }
        if (pendingNotificationResult != null) {
            result.error("busy", "A notification permission request is already open.", null);
            return;
        }
        pendingNotificationResult = result;
        requestPermissions(new String[] {POST_NOTIFICATIONS}, NOTIFICATION_REQUEST);
    }

    /** False if the worker switched this app's notifications off in Android settings. */
    private boolean notificationsEnabled() {
        if (Build.VERSION.SDK_INT < 24) return true;
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        return manager == null || manager.areNotificationsEnabled();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != NOTIFICATION_REQUEST || pendingNotificationResult == null) return;
        boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        MethodChannel.Result result = pendingNotificationResult;
        pendingNotificationResult = null;
        result.success(granted && notificationsEnabled());
    }

    @Override
    protected void onDestroy() {
        // Never leave the Dart side waiting forever.
        if (pendingNotificationResult != null) {
            pendingNotificationResult.success(false);
            pendingNotificationResult = null;
        }
        super.onDestroy();
    }
}
