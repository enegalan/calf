import 'package:flutter_test/flutter_test.dart';

import 'package:ui/main.dart';

void main() {
  testWidgets('shows status screen on launch', (tester) async {
    await tester.pumpWidget(const MainApp());
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Daemon status'), findsOneWidget);
    expect(find.text('Loading...'), findsOneWidget);
  });
}
