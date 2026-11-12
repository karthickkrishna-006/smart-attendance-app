import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Configuration comes from android/app/google-services.json.
  await Firebase.initializeApp();
  // In release builds Flutter shows a failed widget as an empty grey box.
  // Show a readable message instead, so problems can be reported and fixed.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFFFFF4E5),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Text('This part of the screen could not be shown. Please send a screenshot to support.\n\n'
                '${details.exceptionAsString()}', style: const TextStyle(color: Color(0xFF7A4B00), fontSize: 13)),
          ),
        ),
      );
  runApp(const FieldMonitorApp());
}
