import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/auth_service.dart';
import '../../services/db.dart';
import '../../services/location_service.dart';
import '../../services/models.dart';
import '../shell.dart';
import 'login_screen.dart';

/// Routes the user based on Firebase Auth state and their Firestore profile.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.changes,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const Scaffold(body: LoadingView());
        final user = snap.data;
        if (user == null) {
          LiveTracker.stop();
          return const LoginScreen();
        }
        return _ProfileGate(user: user, key: ValueKey(user.uid));
      },
    );
  }
}

class _ProfileGate extends StatefulWidget {
  final User user;
  const _ProfileGate({super.key, required this.user});
  @override
  State<_ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<_ProfileGate> {
  late Future<void> _ensure = AuthService.ensureProfile(widget.user);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _ensure,
      builder: (context, f) {
        if (f.connectionState != ConnectionState.done) {
          return const Scaffold(body: LoadingView(label: 'Preparing your workspace…'));
        }
        if (f.hasError) {
          return Scaffold(
            body: ErrorView(
              message: 'Could not load your profile.\n${friendlyError(f.error!)}',
              onRetry: () => setState(() => _ensure = AuthService.ensureProfile(widget.user)),
            ),
            floatingActionButton: TextButton(onPressed: AuthService.signOut, child: const Text('Sign out')),
          );
        }
        return StreamBuilder(
          stream: Db.col('users').doc(widget.user.uid).snapshots(),
          builder: (context, s) {
            if (s.hasError) {
              AuthService.logProfileFailure(widget.user, 'listen', s.error!);
              return Scaffold(body: ErrorView(message: friendlyError(s.error!)));
            }
            if (!s.hasData) return const Scaffold(body: LoadingView());
            final doc = s.data!;
            if (!doc.exists) return const Scaffold(body: LoadingView(label: 'Creating profile…'));
            final me = AppUser(doc.id, doc.data()!);
            if (me.status != 'active') return _Blocked(me: me);
            return Shell(me: me);
          },
        );
      },
    );
  }
}

class _Blocked extends StatelessWidget {
  final AppUser me;
  const _Blocked({required this.me});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(me.status == 'pending_approval' ? Icons.hourglass_top : Icons.lock_person_outlined, size: 64, color: me.status == 'pending_approval' ? AppColors.warning : AppColors.danger),
              const SizedBox(height: 16),
              Text(me.status == 'pending_approval' ? 'Awaiting approval' : 'Account ${me.status}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                me.status == 'pending_approval'
                    ? 'Your account (${me.email}) was created. An administrator or supervisor must approve it and assign your role before you can use the app. This screen updates automatically.'
                    : 'Your account is not active. Please contact your administrator.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: AuthService.signOut, icon: const Icon(Icons.logout), label: const Text('Sign out')),
            ]),
          ),
        ),
      );
}
