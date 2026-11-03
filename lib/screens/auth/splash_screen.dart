import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'auth_gate.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..forward();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1900), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, __, ___) => const AuthGate(),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ));
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.navyDark, AppColors.navy, Color(0xFF1B5E7A)],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            const Spacer(flex: 3),
            ScaleTransition(
              scale: CurvedAnimation(parent: _c, curve: Curves.elasticOut),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset('assets/images/logo.png', width: 116, height: 116),
              ),
            ),
            const SizedBox(height: 28),
            FadeTransition(
              opacity: CurvedAnimation(parent: _c, curve: const Interval(0.4, 1)),
              child: const Column(children: [
                Text('Smart Attendance',
                    style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                SizedBox(height: 6),
                Text('AI-Enabled Field Activity Monitoring',
                    style: TextStyle(color: Colors.white70, fontSize: 15)),
              ]),
            ),
            const Spacer(flex: 3),
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.teal)),
            const SizedBox(height: 26),
            const Text('Rural Development · Chengalpattu District', style: TextStyle(color: Colors.white60, fontSize: 12.5)),
            const SizedBox(height: 18),
          ]),
        ),
      ),
    );
  }
}
