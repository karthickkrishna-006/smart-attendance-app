import 'package:flutter/material.dart';
import '../../core/ui.dart';
import '../../services/auth_service.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _busy = false;
  bool _consent = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_consent) {
      showSnack(context, 'Please accept the location and face data consent to continue.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.register(_name.text, _email.text, _pass.text, _phone.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showSnack(context, AuthService.errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create account',
      subtitle: 'Register with email & password',
      back: true,
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline)),
            validator: (v) => (v ?? '').trim().length < 3 ? 'Enter your full name' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
            validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Mobile number', prefixIcon: Icon(Icons.phone_outlined)),
            validator: (v) => RegExp(r'^[0-9+ ]{10,14}$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid mobile number',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
            validator: (v) {
              final s = v ?? '';
              if (s.length < 8) return 'Use at least 8 characters';
              if (!RegExp(r'[0-9]').hasMatch(s) || !RegExp(r'[A-Za-z]').hasMatch(s)) return 'Use letters and numbers';
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pass2,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Confirm password', prefixIcon: Icon(Icons.lock_outline)),
            validator: (v) => v != _pass.text ? 'Passwords do not match' : null,
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _consent,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (v) => setState(() => _consent = v ?? false),
            title: const Text(
              'I consent to processing of my location and face image for attendance verification as per project policy.',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Create account'),
          ),
          const SizedBox(height: 10),
          const Text(
            'New accounts start as Field Worker. An administrator assigns Supervisor/Admin roles.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
      ),
    );
  }
}
