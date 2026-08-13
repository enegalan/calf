import 'package:ui/api/models.dart';

/// Interface for talking to the calf daemon's REST + WebSocket API.
abstract class CalfClient {
  /// Fetches the daemon status including runtime state.
  Future<DaemonStatus> fetchStatus();

  /// Fetches the list of containers.
  Future<List<ContainerItem>> fetchContainers();

  /// Fetches the list of images.
  Future<List<ImageItem>> fetchImages();

  /// Fetches the layer history for an image reference.
  Future<List<ImageLayer>> fetchImageLayers(String reference);

  /// Fetches the list of volumes.
  Future<List<VolumeItem>> fetchVolumes();

  /// Fetches the list of networks.
  Future<List<NetworkItem>> fetchNetworks();

  /// Fetches detailed information for a network.
  Future<NetworkDetail> fetchNetworkDetail(String name);

  /// Fetches detailed information for a volume.
  Future<VolumeDetail> fetchVolumeDetail(String name);

  /// Lists files inside a volume at the given path.
  Future<List<ContainerFileEntry>> fetchVolumeFiles(
    String name, {
    String path = '/',
  });

  /// Fetches containers that mount the given volume.
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name);

  /// Fetches export history for a volume.
  Future<List<VolumeExportItem>> fetchVolumeExports(String name);

  /// Starts a new export for a volume.
  Future<VolumeExportItem> createVolumeExport({
    required String name,
    required String type,
    String fileName = '',
    String folder = '',
    String imageRef = '',
  });

  /// Downloads the bytes of a completed volume export.
  Future<List<int>> downloadVolumeExport(String volumeName, String exportId);

  /// Fetches scheduled exports for a volume.
  Future<List<VolumeExportScheduleItem>> fetchVolumeExportSchedules(
    String name,
  );

  /// Creates a new scheduled export for a volume.
  Future<VolumeExportScheduleItem> createVolumeExportSchedule({
    required String name,
    required String type,
    bool enabled = false,
    List<VolumeExportDayTimes> dayTimes = const [],
    String fileName = '',
    String folder = '',
    String imageRef = '',
  });

  /// Updates an existing scheduled export.
  Future<VolumeExportScheduleItem> updateVolumeExportSchedule({
    required String volumeName,
    required String scheduleId,
    bool? enabled,
    List<VolumeExportDayTimes>? dayTimes,
    String type = '',
    String fileName = '',
    String folder = '',
    String imageRef = '',
  });

  /// Deletes a scheduled export.
  Future<void> deleteVolumeExportSchedule(String volumeName, String scheduleId);

  /// Fetches the build history, optionally filtered by tag.
  Future<List<BuildItem>> fetchBuilds({String? tag});

  /// Fetches full details for a build.
  Future<BuildDetail> fetchBuildDetail(String id);

  /// Fetches the Dockerfile source for a build.
  Future<BuildSource> fetchBuildSource(String id);

  /// Fetches build logs and step breakdown.
  Future<BuildLogs> fetchBuildLogs(String id);

  /// Downloads a build result artifact JSON by digest.
  Future<List<int>> downloadBuildArtifact(String id, String digest);

  /// Starts a stopped container.
  Future<void> startContainer(String id);

  /// Stops a running container.
  Future<void> stopContainer(String id);

  /// Removes a container.
  Future<void> removeContainer(String id);

  /// Restarts a container.
  Future<void> restartContainer(String id);

  /// Fetches raw inspect JSON for a container.
  Future<String> fetchContainerInspect(String id, {String? section});

  /// Fetches mount points for a container.
  Future<List<ContainerMount>> fetchContainerMounts(String id);

  /// Lists files inside a container at the given path.
  Future<List<ContainerFileEntry>> fetchContainerFiles(
    String id, {
    String path = '/',
  });

  /// Runs a one-shot command inside a container.
  Future<ContainerExecResult> execContainer(String id, String command);

  /// Fetches resource usage stats for a container.
  Future<ContainerStats> fetchContainerStats(String id);

  /// Pulls an image from a registry.
  Future<void> pullImage(String reference);

  /// Pushes an image to a registry.
  Future<void> pushImage(String reference);

  /// Creates and starts a container from an image reference.
  Future<String> runImage(String reference);

  /// Removes an image.
  Future<void> removeImage(String reference);

  /// Creates a new volume.
  Future<void> createVolume(String name);

  /// Clones an existing volume to a new name.
  Future<void> cloneVolume(String source, String name);

  /// Removes a volume.
  Future<void> removeVolume(String name);

  /// Removes a network.
  Future<void> removeNetwork(String name);

  /// Triggers a new image build.
  Future<BuildItem> runBuild({
    required String context,
    required String tag,
    String dockerfile = '',
    String platform = '',
  });

  /// Returns a stream of log lines from a container.
  Stream<String> streamContainerLogs(String id);

  /// Returns the WebSocket URI for container log streaming.
  Uri containerLogsWebSocketUri(String id);

  /// Returns the WebSocket URI for interactive container exec.
  Uri containerExecWebSocketUri(String id);

  /// Fetches the current daemon configuration.
  Future<Config> fetchConfig();

  /// Updates the daemon configuration.
  Future<Config> updateConfig(Config config);

  /// Fetches the current Docker Desktop migration status.
  Future<MigrationStatus> fetchDockerDesktopMigration();

  /// Starts migration from Docker Desktop.
  Future<MigrationStatus> startDockerDesktopMigration();

  /// Fetches the current registry login status.
  Future<RegistryLoginStatus> fetchRegistryStatus();

  /// Starts a Docker Hub browser-based login flow.
  Future<RegistryBrowserLoginStart> startRegistryBrowserLogin();

  /// Polls the status of a browser login session.
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(
    String sessionId,
  );

  /// Cancels a pending browser login session.
  Future<void> cancelRegistryBrowserLogin(String sessionId);

  /// Logs in to a container registry with username and password.
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  });

  /// Logs out from a container registry.
  Future<void> logoutRegistry({String server = 'docker.io'});

  /// Starts the container engine while the daemon stays up.
  Future<RuntimeStatus> startRuntime();

  /// Gracefully stops the container engine.
  Future<RuntimeStatus> stopRuntime();

  /// Force-stops the container engine.
  Future<RuntimeStatus> killRuntime();

  /// Stops the engine and deletes guest/runtime data while keeping settings.
  Future<void> purgeEngineData();

  /// Stops the engine, wipes calf data, and restores default settings.
  Future<void> factoryReset();

  /// Fetches a preview of unused data reclaimable by prune.
  Future<PrunePreview> fetchPrunePreview();

  /// Prunes selected unused resource categories.
  Future<PruneResult> prune({
    bool containers = true,
    bool images = true,
    bool volumes = true,
    bool networks = true,
    bool buildCache = true,
  });
}
