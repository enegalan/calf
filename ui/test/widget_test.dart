import 'package:flutter_test/flutter_test.dart';

import 'package:ui/api/client.dart';
import 'package:ui/main.dart';

class FakeStatusClient implements StatusClient {
  FakeStatusClient(this.status);

  final DaemonStatus status;

  @override
  Future<DaemonStatus> fetchStatus() async => status;
}

void main() {
  testWidgets('shows loading then loaded daemon status', (tester) async {
    final apiClient = FakeStatusClient(
      const DaemonStatus(
        version: '0.1.0',
        uptimeSeconds: 42,
        listenAddr: ':8080',
        logLevel: 'info',
      ),
    );

    await tester.pumpWidget(MainApp(apiClient: apiClient));
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Daemon status'), findsOneWidget);
    expect(find.text('Loading...'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Loading...'), findsNothing);
    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('42s'), findsOneWidget);
  });

  testWidgets('shows error when status fetch fails', (tester) async {
    final apiClient = _ErrorStatusClient();

    await tester.pumpWidget(MainApp(apiClient: apiClient));
    await tester.pump();
    expect(find.text('Loading...'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Loading...'), findsNothing);
    expect(find.text('daemon unavailable'), findsOneWidget);
  });
}

class _ErrorStatusClient implements StatusClient {
  @override
  Future<DaemonStatus> fetchStatus() async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }
}
