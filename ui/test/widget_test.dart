import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  Future<List<ImageLayer>> fetchImageLayers(String reference) async => const [
        ImageLayer(index: 0, createdBy: 'CMD ["/hello"]', size: '0 B'),
      ];

  @override
  Future<List<VolumeItem>> fetchVolumes() async => const [
        VolumeItem(name: 'calf-data', driver: 'local', inUse: true, size: '88 B', created: '9 months ago'),
      ];

  @override
  Future<VolumeDetail> fetchVolumeDetail(String name) async => VolumeDetail(
        name: name,
        driver: 'local',
        created: '9 months ago',
        inUse: true,
      );

  @override
  Future<List<ContainerFileEntry>> fetchVolumeFiles(String name, {String path = '/'}) async => const [
        ContainerFileEntry(name: 'app', path: '/app', isDir: true, size: 0, mode: 'drwxr-xr-x', modified: '5 months ago'),
        ContainerFileEntry(name: 'dump.rdb', path: '/dump.rdb', isDir: false, size: 88, mode: '-rw-------', modified: '7 months ago'),
      ];

  @override
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name) async => const [
        VolumeContainerUsage(
          id: 'abc123',
          name: 'hello',
          image: 'hello-world',
          port: '',
          target: '/data',
        ),
      ];

  @override
  Future<List<BuildItem>> fetchBuilds({String? tag}) async => const [];

  @override
  Future<BuildDetail> fetchBuildDetail(String id) async => BuildDetail(
        id: id,
        tag: 'demo',
        context: '.',
        status: 'success',
        createdAt: '2026-01-01T00:00:00Z',
      );

  @override
  Future<BuildSource> fetchBuildSource(String id) async => const BuildSource(
        path: 'Dockerfile',
        filename: 'Dockerfile',
        content: 'FROM alpine',
        platform: 'arm64',
      );

  @override
  Future<BuildLogs> fetchBuildLogs(String id) async => const BuildLogs(
        rawLog: '#1 DONE 0.1s',
        steps: [
          BuildStep(index: 1, total: 1, name: 'load build definition', cached: false, durationMs: 100),
        ],
      );

  @override
  Future<void> startContainer(String id) async {}

  @override
  Future<void> stopContainer(String id) async {}

  @override
  Future<void> removeContainer(String id) async {}

  @override
  Future<void> restartContainer(String id) async {}

  @override
  Future<String> fetchContainerInspect(String id, {String? section}) async => '{"Id":"$id"}';

  @override
  Future<List<ContainerMount>> fetchContainerMounts(String id) async => const [];

  @override
  Future<List<ContainerFileEntry>> fetchContainerFiles(String id, {String path = '/'}) async => const [];

  @override
  Future<ContainerExecResult> execContainer(String id, String command) async => const ContainerExecResult(output: '');

  @override
  Future<ContainerStats> fetchContainerStats(String id) async => const ContainerStats(
        cpuPercent: '0%',
        memUsage: '0B / 0B',
        memPercent: '0%',
        netIo: '0B / 0B',
        blockIo: '0B / 0B',
        pids: '0',
      );

  @override
  Future<void> pullImage(String reference) async {}

  @override
  Future<void> pushImage(String reference) async {}

  @override
  Future<String> runImage(String reference) async => 'mock-container-id';

  @override
  Future<void> removeImage(String reference) async {}

  @override
  Future<void> createVolume(String name) async {}

  @override
  Future<void> cloneVolume(String source, String name) async {}

  @override
  Future<void> removeVolume(String name) async {}

  @override
  Future<BuildItem> runBuild({required String context, required String tag, String dockerfile = ''}) async {
    return BuildItem(
      id: 'build-1',
      tag: tag,
      context: context,
      status: 'success',
      createdAt: '2026-01-01T00:00:00Z',
    );
  }

  @override
  Stream<String> streamContainerLogs(String id) async* {
    yield 'hello';
  }

  @override
  Uri containerLogsWebSocketUri(String id) => Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/logs');

  @override
  Uri containerExecWebSocketUri(String id) => Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/exec');

  @override
  Future<Config> fetchConfig() async => const Config(
        pollIntervalMs: 3000,
        cpus: 4,
        memoryGB: 4,
        memorySwapGB: 1,
        hostCPUs: 8,
        hostMemoryGB: 16,
      );

  @override
  Future<Config> updateConfig(Config config) async => config;

  @override
  Future<MigrationStatus> fetchDockerDesktopMigration() async => const MigrationStatus(
        phase: 'idle',
        step: 'idle',
        progress: 0,
        message: 'Ready to migrate',
        summary: MigrationSummary(
          configApplied: false,
          imagesTotal: 0,
          imagesOK: 0,
          volumesTotal: 0,
          volumesOK: 0,
          containersTotal: 0,
          containersOK: 0,
          buildsTotal: 0,
          buildsOK: 0,
        ),
      );

  @override
  Future<MigrationStatus> startDockerDesktopMigration() async => const MigrationStatus(
        phase: 'completed',
        step: 'done',
        progress: 100,
        message: 'Migration completed',
        summary: MigrationSummary(
          configApplied: true,
          imagesTotal: 1,
          imagesOK: 1,
          volumesTotal: 0,
          volumesOK: 0,
          containersTotal: 0,
          containersOK: 0,
          buildsTotal: 0,
          buildsOK: 0,
        ),
      );

  @override
  Future<RegistryLoginStatus> fetchRegistryStatus() async =>
      const RegistryLoginStatus(loggedIn: false, server: 'docker.io');

  @override
  Future<RegistryBrowserLoginStart> startRegistryBrowserLogin() async =>
      const RegistryBrowserLoginStart(
        sessionId: 'session-1',
        userCode: 'ABCD-EFGH',
        verificationUrl: 'https://login.docker.com/activate?code=ABCD-EFGH',
        expiresIn: 600,
      );

  @override
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(String sessionId) async =>
      const RegistryBrowserLoginStatus(status: 'complete', username: 'demo');

  @override
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  }) async {}

  @override
  Future<void> logoutRegistry({String server = 'docker.io'}) async {}
}

