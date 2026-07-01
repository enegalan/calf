import 'package:flutter_test/flutter_test.dart';

import 'package:ui/api/client.dart';
import 'package:ui/main.dart';

class FakeCalfClient implements CalfClient {
  FakeCalfClient(this.status);

  final DaemonStatus status;

  @override
  Future<DaemonStatus> fetchStatus() async => status;

  @override
  Future<List<ContainerItem>> fetchContainers() async => const [
        ContainerItem(
          id: 'abc123',
          name: 'hello',
          image: 'hello-world',
          state: 'running',
          status: 'Up',
        ),
      ];

  @override
  Future<List<ImageItem>> fetchImages() async => const [
        ImageItem(
          id: 'img1',
          repository: 'hello-world',
          tag: 'latest',
          size: '10MB',
        ),
      ];

  @override
  Future<void> startContainer(String id) async {}

  @override
  Future<void> stopContainer(String id) async {}

  @override
  Future<void> removeContainer(String id) async {}

  @override
  Future<void> pullImage(String reference) async {}

  @override
  Future<void> removeImage(String reference) async {}

  @override
  Stream<String> streamContainerLogs(String id) async* {
    yield 'hello';
  }
}

void main() {
  testWidgets('shows loading then loaded daemon status', (tester) async {
    final apiClient = FakeCalfClient(
      DaemonStatus(
        version: '0.3.0',
        uptimeSeconds: 42,
        listenAddr: ':8080',
        logLevel: 'info',
        runtime: const RuntimeStatus(
          mode: 'vm',
          state: 'running',
          dockerSocket: '/tmp/calf.sock',
          vmName: 'calf',
        ),
      ),
    );

    await tester.pumpWidget(MainApp(apiClient: apiClient));
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Daemon status'), findsOneWidget);
    expect(find.text('Loading...'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Loading...'), findsNothing);
    expect(find.text('0.3.0'), findsOneWidget);
    expect(find.text('42s'), findsOneWidget);
  });

  testWidgets('shows error when status fetch fails', (tester) async {
    final apiClient = _ErrorCalfClient();

    await tester.pumpWidget(MainApp(apiClient: apiClient));
    await tester.pump();
    expect(find.text('Loading...'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Loading...'), findsNothing);
    expect(find.text('daemon unavailable'), findsOneWidget);
  });
}

class _ErrorCalfClient implements CalfClient {
  @override
  Future<DaemonStatus> fetchStatus() async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<List<ContainerItem>> fetchContainers() async => [];

  @override
  Future<List<ImageItem>> fetchImages() async => [];

  @override
  Future<void> startContainer(String id) async {}

  @override
  Future<void> stopContainer(String id) async {}

  @override
  Future<void> removeContainer(String id) async {}

  @override
  Future<void> pullImage(String reference) async {}

  @override
  Future<void> removeImage(String reference) async {}

  @override
  Stream<String> streamContainerLogs(String id) async* {}
}
