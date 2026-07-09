import 'package:flutter_test/flutter_test.dart';
import 'package:ui/platform/launch_at_login.dart';

void main() {
  test('macAppBundlePath resolves app bundle from executable', () {
    expect(
      macAppBundlePath('/Applications/Calf.app/Contents/MacOS/ui'),
      '/Applications/Calf.app',
    );
    expect(
      macAppBundlePath('/Users/demo/build/macos/Build/Products/Debug/Calf.app/Contents/MacOS/ui'),
      '/Users/demo/build/macos/Build/Products/Debug/Calf.app',
    );
    expect(macAppBundlePath('/usr/local/bin/calf'), isNull);
  });
}
