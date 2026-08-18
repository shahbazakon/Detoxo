import 'package:detoxo/core/utils/package_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts real application-id shapes', () {
    expect(isValidPackageName('com.instagram.android'), isTrue);
    expect(isValidPackageName('com.Slack'), isTrue); // real, mixed-case
    expect(isValidPackageName('com.my_app.v2'), isTrue);
  });

  test('rejects what could never match a foreground package', () {
    expect(isValidPackageName(''), isFalse);
    expect(isValidPackageName('instagram'), isFalse); // no dot
    expect(isValidPackageName('my bank'), isFalse); // space
    expect(isValidPackageName('com..app'), isFalse); // empty segment
    expect(isValidPackageName('com.1app'), isFalse); // digit-led segment
    expect(isValidPackageName('.com.app'), isFalse);
    expect(isValidPackageName('com.app.'), isFalse);
    expect(isValidPackageName('com.${'a' * 300}'), isFalse); // over length cap
  });
}
