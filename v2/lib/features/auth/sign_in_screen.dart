import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../app/ui.dart';
import '../../data/auth_service.dart';
import '../../data/session_controller.dart';

/// Google first (one big button); e-mail and password behind a link, mainly
/// for staff accounts that are not Gmail.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _showEmail = false;

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      showToast(AuthService.describe(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _withValidForm(Future<void> Function() action) {
    if (_form.currentState?.validate() ?? false) _run(action);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'en', label: Text(s.t('english'))),
                        ButtonSegment(value: 'ta', label: Text(s.t('tamil'))),
                      ],
                      selected: {widget.session.language},
                      onSelectionChanged: (v) => widget.session.setLanguage(v.first),
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Icon(Icons.how_to_reg, size: 56, color: AppColors.green),
                  const SizedBox(height: 12),
                  Text(
                    s.t('appName'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.ink),
                  ),
                  const SizedBox(height: 6),
                  Text(s.t('signInTitle'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: AppColors.muted)),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _run(() => AuthService.signInWithGoogle()),
                    icon: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Icon(Icons.login),
                    label: Text(_busy ? s.t('signingIn') : s.t('signInGoogle')),
                  ),
                  const SizedBox(height: 8),
                  if (!_showEmail)
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _showEmail = true),
                      child: Text(s.t('useEmail')),
                    )
                  else ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: s.t('email')),
                      validator: (v) => _emailPattern.hasMatch((v ?? '').trim()) ? null : s.t('emailInvalid'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(labelText: s.t('password')),
                      validator: (v) => (v ?? '').length >= 8 ? null : s.t('passwordShort'),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : () => _withValidForm(() => AuthService.signInWithEmail(_email.text, _password.text)),
                      child: Text(s.t('signIn')),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _withValidForm(() => AuthService.createEmailAccount(_email.text, _password.text)),
                      child: Text(s.t('createAccount')),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              final email = _email.text.trim();
                              if (!_emailPattern.hasMatch(email)) {
                                showToast(s.t('emailInvalid'), kind: ToastKind.error);
                                return;
                              }
                              _run(() async {
                                await AuthService.sendPasswordReset(email);
                                showToast(s.t('resetSent', {'email': email}), kind: ToastKind.success);
                              });
                            },
                      child: Text(s.t('forgotPassword')),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(s.t('privacyNote'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
