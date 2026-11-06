import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'db.dart';
import 'models.dart';
import 'pending_details.dart';
import 'tracking_service.dart';

/// Firebase Authentication: Google Sign-In, email/password, registration,
/// password reset, logout. Roles are stored in Firestore `users/{uid}`.
class AuthService {
  static final _auth = FirebaseAuth.instance;
  static final _google = GoogleSignIn(scopes: ['email', 'profile']);

  static Stream<User?> get changes => _auth.authStateChanges();
  static User? get current => _auth.currentUser;

  static Future<void> signInEmail(String email, String password) async {
    await _auth.signInWithEmailAndPassword(email: email.trim(), password: password);
    await Db.audit('login', 'auth', {'method': 'password'});
  }

  static Future<void> register(String name, String email, String password, String phone) async {
    // Remember the form details BEFORE the account exists: creating the
    // account immediately notifies AuthGate, which also calls ensureProfile.
    // Both calls share one operation (see _inFlight), so the details typed in
    // the form are used whichever call starts first. They are stored under
    // this e-mail address, so they can only ever be used for this account.
    _rememberDetails(email, name.trim(), phone.trim());
    final UserCredential cred;
    try {
      cred = await _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
    } catch (_) {
      _forgetDetails(email);
      rethrow;
    }
    try {
      await cred.user!.updateDisplayName(name.trim());
    } catch (_) {}
    await ensureProfile(cred.user!, name: name.trim(), phone: phone.trim());
    try {
      await cred.user!.sendEmailVerification();
    } catch (_) {}
    await Db.audit('register', 'auth', {'method': 'password'});
  }

  /// Returns false if the user cancelled the Google account picker.
  static Future<bool> signInGoogle() async {
    final GoogleSignInAccount? account;
    try {
      account = await _google.signIn();
    } catch (e) {
      // Logs only the error code (e.g. ApiException: 10 = SHA-1 not registered).
      debugPrint('[google-signin-diagnostic] step=account_picker error=$e');
      rethrow;
    }
    if (account == null) return false;
    final auth = await account.authentication;
    if (auth.idToken == null) {
      debugPrint('[google-signin-diagnostic] step=token idToken=null');
      throw 'Google Sign-In did not return an ID token. The Web client ID may be missing from google-services.json.';
    }
    final credential = GoogleAuthProvider.credential(accessToken: auth.accessToken, idToken: auth.idToken);
    _rememberDetails(account.email, account.displayName ?? '', '');
    final UserCredential res;
    try {
      res = await _auth.signInWithCredential(credential);
    } catch (_) {
      _forgetDetails(account.email);
      rethrow;
    }
    // AuthGate starts ensureProfile as soon as the sign-in above completes;
    // this call joins that same operation instead of racing it.
    await ensureProfile(res.user!, name: account.displayName ?? res.user!.displayName ?? '');
    await Db.audit('login', 'auth', {'method': 'google'});
    return true;
  }

  static Future<void> resetPassword(String email) => _auth.sendPasswordResetEmail(email: email.trim());

