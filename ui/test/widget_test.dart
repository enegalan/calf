import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/main.dart';
import 'package:ui/widgets/app_bottom_bar.dart';
import 'package:ui/widgets/calf_snack_bar.dart';

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
    VolumeItem(
      name: 'calf-data',
      driver: 'local',
      inUse: true,
      size: '88 B',
      created: '9 months ago',
    ),
  ];

  @override
  Future<List<NetworkItem>> fetchNetworks() async => const [
    NetworkItem(
      id: '9d1ce4c80488',
      name: 'bridge',
      driver: 'bridge',
      scope: 'local',
      subnet: '192.168.215.0/24',
    ),
  ];

  @override
  Future<NetworkDetail> fetchNetworkDetail(String name) async => NetworkDetail(
    id: '9d1ce4c80488',
    name: name,
    driver: 'bridge',
    scope: 'local',
    subnet: '192.168.215.0/24',
    gateway: '192.168.215.1',
    created: '9 months ago',
  );

  @override
  Future<VolumeDetail> fetchVolumeDetail(String name) async => VolumeDetail(
    name: name,
    driver: 'local',
    created: '9 months ago',
    inUse: true,
  );

  @override
  Future<List<ContainerFileEntry>> fetchVolumeFiles(
    String name, {
    String path = '/',
  }) async => const [
    ContainerFileEntry(
      name: 'app',
      path: '/app',
      isDir: true,
      size: 0,
      mode: 'drwxr-xr-x',
      modified: '5 months ago',
    ),
    ContainerFileEntry(
      name: 'dump.rdb',
      path: '/dump.rdb',
      isDir: false,
      size: 88,
      mode: '-rw-------',
      modified: '7 months ago',
    ),
      ];

  @override
  Future<void> writeVolumeFile(
    String name,
    String path,
    String content,
  ) async {}

  @override
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name) async =>
      const [
        VolumeContainerUsage(
          id: 'abc123',
          name: 'hello',
          image: 'hello-world',
          port: '',
          target: '/data',
        ),
      ];

  @override
  Future<List<VolumeExportItem>> fetchVolumeExports(String name) async =>
      const [];

  @override
  Future<VolumeExportItem> createVolumeExport({
    required String name,
    required String type,
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async => VolumeExportItem(
    id: 'export-1',
    volume: name,
    type: type,
    status: 'completed',
    createdAt: '2026-01-01T00:00:00Z',
    fileName: fileName,
    filePath: folder,
    imageRef: imageRef,
    downloadable: type == 'local_file',
  );

  @override
  Future<List<int>> downloadVolumeExport(
    String volumeName,
    String exportId,
  ) async => const [1, 2, 3];

  @override
  Future<List<VolumeExportScheduleItem>> fetchVolumeExportSchedules(
    String name,
  ) async => const [];

  @override
  Future<VolumeExportScheduleItem> createVolumeExportSchedule({
    required String name,
    required String type,
    bool enabled = false,
    List<VolumeExportDayTimes> dayTimes = const [],
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async => VolumeExportScheduleItem(
    id: 'schedule-1',
    volume: name,
    enabled: enabled,
    dayTimes: dayTimes,
    type: type,
    nextRunAt: enabled ? '2026-01-02T03:00:00Z' : '',
  );

  @override
  Future<VolumeExportScheduleItem> updateVolumeExportSchedule({
    required String volumeName,
    required String scheduleId,
    bool? enabled,
    List<VolumeExportDayTimes>? dayTimes,
    String type = '',
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async => VolumeExportScheduleItem(
    id: scheduleId,
    volume: volumeName,
    enabled: enabled ?? true,
    dayTimes:
        dayTimes ??
        const [
          VolumeExportDayTimes(day: 1, times: ['03:00']),
        ],
    type: type.isNotEmpty ? type : 'local_file',
  );

  @override
  Future<void> deleteVolumeExportSchedule(
    String volumeName,
    String scheduleId,
  ) async {}

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
      BuildStep(
        index: 1,
        total: 1,
        name: 'load build definition',
        cached: false,
        durationMs: 100,
      ),
    ],
  );

  @override
  Future<List<int>> downloadBuildArtifact(String id, String digest) async =>
      const [123, 125];

  @override
  Future<void> startContainer(String id) async {}

  @override
  Future<void> stopContainer(String id) async {}

  @override
  Future<void> removeContainer(String id) async {}

  @override
  Future<void> restartContainer(String id) async {}

  @override
  Future<void> pauseContainer(String id) async {}

  @override
  Future<void> resumeContainer(String id) async {}

  @override
  Future<String> fetchContainerInspect(String id, {String? section}) async =>
      '{"Id":"$id"}';

  @override
  Future<List<ContainerMount>> fetchContainerMounts(String id) async =>
      const [];

  @override
  Future<List<ContainerFileEntry>> fetchContainerFiles(
    String id, {
    String path = '/',
  }) async => const [];

  @override
  Future<void> writeContainerFile(
    String id,
    String path,
    String content,
  ) async {}

  @override
  Future<ContainerExecResult> execContainer(String id, String command) async =>
      const ContainerExecResult(output: '');

  @override
  Future<ContainerStats> fetchContainerStats(String id) async =>
      const ContainerStats(
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
  Future<String> runImage(
    String reference, {
    String name = '',
    List<String> ports = const [],
    List<String> env = const [],
    List<String> volumes = const [],
  }) async => 'mock-container-id';

  @override
  Future<void> removeImage(String reference) async {}

  @override
  Future<void> createVolume(String name) async {}

  @override
  Future<void> emptyVolume(String name) async {}

  @override
  Future<void> importVolume({
    required String name,
    required String source,
    String filePath = '',
    String imageRef = '',
  }) async {}

  @override
  Future<void> cloneVolume(String source, String name) async {}

  @override
  Future<void> removeVolume(String name) async {}

  @override
  Future<void> removeNetwork(String name) async {}

  @override
  Future<void> createNetwork(
    String name, {
    String driver = '',
    String subnet = '',
  }) async {}

  @override
  Future<BuildItem> runBuild({
    required String context,
    required String tag,
    String dockerfile = '',
    String platform = '',
  }) async {
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
  Uri containerLogsWebSocketUri(String id) =>
      Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/logs');

  @override
  Uri containerExecWebSocketUri(String id) =>
      Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/exec');

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
  Future<Config> updateLogLevel(String logLevel) async =>
      (await fetchConfig()).copyWith(logLevel: logLevel);

  @override
  Future<DaemonLogs> fetchDaemonLogs() async => const DaemonLogs(
    text: 'time=2026-08-14T12:00:00Z level=INFO msg="runtime started"',
    path: '/tmp/calf.log',
  );

  @override
  Future<MigrationStatus> fetchDockerDesktopMigration() async =>
      const MigrationStatus(
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
  Future<MigrationStatus> startDockerDesktopMigration() async =>
      const MigrationStatus(
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
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(
    String sessionId,
  ) async =>
      const RegistryBrowserLoginStatus(status: 'complete', username: 'demo');

  @override
  Future<void> cancelRegistryBrowserLogin(String sessionId) async {}

  @override
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  }) async {}

  @override
  Future<void> logoutRegistry({String server = 'docker.io'}) async {}

  @override
  Future<RuntimeStatus> startRuntime() async => status.runtime;

  @override
  Future<RuntimeStatus> stopRuntime() async => status.runtime;

  @override
  Future<RuntimeStatus> killRuntime() async => status.runtime;

  @override
  Future<void> purgeEngineData() async {}

  @override
  Future<void> factoryReset() async {}

  @override
  Future<PrunePreview> fetchPrunePreview() async => const PrunePreview(
    containers: PruneCategoryPreview(items: []),
    images: PruneCategoryPreview(items: []),
    volumes: PruneCategoryPreview(items: []),
    networks: PruneCategoryPreview(items: []),
    buildCache: PruneCategoryPreview(items: []),
  );

  @override
  Future<PruneResult> prune({
    bool containers = true,
    bool images = true,
    bool volumes = true,
    bool networks = true,
    bool buildCache = true,
  }) async => const PruneResult();

  @override
  Future<void> installDockerCli() async {}

  @override
  Future<List<BuilderInfo>> fetchBuilders() async => const [];

  @override
  Future<void> useBuilder(String name) async {}

  @override
  Future<void> removeBuilder(String name) async {}

  @override
  Future<List<int>> downloadDiagnostics() async => const [];

  @override
  Future<void> copyDiskImage(String path) async {}

  @override
  Future<List<HubRepository>> fetchHubRepositories() async => const [];

  @override
  Uri unifiedLogsWebSocketUri() => Uri.parse('ws://127.0.0.1:8765/v1/logs');
}

class _LoggedInCalfClient extends FakeCalfClient {
  _LoggedInCalfClient(super.status);

  @override
  Future<RegistryLoginStatus> fetchRegistryStatus() async =>
      const RegistryLoginStatus(
        loggedIn: true,
        server: 'docker.io',
        username: 'demo',
      );
}

/// Builds a themed [AppBottomBar] for status-label widget tests.
Widget _engineBottomBar({DaemonStatus? status, String pendingAction = ''}) {
  return MaterialApp(
    home: Scaffold(
      body: AppBottomBar(
        status: status,
        appVersion: '1.0.10',
        busy: false,
        pendingAction: pendingAction,
        loggedIn: false,
        signInPending: false,
        updateAvailable: false,
        onStart: () {},
        onStop: () {},
        onOpenSettings: () {},
        onOpenAbout: () {},
        onSignIn: () {},
        onSignOut: () {},
        onTroubleshoot: () {},
        onOpenDockerHub: () {},
        onDownloadUpdate: () {},
        onRestart: () {},
        onQuit: () {},
      ),
    ),
  );
}

void main() {
  tearDown(CalfToastController.instance.clear);

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
    expect(find.text('demo'), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.chevronDown));
    await tester.pumpAndSettle();

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Account Settings'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Docker Hub'), findsOneWidget);
  });

  testWidgets('shows a toast when containers fetch fails', (tester) async {
    final apiClient = _ErrorCalfClient();

    await tester.pumpWidget(MainApp(apiClient: apiClient));
    await tester.pump();
    expect(find.text('Loading...'), findsOneWidget);

    await tester.pump(Duration.zero);
    await tester.pump();

    expect(find.text('Loading...'), findsNothing);
    expect(find.text('daemon unavailable'), findsOneWidget);
    CalfToastController.instance.clear();
  });

  testWidgets('shows debug log button when log level is debug', (tester) async {
    final apiClient = FakeCalfClient(
      DaemonStatus(
        uptimeSeconds: 42,
        listenAddr: ':8765',
        logLevel: 'debug',
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

    expect(find.byIcon(LucideIcons.bug), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.bug));
    await tester.pumpAndSettle();

    expect(find.text('Daemon logs'), findsOneWidget);
    expect(find.textContaining('runtime started'), findsOneWidget);
  });

  testWidgets('shows engine starting in the status bar', (tester) async {
    final apiClient = FakeCalfClient(
      DaemonStatus(
        uptimeSeconds: 1,
        listenAddr: ':8765',
        logLevel: 'info',
        runtime: const RuntimeStatus(
          mode: 'vm',
          state: 'starting',
          dockerSocket: '/tmp/calf.sock',
          vmName: 'calf',
        ),
      ),
    );

    await tester.pumpWidget(MainApp(apiClient: apiClient));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Engine starting…'), findsWidgets);
  });

  testWidgets('app exit request is accepted after shutdown', (tester) async {
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
    await tester.pump();

    final response = await WidgetsBinding.instance.handleRequestAppExit();
    expect(response, AppExitResponse.exit);
  });

  testWidgets('null engine status is unknown, not starting', (tester) async {
    await tester.pumpWidget(_engineBottomBar(status: null));
    await tester.pump();

    expect(find.text('Engine unknown'), findsOneWidget);
    expect(find.text('Engine starting…'), findsNothing);
  });

  testWidgets('pending start with null status still shows starting', (
    tester,
  ) async {
    await tester.pumpWidget(
      _engineBottomBar(status: null, pendingAction: 'Engine starting…'),
    );
    await tester.pump();

    expect(find.text('Engine starting…'), findsOneWidget);
    expect(find.text('Engine unknown'), findsNothing);
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
  Future<List<NetworkItem>> fetchNetworks() async => [];

  @override
  Future<NetworkDetail> fetchNetworkDetail(String name) async => NetworkDetail(
    id: '',
    name: name,
    driver: 'bridge',
    scope: 'local',
    subnet: '',
    gateway: '',
    created: '',
  );

  @override
  Future<VolumeDetail> fetchVolumeDetail(String name) async =>
      VolumeDetail(name: name, driver: 'local', created: '', inUse: false);

  @override
  Future<List<ContainerFileEntry>> fetchVolumeFiles(
    String name, {
    String path = '/',
  }) async => const [];

  @override
  Future<void> writeVolumeFile(
    String name,
    String path,
    String content,
  ) async {}

  @override
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name) async =>
      const [];

  @override
  Future<List<VolumeExportItem>> fetchVolumeExports(String name) async =>
      const [];

  @override
  Future<VolumeExportItem> createVolumeExport({
    required String name,
    required String type,
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async => VolumeExportItem(
    id: 'export-1',
    volume: name,
    type: type,
    status: 'completed',
    createdAt: '2026-01-01T00:00:00Z',
    downloadable: type == 'local_file',
  );

  @override
  Future<List<int>> downloadVolumeExport(
    String volumeName,
    String exportId,
  ) async => const [];

  @override
  Future<List<VolumeExportScheduleItem>> fetchVolumeExportSchedules(
    String name,
  ) async => const [];

  @override
  Future<VolumeExportScheduleItem> createVolumeExportSchedule({
    required String name,
    required String type,
    bool enabled = false,
    List<VolumeExportDayTimes> dayTimes = const [],
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async => VolumeExportScheduleItem(
    id: 'schedule-1',
    volume: name,
    enabled: enabled,
    dayTimes: dayTimes,
    type: type,
  );

  @override
  Future<VolumeExportScheduleItem> updateVolumeExportSchedule({
    required String volumeName,
    required String scheduleId,
    bool? enabled,
    List<VolumeExportDayTimes>? dayTimes,
    String type = '',
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async => VolumeExportScheduleItem(
    id: scheduleId,
    volume: volumeName,
    enabled: enabled ?? true,
    dayTimes:
        dayTimes ??
        const [
          VolumeExportDayTimes(day: 1, times: ['03:00']),
        ],
    type: type.isNotEmpty ? type : 'local_file',
  );

  @override
  Future<void> deleteVolumeExportSchedule(
    String volumeName,
    String scheduleId,
  ) async {}

  @override
  Future<List<BuildItem>> fetchBuilds({String? tag}) async => [];

  @override
  Future<BuildDetail> fetchBuildDetail(String id) async {
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<BuildSource> fetchBuildSource(String id) async {
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<BuildLogs> fetchBuildLogs(String id) async {
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<List<int>> downloadBuildArtifact(String id, String digest) async {
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<void> startContainer(String id) async {}

  @override
  Future<void> stopContainer(String id) async {}

  @override
  Future<void> removeContainer(String id) async {}

  @override
  Future<void> restartContainer(String id) async {}

  @override
  Future<void> pauseContainer(String id) async {}

  @override
  Future<void> resumeContainer(String id) async {}

  @override
  Future<String> fetchContainerInspect(String id, {String? section}) async =>
      '{"Id":"$id"}';

  @override
  Future<List<ContainerMount>> fetchContainerMounts(String id) async =>
      const [];

  @override
  Future<List<ContainerFileEntry>> fetchContainerFiles(
    String id, {
    String path = '/',
  }) async => const [];

  @override
  Future<void> writeContainerFile(
    String id,
    String path,
    String content,
  ) async {}

  @override
  Future<ContainerExecResult> execContainer(String id, String command) async =>
      const ContainerExecResult(output: '');

  @override
  Future<ContainerStats> fetchContainerStats(String id) async =>
      const ContainerStats(
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
  Future<String> runImage(
    String reference, {
    String name = '',
    List<String> ports = const [],
    List<String> env = const [],
    List<String> volumes = const [],
  }) async => 'mock-container-id';

  @override
  Future<void> removeImage(String reference) async {}

  @override
  Future<void> createVolume(String name) async {}

  @override
  Future<void> emptyVolume(String name) async {}

  @override
  Future<void> importVolume({
    required String name,
    required String source,
    String filePath = '',
    String imageRef = '',
  }) async {}

  @override
  Future<void> cloneVolume(String source, String name) async {}

  @override
  Future<void> removeVolume(String name) async {}

  @override
  Future<void> removeNetwork(String name) async {}

  @override
  Future<void> createNetwork(
    String name, {
    String driver = '',
    String subnet = '',
  }) async {}

  @override
  Future<BuildItem> runBuild({
    required String context,
    required String tag,
    String dockerfile = '',
    String platform = '',
  }) async {
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
  Uri containerLogsWebSocketUri(String id) =>
      Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/logs');

  @override
  Uri containerExecWebSocketUri(String id) =>
      Uri.parse('ws://127.0.0.1:8765/v1/containers/$id/exec');

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
  Future<Config> updateLogLevel(String logLevel) async {
    await Future<void>.delayed(Duration.zero);
    throw ApiException('daemon unavailable', statusCode: 503);
  }

  @override
  Future<DaemonLogs> fetchDaemonLogs() async {
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
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(
    String sessionId,
  ) async =>
      const RegistryBrowserLoginStatus(status: 'complete', username: 'demo');

  @override
  Future<void> cancelRegistryBrowserLogin(String sessionId) async {}

  @override
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  }) async {}

  @override
  Future<void> logoutRegistry({String server = 'docker.io'}) async {}

  @override
  Future<RuntimeStatus> startRuntime() async => const RuntimeStatus(
    mode: 'vm',
    state: 'stopped',
    dockerSocket: '/tmp/calf.sock',
  );

  @override
  Future<RuntimeStatus> stopRuntime() async => const RuntimeStatus(
    mode: 'vm',
    state: 'stopped',
    dockerSocket: '/tmp/calf.sock',
  );

  @override
  Future<RuntimeStatus> killRuntime() async => const RuntimeStatus(
    mode: 'vm',
    state: 'stopped',
    dockerSocket: '/tmp/calf.sock',
  );

  @override
  Future<void> purgeEngineData() async {}

  @override
  Future<void> factoryReset() async {}

  @override
  Future<PrunePreview> fetchPrunePreview() async => const PrunePreview(
    containers: PruneCategoryPreview(items: []),
    images: PruneCategoryPreview(items: []),
    volumes: PruneCategoryPreview(items: []),
    networks: PruneCategoryPreview(items: []),
    buildCache: PruneCategoryPreview(items: []),
  );

  @override
  Future<PruneResult> prune({
    bool containers = true,
    bool images = true,
    bool volumes = true,
    bool networks = true,
    bool buildCache = true,
  }) async => const PruneResult();

  @override
  Future<void> installDockerCli() async {}

  @override
  Future<List<BuilderInfo>> fetchBuilders() async => const [];

  @override
  Future<void> useBuilder(String name) async {}

  @override
  Future<void> removeBuilder(String name) async {}

  @override
  Future<List<int>> downloadDiagnostics() async => const [];

  @override
  Future<void> copyDiskImage(String path) async {}

  @override
  Future<List<HubRepository>> fetchHubRepositories() async => const [];

  @override
  Uri unifiedLogsWebSocketUri() => Uri.parse('ws://127.0.0.1:8765/v1/logs');
}
