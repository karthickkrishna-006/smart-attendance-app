/// Name and phone typed on the registration form (or taken from the Google
/// account), waiting for that account's profile to be created.
///
/// Stored per normalised e-mail address, so when sign-ins of different
/// accounts overlap, one account's details can never be written into another
/// account's profile. Each entry is used once and expires after [ttl].
class PendingDetails {
  PendingDetails({this.ttl = const Duration(minutes: 10), DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, ({String name, String phone, DateTime at})> _byEmail = {};

  static String _key(String? email) => (email ?? '').trim().toLowerCase();

  int get length => _byEmail.length;

  void remember(String? email, String name, String phone) {
    final key = _key(email);
    if (key.isEmpty) return;
    _byEmail[key] = (name: name, phone: phone, at: _now());
  }

  void forget(String? email) => _byEmail.remove(_key(email));

  /// Returns and removes the details stored for exactly this e-mail address.
  ({String name, String phone})? take(String? email) {
    final now = _now();
    _byEmail.removeWhere((_, v) => now.difference(v.at) > ttl);
    final key = _key(email);
    if (key.isEmpty) return null;
    final v = _byEmail.remove(key);
    return v == null ? null : (name: v.name, phone: v.phone);
  }
}
