import 'package:flutter_test/flutter_test.dart';
import 'package:ui/platform/launch_at_login.dart';

void main() {
  test('macAppBundlePath resolves app bundle from executable', () {
    expect(
      macAppBundlePath('/Applications/calf.app/Contents/MacOS/ui'),
      '/Applications/calf.app',
    );
    expect(
      macAppBundlePath(
        '/Users/demo/build/macos/Build/Products/Debug/calf.app/Contents/MacOS/ui',
      ),
      '/Users/demo/build/macos/Build/Products/Debug/calf.app',
    );
    expect(macAppBundlePath('/usr/local/bin/calf'), isNull);
  });
}
