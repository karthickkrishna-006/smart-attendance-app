import 'package:field_monitor/app/strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every English text has a Tamil version', () {
    expect(Strings.missingTamil(), <String>[]);
  });

  test('placeholders are filled and unknown keys fall back safely', () {
    expect(const Strings('en').t('hello', {'name': 'Ravi'}), 'Hello, Ravi');
    expect(const Strings('ta').t('hello', {'name': 'Ravi'}), 'வணக்கம், Ravi');
    expect(const Strings('ta').t('no-such-key'), 'no-such-key');
  });
}