  static Future<void> signOut() async {
    // End field duty while the database can still be written.
    if (TrackingService.onDuty) {
      try {
        await TrackingService.stopDuty(reason: 'signed_out');
      } catch (_) {}
    }
    await Db.audit('logout', 'auth');
    try {
      await _google.signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  /// Creates the Firestore profile on first login.
  ///
  /// Security model (enforced by firestore.rules, not by this code):
  ///  * Every new account is a Field Worker with status `active`, so workers
  ///    can use the app immediately (no approval step). Workers can only ever
  ///    see their own data; administrators can suspend an account at any time.
  ///  * Accounts created earlier as `pending_approval` activate themselves on
  ///    their next sign-in. Accounts an admin set to inactive/suspended stay
  ///    blocked.
  ///  * Only the single e-mail address configured as `bootstrapAdminEmail()`
  ///    in firestore.rules, with a VERIFIED e-mail, can claim the initial
  ///    Administrator role – and only once (meta/bootstrap is write-once).
  /// The client simply attempts the bootstrap; the rules reject it for
  /// everyone else, and the account stays a worker.
  static Future<void> ensureProfile(User u, {String? name, String? phone}) {
    // Single-flight: concurrent callers for the same user share one Future.
    // Previously the sign-in code and AuthGate both created the profile at
    // the same time; the security rules rejected the second write, so a
    // brand-new worker saw "permission denied" or a login screen that closed.
    final running = _inFlight[u.uid];
    if (running != null) return running;
    // Only details typed for THIS account's e-mail address are used.
    final details = _takeDetails(u.email);
    final f = () async {
      try {
        await _ensureProfile(
          u,
          name: (name != null && name.isNotEmpty) ? name : details?.name,
          phone: (phone != null && phone.isNotEmpty) ? phone : details?.phone,
        );
      } catch (_) {
        // Keep the details for a retry of the same account.
        if (details != null) _rememberDetails(u.email, details.name, details.phone);
        rethrow;
      } finally {
        _inFlight.remove(u.uid);
      }
    }();
    _inFlight[u.uid] = f;
    return f;
  }

  static final Map<String, Future<void>> _inFlight = {};

  /// Details waiting for their own account's profile (see PendingDetails).
  static final PendingDetails _pending = PendingDetails();
  static void _rememberDetails(String? email, String name, String phone) => _pending.remember(email, name, phone);
  static void _forgetDetails(String? email) => _pending.forget(email);
  static ({String name, String phone})? _takeDetails(String? email) => _pending.take(email);

  static Future<void> _ensureProfile(User u, {String? name, String? phone}) async {
    final ref = Db.col('users').doc(u.uid);
    var operation = 'read';
    Map<String, dynamic> profile(String status) => {
          'name': (name != null && name.isNotEmpty) ? name : (u.displayName ?? u.email?.split('@').first ?? 'User'),
          'email': u.email ?? '',
          'phone': phone ?? u.phoneNumber ?? '',
          'role': Roles.worker,
          'status': status,
          'employeeId': '',
          'category': '',
          'hasLogin': true,
          'synthetic': false,
          'faceEnrolled': false,
          'createdAt': FieldValue.serverTimestamp(),
        };
    try {
      final existing = await ref.get();
      if (!existing.exists) {
        operation = 'create';
        try {
          await ref.set(profile('active'));
        } on FirebaseException catch (e) {
          // Security rules published before immediate access was enabled only
          // accept a pending account. Fall back so registration still works;
          // the account activates itself once the new rules are published.
          if (e.code != 'permission-denied' || await _profileExists(ref)) rethrow;
          operation = 'create_pending';
          await ref.set(profile('pending_approval'));
        }
      }
    } catch (error) {
      logProfileFailure(u, operation, error);
      final createdElsewhere = operation.startsWith('create') &&
          error is FirebaseException &&
          error.code == 'permission-denied' &&
          await _profileExists(ref);
      if (!createdElsewhere) rethrow;
    }
    await _activateLegacyPending(ref);
    await _tryBootstrapAdmin(u);
  }

  /// A Field Worker account still marked `pending_approval` (created before
  /// the approval step was removed) switches itself to `active`. The rules
  /// allow only this exact change; inactive/suspended accounts stay blocked.
  static Future<void> _activateLegacyPending(DocumentReference<Map<String, dynamic>> ref) async {
    try {
      final data = (await ref.get()).data();
      if (data == null || data['role'] != Roles.worker || data['status'] != 'pending_approval') return;
      await ref.update({'status': 'active'});
      await Db.audit('self_activated', 'users/${ref.id}');
    } catch (_) {
      // Older security rules still deployed: the account stays pending.
    }
  }

  static Future<bool> _profileExists(DocumentReference<Map<String, dynamic>> ref) async {
    try {
      return (await ref.get(const GetOptions(source: Source.server))).exists;
    } catch (_) {
      return false;
    }
  }

  /// Logs only non-secret context needed to diagnose profile access failures.
  /// The UID is included because it is also the profile document ID.
  static void logProfileFailure(User u, String operation, Object error) {
    final projectId = Firebase.app().options.projectId;
    final errorCode = error is FirebaseException ? error.code : error.runtimeType.toString();
    debugPrint(
      '[profile-diagnostic] operation=$operation projectId=$projectId uid=${u.uid} '
      'documentPath=users/${u.uid} errorCode=$errorCode',
    );
  }

  static Future<void> _tryBootstrapAdmin(User u) async {
    try {
      await u.reload();
      final fresh = FirebaseAuth.instance.currentUser ?? u;
      if (!fresh.emailVerified) return; // rules also require email_verified == true
      await fresh.getIdToken(true); // refresh token so the email_verified claim is current
      final boot = await Db.col('meta').doc('bootstrap').get();
      if (boot.exists) return;
      final b = Db.fs.batch();
      b.update(Db.col('users').doc(u.uid), {'role': Roles.admin, 'status': 'active'});
      b.set(Db.col('meta').doc('bootstrap'), {'adminUid': u.uid, 'createdAt': FieldValue.serverTimestamp()});
      await b.commit();
      await Db.audit('bootstrap_admin', 'users/${u.uid}');
    } catch (_) {
      // Not the authorised bootstrap e-mail (or already bootstrapped): stays a worker.
    }
  }

  static String errorText(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'invalid-email':
          return 'The email address is not valid.';
        case 'user-disabled':
          return 'This account has been disabled.';
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'Incorrect email or password.';
        case 'email-already-in-use':
          return 'An account already exists with this email. Try signing in.';
        case 'weak-password':
          return 'Password is too weak (use at least 6 characters).';
        case 'network-request-failed':
          return 'No internet connection. Please check your network.';
        case 'too-many-requests':
          return 'Too many attempts. Please wait a moment and try again.';
        case 'account-exists-with-different-credential':
          return 'This email is already registered with a different sign-in method.';
        default:
          return e.message ?? e.code;
      }
    }
    final s = e.toString();
    if (s.contains('ApiException: 10')) {
      return 'Google Sign-In configuration error (code 10): the app signing SHA-1 is not registered in Firebase.';
    }
    if (s.contains('ApiException: 7') || s.contains('network_error')) {
      return 'Network error during Google Sign-In. Check your internet connection.';
    }
    if (s.contains('ApiException: 12500')) {
      return 'Google Sign-In failed (12500). Update Google Play services and set a support email in Firebase.';
    }
    return s;
  }
}
