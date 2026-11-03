import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'db.dart';
import 'models.dart';

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
    final cred = await _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
    await cred.user!.updateDisplayName(name.trim());
    await ensureProfile(cred.user!, name: name.trim(), phone: phone.trim());
    try {
      await cred.user!.sendEmailVerification();
    } catch (_) {}
    await Db.audit('register', 'auth', {'method': 'password'});
  }

  /// Returns false if the user cancelled the Google account picker.
  static Future<bool> signInGoogle() async {
    final account = await _google.signIn();
    if (account == null) return false;
    final auth = await account.authentication;
    final credential = GoogleAuthProvider.credential(accessToken: auth.accessToken, idToken: auth.idToken);
    final res = await _auth.signInWithCredential(credential);
    await ensureProfile(res.user!, name: account.displayName ?? res.user!.displayName ?? '');
    await Db.audit('login', 'auth', {'method': 'google'});
    return true;
  }

  static Future<void> resetPassword(String email) => _auth.sendPasswordResetEmail(email: email.trim());

  static Future<void> signOut() async {
    await Db.audit('logout', 'auth');
    try {
      await _google.signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  /// Creates the Firestore profile on first login. The very first account in
  /// a fresh project becomes Administrator (bootstrap); all later accounts
  /// start as Field Workers until an administrator changes their role.
  static Future<void> ensureProfile(User u, {String? name, String? phone}) async {
    final ref = Db.col('users').doc(u.uid);
    final existing = await ref.get();
    if (existing.exists) return;
    final base = {
      'name': (name != null && name.isNotEmpty) ? name : (u.displayName ?? u.email?.split('@').first ?? 'User'),
      'email': u.email ?? '',
      'phone': phone ?? u.phoneNumber ?? '',
      'status': 'active',
      'employeeId': '',
      'category': '',
      'hasLogin': true,
      'synthetic': false,
      'createdAt': Timestamp.now(),
    };
    final boot = await Db.col('meta').doc('bootstrap').get();
    if (!boot.exists) {
      try {
        final b = Db.fs.batch();
        b.set(Db.col('meta').doc('bootstrap'), {'adminUid': u.uid, 'createdAt': Timestamp.now()});
        b.set(ref, {...base, 'role': Roles.admin});
        await b.commit();
        await Db.audit('bootstrap_admin', 'users/${u.uid}');
        return;
      } catch (_) {
        // someone else bootstrapped first – fall through to worker
      }
    }
    await ref.set({...base, 'role': Roles.worker});
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
