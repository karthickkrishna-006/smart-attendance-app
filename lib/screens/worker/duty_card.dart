import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/fmt.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';
import '../../services/tracking_service.dart';
import '../common/route_screen.dart';

/// Start / stop field duty, with live totals for the running session.
class DutyCard extends StatefulWidget {
  final AppUser me;
  const DutyCard({super.key, required this.me});
  @override
  State<DutyCard> createState() => _DutyCardState();
}

class _DutyCardState extends State<DutyCard> {
  Timer? _tick;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Refresh the elapsed time shown on the card.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && TrackingService.onDuty) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.share_location, color: AppColors.navy, size: 36),
        title: const Text('Start field duty?'),
        content: const Text(
          'While you are on duty, the app records your location every few minutes '
          '(or when you move about 50 m) to show your work route, even when the phone is locked.\n\n'
          '• Android shows a "Field duty in progress" notification while recording, if notifications are allowed for this app.\n'
          '• Recording stops when you tap Stop duty, check out or sign out.\n'
          '• Only you, your supervisor and administrators can see your route.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('I agree, start')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    // Ask for notification permission and wait for the real answer.
    final notificationsOn = await TrackingService.requestNotificationPermission();
    if (!mounted) return;
    if (!notificationsOn) {
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.notifications_off_outlined, color: AppColors.warning, size: 36),
          title: const Text('Notifications are turned off'),
          content: const Text(
            'Android may not show the "Field duty in progress" notification, so you might not see '
            'that your location is being recorded.\n\n'
            'Your location will still be recorded while you are on duty. You can always see it on this '
            'screen and stop it here.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, 'settings'), child: const Text('Open settings')),
            TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'start'), child: const Text('Start anyway')),
          ],
        ),
      );
      if (choice == 'settings') await LocationService.openAppSettings();
      if (choice != 'start' || !mounted) return;
    }

    setState(() => _busy = true);
    try {
      await TrackingService.startDuty(widget.me);
      if (mounted) {
        showSnack(
          context,
          notificationsOn
              ? 'Field duty started. Your route is being recorded.'
              : 'Field duty started without a notification. Your route is being recorded.',
          success: true,
        );
      }
    } on LocationException catch (e) {
      if (!mounted) return;
      showSnack(context, e.message, error: true);
      if (e.openSettings) await LocationService.openSettings();
      if (e.openAppSettings) await LocationService.openAppSettings();
    } catch (e) {
      if (mounted) showSnack(context, 'Could not start duty: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop field duty?'),
        content: const Text('Location recording will stop and today\'s route will be saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Stop duty'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await TrackingService.stopDuty();
      if (mounted) _reportStop(r);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Tells the worker exactly what happened to their route; never claims it
  /// was saved unless the server confirmed it.
  void _reportStop(StopResult r) {
    if (r.sessionClosed == WriteOutcome.failed) {
      showSnack(
        context,
        'Duty stopped on this phone, but the duty record could not be closed on the server'
        '${r.error == null ? '' : ' (${r.error})'}. It will be closed automatically when you next open the app.',
        error: true,
      );
      return;
    }
    if (r.finalPoint == WriteOutcome.failed) {
      showSnack(
        context,
        'Duty stopped, but the final location could not be saved'
        '${r.error == null ? '' : ' (${r.error})'}. The route up to your last saved point is kept.',
        error: true,
      );
      return;
    }
    if (r.failedPoints > 0) {
      showSnack(
        context,
        'Duty stopped. ${r.failedPoints} location point${r.failedPoints == 1 ? '' : 's'} could not be saved; '
        'the rest of your route is kept.',
        error: true,
      );
      return;
    }
    if (r.waitingForInternet) {
      showSnack(
        context,
        'Duty stopped. No internet right now: your route is stored on this phone and will upload '
        'automatically when you are online. Please stay signed in until then.',
      );
      return;
    }
    if (r.finalPoint == WriteOutcome.skipped) {
      showSnack(context, 'Duty stopped. No GPS signal for a final point; your route is saved up to the last point.', success: true);
      return;
    }
    showSnack(context, 'Field duty stopped. Your route was saved.', success: true);
  }

  void _openRoute() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => RouteScreen(me: widget.me, workerUid: widget.me.uid, workerName: widget.me.name)),
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DutyState?>(
      valueListenable: TrackingService.state,
      builder: (context, duty, _) {
        final on = duty != null;
        return Card(
          margin: const EdgeInsets.only(top: 14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (on ? AppColors.success : AppColors.navy).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(on ? Icons.directions_walk : Icons.work_outline, color: on ? AppColors.success : AppColors.navy),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Field duty', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    Text(
                      on ? 'On duty since ${fmtTime(duty.startedAt)} · ${_elapsed(duty.startedAt)}' : 'Not on duty',
                      style: TextStyle(color: on ? AppColors.success : AppColors.muted, fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
                if (on && duty.geoStatus != null) StatusChip(duty.geoStatus!, label: titleCase(duty.geoStatus!)),
              ]),
              if (on) ...[
                const SizedBox(height: 14),
                if (duty.failedPoints > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: [
                      const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${duty.failedPoints} location point${duty.failedPoints == 1 ? '' : 's'} could not be saved.',
                          style: const TextStyle(color: AppColors.danger, fontSize: 12.5),
                        ),
                      ),
                    ]),
                  ),
                Row(children: [
                  _metric('${(duty.distanceM / 1000).toStringAsFixed(2)} km', 'Distance'),
                  _metric('${duty.points}', 'Points saved'),
                  _metric(duty.points == 0 ? '–' : '${(duty.insidePoints * 100 / duty.points).round()}%', 'In my area'),
                ]),
              ] else ...[
                const SizedBox(height: 8),
                const Text(
                  'Start duty when you begin field work. Your route is recorded until you stop.',
                  style: TextStyle(color: AppColors.muted),
                ),
              ],
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openRoute,
                    icon: const Icon(Icons.route_outlined),
                    label: const Text('My route'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: on ? AppColors.danger : AppColors.success,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _busy ? null : (on ? _stop : _start),
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Icon(on ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                    label: Text(on ? 'Stop duty' : 'Start duty'),
                  ),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }

  Widget _metric(String value, String label) => Expanded(
        child: Column(children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ]),
      );

  static String _elapsed(DateTime start) {
    final d = DateTime.now().difference(start);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}