class _LoggedInCalfClient extends FakeCalfClient {
  _LoggedInCalfClient(super.status);

  @override
  Future<RegistryLoginStatus> fetchRegistryStatus() async =>
      const RegistryLoginStatus(loggedIn: true, server: 'docker.io', username: 'demo');
}

void main() {
  testWidgets('opens containers screen on launch', (tester) async {
    final apiClient = FakeCalfClient(
      DaemonStatus(
        uptimeSeconds: 42,
        listenAddr: ':8765',
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
    expect(find.text('Containers'), findsWidgets);
    expect(find.text('Loading...'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Loading...'), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('opens account dropdown when avatar is tapped', (tester) async {
    final apiClient = _LoggedInCalfClient(
      DaemonStatus(
        uptimeSeconds: 42,
        listenAddr: ':8765',
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
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsNothing);
    await tester.tap(find.byIcon(LucideIcons.chevronDown));
    await tester.pumpAndSettle();

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Account Settings'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('shows error when containers fetch fails', (tester) async {
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
    return const DaemonStatus(
      uptimeSeconds: 0,
      listenAddr: ':8765',
      logLevel: 'info',
      runtime: RuntimeStatus(
        mode: 'vm',
        state: 'stopped',
        dockerSocket: '/tmp/calf.sock',
      ),
    );
  }

  @override
  Future<List<ContainerItem>> fetchContainers() async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<List<ImageItem>> fetchImages() async => [];

  @override
  Future<List<ImageLayer>> fetchImageLayers(String reference) async => [];

  @override
  Future<List<VolumeItem>> fetchVolumes() async => [];

  @override
  Future<VolumeDetail> fetchVolumeDetail(String name) async => VolumeDetail(
        name: name,
        driver: 'local',
        created: '',
        inUse: false,
      );

  @override
  Future<List<ContainerFileEntry>> fetchVolumeFiles(String name, {String path = '/'}) async => const [];

  @override
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name) async => const [];

  @override
  Future<List<BuildItem>> fetchBuilds({String? tag}) async => [];

  @override
  Future<BuildDetail> fetchBuildDetail(String id) async => BuildDetail(
        id: id,
        tag: 'demo',
        context: '.',
        status: 'success',
        createdAt: '2026-01-01T00:00:00Z',
      );

  @override
  Future<BuildSource> fetchBuildSource(String id) async => const BuildSource(
        path: 'Dockerfile',
        filename: 'Dockerfile',
        content: 'FROM alpine',
        platform: 'arm64',
      );

  @override
  Future<BuildLogs> fetchBuildLogs(String id) async => const BuildLogs(
        rawLog: '#1 DONE 0.1s',
        steps: [
          BuildStep(index: 1, total: 1, name: 'load build definition', cached: false, durationMs: 100),
        ],
      );

  @override
  Future<void> startContainer(String id) async {}

  @override
  Future<void> stopContainer(String id) async {}

  @override
  Future<void> removeContainer(String id) async {}

  @override
  Future<void> restartContainer(String id) async {}

  @override
  Future<String> fetchContainerInspect(String id, {String? section}) async => '{"Id":"$id"}';

  @override
  Future<List<ContainerMount>> fetchContainerMounts(String id) async => const [];

  @override
  Future<List<ContainerFileEntry>> fetchContainerFiles(String id, {String path = '/'}) async => const [];

  @override
  Future<ContainerExecResult> execContainer(String id, String command) async => const ContainerExecResult(output: '');

  @override
  Future<ContainerStats> fetchContainerStats(String id) async => const ContainerStats(
        cpuPercent: '0%',
        memUsage: '0B / 0B',
        memPercent: '0%',
        netIo: '0B / 0B',
        blockIo: '0B / 0B',
        pids: '0',
      );

  @override
  Future<void> pullImage(String reference) async {}

  @override
  Future<void> pushImage(String reference) async {}

  @override
  Future<String> runImage(String reference) async => 'mock-container-id';

  @override
  Future<void> removeImage(String reference) async {}

  @override
  Future<void> createVolume(String name) async {}

  @override
  Future<void> cloneVolume(String source, String name) async {}

  @override
  Future<void> removeVolume(String name) async {}

  @override
  Future<BuildItem> runBuild({required String context, required String tag, String dockerfile = ''}) async {
    return BuildItem(
      id: 'build-1',
      tag: tag,
      context: context,
      status: 'success',
      createdAt: '2026-01-01T00:00:00Z',
    );
  }

  @override
  Stream<String> streamContainerLogs(String id) async* {}

  @override
  Uri containerLogsWebSocketUri(String id) => Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/logs');

  @override
  Uri containerExecWebSocketUri(String id) => Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/exec');

  @override
  Future<Config> fetchConfig() async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<Config> updateConfig(Config config) async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<MigrationStatus> fetchDockerDesktopMigration() async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<MigrationStatus> startDockerDesktopMigration() async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<RegistryLoginStatus> fetchRegistryStatus() async =>
      const RegistryLoginStatus(loggedIn: false, server: 'docker.io');

  @override
  Future<RegistryBrowserLoginStart> startRegistryBrowserLogin() async =>
      const RegistryBrowserLoginStart(
        sessionId: 'session-1',
        userCode: 'ABCD-EFGH',
        verificationUrl: 'https://login.docker.com/activate?code=ABCD-EFGH',
        expiresIn: 600,
      );

  @override
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(String sessionId) async =>
      const RegistryBrowserLoginStatus(status: 'complete', username: 'demo');

  @override
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  }) async {}

  @override
  Future<void> logoutRegistry({String server = 'docker.io'}) async {}
}
