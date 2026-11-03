import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

/// Evidence images are stored in Cloud Storage for Firebase at
///   evidence/{uid}/{activityId}/{index}.jpg
/// Firestore keeps only these object paths (never image bytes).
/// storage.rules: only the owner can upload (JPEG, < 1.5 MB) to their own
/// folder; the owner and admin/supervisor/auditor can read; nobody can
/// overwrite or delete (tamper-evident evidence).
///
/// BILLING: since Oct 2024 new Cloud Storage buckets require the Firebase
/// Blaze (pay-as-you-go) plan. The no-cost usage quota still applies on
/// Blaze, but a billing account must be linked. Enable the feature in
/// Settings only after the bucket exists.
class EvidenceStorage {
  static const maxBytes = 1500 * 1024;

  static String path(String uid, String activityId, int index) => 'evidence/$uid/$activityId/$index.jpg';

  static Future<String> upload(String uid, String activityId, int index, Uint8List jpeg) async {
    if (jpeg.length > maxBytes) throw 'Image larger than 1.5 MB after compression';
    final p = path(uid, activityId, index);
    await FirebaseStorage.instance.ref(p).putData(jpeg, SettableMetadata(contentType: 'image/jpeg'));
    return p;
  }

  /// Reads through the SDK (security rules are enforced on every read).
  /// Public download URLs are deliberately NOT used, because they are bearer
  /// links that bypass the rules.
  static Future<Uint8List?> read(String path) => FirebaseStorage.instance.ref(path).getData(maxBytes);

  static String errorText(Object e) {
    final s = e.toString();
    if (s.contains('bucket') || s.contains('object-not-found') || s.contains('project-not-found')) {
      return 'Cloud Storage bucket not found. Photo evidence needs Firebase Storage (Blaze plan) – see docs/STORAGE.md.';
    }
    if (s.contains('unauthorized') || s.contains('permission')) {
      return 'Not allowed by storage security rules (publish storage.rules).';
    }
    return s;
  }
}

/// Displays an evidence image fetched with rule-checked SDK access.
class StorageImage extends StatelessWidget {
  final String path;
  final double size;
  const StorageImage(this.path, {super.key, this.size = 90});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: FutureBuilder<Uint8List?>(
          future: EvidenceStorage.read(path),
          builder: (context, s) {
            if (s.hasError) return const ColoredBox(color: Color(0xFFEFF2F6), child: Icon(Icons.lock_outline));
            if (!s.hasData) return const ColoredBox(color: Color(0xFFEFF2F6), child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))));
            return Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true);
          },
        ),
      ),
    );
  }
}
