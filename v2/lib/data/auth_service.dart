import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Sign-in with Google (main path) or e-mail and password (mainly staff).
/// Signing in grants nothing by itself: access comes from role assignments,
/// checked by the security rules.
class AuthService {
  AuthService._();

  static final _auth = FirebaseAuth.instance;
  static final _google = GoogleSignIn(scopes: const ['email']);

  static Stream<User?> changes() => _auth.authStateChanges();
  static User? get current => _auth.currentUser;

  /// Returns false if the person closed the Google account picker.
  static Future<bool> signInWithGoogle() async {
    final account = await _google.signIn();
    if (account == null) return false;
    final auth = await account.authentication;
    if (auth.idToken == null) {
      throw const AuthMessage('Google did not return a sign-in token. Check the app\'s SHA-1 fingerprint in Firebase.');
    }
    await _auth.signInWithCredential(GoogleAuthProvider.credential(idToken: auth.idToken, accessToken: auth.accessToken));
    return true;
  }

  static Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email.trim(), password: password);

  /// Creates an e-mail account and sends the confirmation link. Access still
  /// needs a pre-registration (or open sign-up) and a confirmed address.
  static Future<void> createEmailAccount(String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
    await cred.user?.sendEmailVerification();
  }

  static Future<void> sendPasswordReset(String email) => _auth.sendPasswordResetEmail(email: email.trim());

  /// Reloads the user so a just-confirmed e-mail address is seen, and refreshes
  /// the sign-in token the security rules read.
  static Future<void> refresh() async {
    await _auth.currentUser?.reload();
    await _auth.currentUser?.getIdToken(true);
  }

  static Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (_) {
      // Not signed in with Google.
    }
    await _auth.signOut();
  }

  /// Plain-language message for a sign-in failure.
  static String describe(Object e) {
    if (e is AuthMessage) return e.text;
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'invalid-credential':
        case 'wrong-password':
        case 'user-not-found':
          return 'The email or password is not correct.';
        case 'email-already-in-use':
          return 'An account with this email already exists. Sign in instead.';
        case 'weak-password':
          return 'Choose a longer password (at least 8 characters).';
        case 'network-request-failed':
          return 'No internet connection. Try again when you are online.';
        case 'too-many-requests':
          return 'Too many attempts. Wait a few minutes and try again.';
      }
      return e.message ?? e.code;
    }
    final s = e.toString();
    if (s.contains('ApiException: 10')) {
      return 'Google sign-in is not set up for this app build (SHA-1 fingerprint missing in Firebase).';
    }
    if (s.contains('network_error')) return 'No internet connection. Try again when you are online.';
    return s;
  }
}

class AuthMessage implements Exception {
  const AuthMessage(this.text);
  final String text;
  @override
  String toString() => text;
}
