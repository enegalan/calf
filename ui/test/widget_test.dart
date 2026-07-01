import 'package:flutter_test/flutter_test.dart';
import 'package:ui/main.dart';

void main() {
  testWidgets('shows loading state on launch', (tester) async {
    await tester.pumpWidget(const MainApp());
    expect(find.text('Loading...'), findsOneWidget);
  });
}
