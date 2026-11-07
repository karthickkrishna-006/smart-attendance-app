import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Navigator for the whole app, so a message can appear after the screen that
/// triggered it has closed.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

enum ToastKind { info, success, error }

OverlayEntry? _toast;

/// A short message that slides in at the top of the screen. Tap to close.
void showToast(String message, {ToastKind kind = ToastKind.info}) {
  final overlay = appNavigatorKey.currentState?.overlay;
  if (overlay == null) return;
  _toast?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: message,
      kind: kind,
      onDone: () {
        if (_toast == entry) _toast = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _toast = entry;
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({required this.message, required this.kind, required this.onDone});
  final String message;
  final ToastKind kind;
  final VoidCallback onDone;
  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration(seconds: widget.kind == ToastKind.error ? 6 : 3), _close);
  }

  Future<void> _close() async {
    _timer?.cancel();
    if (mounted) await _c.reverse();
    widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (widget.kind) {
      ToastKind.success => (AppColors.success, Icons.check_circle),
      ToastKind.error => (AppColors.danger, Icons.error),
      ToastKind.info => (AppColors.indigo, Icons.info),
    };
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -1), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Semantics(
              liveRegion: true,
              child: Material(
                color: Colors.white,
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _close,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border(left: BorderSide(color: color, width: 5)),
                    ),
                    child: Row(children: [
                      Icon(icon, color: color),
                      const SizedBox(width: 10),
                      Expanded(child: Text(widget.message, style: const TextStyle(color: AppColors.ink, fontSize: 15))),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The signature element: every screen states whose data it shows.
class ScopeChip extends StatelessWidget {
  const ScopeChip({super.key, required this.labels, required this.emptyText, this.dark = false});

  final List<String> labels;
  final String emptyText;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : AppColors.green;
    final text = labels.isEmpty ? emptyText : labels.join('\n');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.14) : const Color(0xFFE3EFE9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.place_outlined, size: 18, color: fg),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14))),
      ]),
    );
  }
}

/// A full-screen message with one clear next step.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.title, this.body, this.actions = const []});

  final IconData icon;
  final String title;
  final String? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(icon, size: 56, color: AppColors.green),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink)),
              if (body != null) ...[
                const SizedBox(height: 10),
                Text(body!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: AppColors.muted, height: 1.4)),
              ],
              if (actions.isNotEmpty) const SizedBox(height: 24),
              for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: a),
            ]),
          ),
        ),
      );
}

/// Shown in sections that arrive in the next build stage, so nothing pretends
/// to work before it does.
class NotYetBuilt extends StatelessWidget {
  const NotYetBuilt({super.key, required this.title, required this.text, required this.icon});
  final String title;
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => MessageView(icon: icon, title: title, body: text);
}
