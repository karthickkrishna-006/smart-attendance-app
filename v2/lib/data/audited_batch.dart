import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// A write batch whose privileged writes each carry their own audit entry.
///
/// The security rules refuse a role, registration, configuration or
/// master-data write unless the same batch creates a NEW `auditLog` entry by
/// the same person naming that exact document. [stamp] creates that entry and
/// returns the fields to merge into the write.
class AuditedBatch {
  AuditedBatch(this.db, this.user) : batch = db.batch();

  final FirebaseFirestore db;
  final User user;
  final WriteBatch batch;

  Map<String, dynamic> stamp(String action, String target, {String details = ''}) {
    final entry = db.collection('auditLog').doc();
    batch.set(entry, {
      'actorUid': user.uid,
      'actorEmail': user.email,
      'action': action,
      'target': target,
      'details': details,
      'at': FieldValue.serverTimestamp(),
    });
    return {'auditId': entry.id};
  }

  /// An audit entry with a given id (used for deletions, whose id the rules derive).
  void stampWithId(String id, String action, String target, {String details = ''}) {
    batch.set(db.collection('auditLog').doc(id), {
      'actorUid': user.uid,
      'actorEmail': user.email,
      'action': action,
      'target': target,
      'details': details,
      'at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> commit() => batch.commit();
}

/// A single audit entry outside a privileged write (for example a sign-in).
/// Best effort: a failure here never blocks the person.
Future<void> logEvent(FirebaseFirestore db, User user, String action, String target, {String details = ''}) async {
  try {
    await db.collection('auditLog').add({
      'actorUid': user.uid,
      'actorEmail': user.email,
      'action': action,
      'target': target,
      'details': details,
      'at': FieldValue.serverTimestamp(),
    });
  } catch (_) {}
}
