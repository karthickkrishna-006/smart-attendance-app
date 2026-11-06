import 'package:flutter_test/flutter_test.dart';
import 'package:smartattendance/services/pending_details.dart';

void main() {
  test('overlapping sign-ins never swap registration details', () {
    final p = PendingDetails();
    p.remember('Asha@Example.com ', 'Asha', '9000000001'); // worker A registering
    p.remember('ravi@gmail.com', 'Ravi K', ''); // worker B signs in meanwhile
    expect(p.take('ravi@gmail.com'), (name: 'Ravi K', phone: ''));
    expect(p.take('asha@example.com'), (name: 'Asha', phone: '9000000001'));
    expect(p.take('asha@example.com'), isNull, reason: 'details are used once');
  });

  test('details are only used for the same e-mail address', () {
    final p = PendingDetails()..remember('d@x.com', 'D', '2');
    expect(p.take(null), isNull);
    expect(p.take(''), isNull);
    expect(p.take('other@x.com'), isNull);
    expect(p.take('D@X.com'), (name: 'D', phone: '2'));
  });

  test('a failed registration leaves nothing behind', () {
    final p = PendingDetails()..remember('c@x.com', 'C', '1');
    p.forget('C@X.COM');
    expect(p.length, 0);
  });

  test('old details expire', () {
    var now = DateTime(2026, 1, 1, 9);
    final p = PendingDetails(clock: () => now)..remember('e@x.com', 'E', '3');
    now = now.add(const Duration(minutes: 11));
    expect(p.take('e@x.com'), isNull);
  });
}
