import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../data/session_controller.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/shell/officer_shell.dart';
import '../features/shell/worker_shell.dart';
import 'strings.dart';
import 'theme.dart';
import 'ui.dart';

/// Two products in one app: the worker app and the officer app. Which one
/// opens is decided by the person's role; what they can read or change is
/// decided by the security rules.
class FieldMonitorApp extends StatefulWidget {
  const FieldMonitorApp({super.key});
  @override
  State<FieldMonitorApp> createState() => _FieldMonitorAppState();
}

class _FieldMonitorAppState extends State<FieldMonitorApp> {
  final session = SessionController()..start();

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) => MaterialApp(
          title: 'Smart Attendance',
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: buildTheme(),
          locale: Locale(session.language),
          supportedLocales: const [Locale('en'), Locale('ta')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // Follow the phone's text size, up to 130 %, so layouts stay usable.
          builder: (context, child) => LanguageScope(
            strings: Strings(session.language),
            child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: child ?? const SizedBox.shrink()),
          ),
          home: _Gate(session: session),
        ),
      );
}

class _Gate extends StatelessWidget {
  const _Gate({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final email = session.user?.email ?? '';
    Widget page;
    switch (session.phase) {
      case SessionPhase.loading:
        page = Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(s.t('loading'))]));
      case SessionPhase.signedOut:
        return SignInScreen(session: session);
      case SessionPhase.ready:
        final role = session.role;
        if (role == null) {
          page = MessageView(icon: Icons.person_off_outlined, title: s.t('notRegisteredTitle'), body: s.t('notRegisteredBody', {'email': email}));
        } else {
          return role.isFieldWorker ? WorkerShell(session: session) : OfficerShell(session: session);
        }
      case SessionPhase.needsEmailVerification:
        page = MessageView(
          icon: Icons.mark_email_unread_outlined,
          title: s.t('notRegisteredTitle'),
          body: s.t('verifyEmailBody', {'email': email}),
          actions: [
            FilledButton(onPressed: session.recheckEmail, child: Text(s.t('checkAgain'))),
            OutlinedButton(onPressed: session.signOut, child: Text(s.t('signOut'))),
          ],
        );
      case SessionPhase.notRegistered:
        page = MessageView(
          icon: Icons.person_search_outlined,
          title: s.t('notRegisteredTitle'),
          body: s.t('notRegisteredBody', {'email': email}),
          actions: [
            FilledButton(onPressed: session.retry, child: Text(s.t('checkAgain'))),
            OutlinedButton(onPressed: session.signOut, child: Text(s.t('signOut'))),
          ],
        );
      case SessionPhase.disabled:
        page = MessageView(
          icon: Icons.block,
          title: s.t('disabledTitle'),
          body: s.t('disabledBody'),
          actions: [OutlinedButton(onPressed: session.signOut, child: Text(s.t('signOut')))],
        );
      case SessionPhase.error:
        page = MessageView(
          icon: Icons.cloud_off_outlined,
          title: s.t('errorTitle'),
          body: session.error,
          actions: [
            FilledButton(onPressed: session.retry, child: Text(s.t('retry'))),
            OutlinedButton(onPressed: session.signOut, child: Text(s.t('signOut'))),
          ],
        );
    }
    return Scaffold(body: SafeArea(child: page));
  }
}
