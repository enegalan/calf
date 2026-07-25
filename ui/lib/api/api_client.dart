import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:ui/api/calf_client.dart';
import 'package:ui/api/models.dart';
import 'package:ui/constants/calf_constants.dart';

/// Concrete [CalfClient] implementation backed by HTTP + WebSocket requests
/// to the calf daemon.
class ApiClient implements CalfClient {
  /// Creates a [ApiClient] instance.
  ApiClient({
    this.baseUrl = CalfDefaults.defaultBaseUrl,
    http.Client? httpClient,
    this.timeout = CalfDefaults.defaultRequestTimeout,
  }) : httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client httpClient;
  final Duration timeout;

  /// Fetches the daemon status including runtime state.
  @override
  Future<DaemonStatus> fetchStatus() async {
    final json = await _getJson('/v1/status');
    return DaemonStatus.fromJson(json);
  }

  /// Starts the container engine while the daemon stays up.
  @override
  Future<RuntimeStatus> startRuntime() async {
    final json = await _postEmptyJson(
      '/v1/runtime/start',
      timeout: CalfDefaults.runtimeActionTimeout,
    );
    return RuntimeStatus.fromJson(json);
  }

  /// Gracefully stops the container engine.
  @override
  Future<RuntimeStatus> stopRuntime() async {
    final json = await _postEmptyJson(
      '/v1/runtime/stop',
      timeout: CalfDefaults.runtimeActionTimeout,
    );
    return RuntimeStatus.fromJson(json);
  }

  /// Force-stops the container engine.
  @override
  Future<RuntimeStatus> killRuntime() async {
    final json = await _postEmptyJson(
      '/v1/runtime/kill',
      timeout: CalfDefaults.runtimeActionTimeout,
    );
    return RuntimeStatus.fromJson(json);
  }

  /// Stops the engine and deletes guest/runtime data while keeping settings.
  @override
  Future<void> purgeEngineData() async {
    await _postEmptyJson(
      '/v1/troubleshoot/purge',
      timeout: CalfDefaults.troubleshootActionTimeout,
    );
  }

  /// Stops the engine, wipes calf data, and restores default settings.
  @override
  Future<void> factoryReset() async {
    await _postEmptyJson(
      '/v1/troubleshoot/factory-reset',
      timeout: CalfDefaults.troubleshootActionTimeout,
    );
  }

  /// Fetches a preview of unused data reclaimable by prune.
  @override
  Future<PrunePreview> fetchPrunePreview() async {
    final json = await _getJson('/v1/system/prune/preview');
    return PrunePreview.fromJson(json);
  }

  /// Prunes selected unused resource categories.
  @override
  Future<PruneResult> prune({
    bool containers = true,
    bool images = true,
    bool volumes = true,
    bool networks = true,
    bool buildCache = true,
  }) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/system/prune'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'containers': containers,
            'images': images,
            'volumes': volumes,
            'networks': networks,
            'build_cache': buildCache,
          }),
        )
        .timeout(CalfDefaults.troubleshootActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return PruneResult.fromJson(json);
  }

  /// Fetches the list of containers.
  @override
  Future<List<ContainerItem>> fetchContainers() async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/containers'))
        .timeout(timeout);
    return _decodeList(response, ContainerItem.fromJson);
  }

  /// Fetches the list of images.
  @override
  Future<List<ImageItem>> fetchImages() async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/images'))
        .timeout(timeout);
    return _decodeList(response, ImageItem.fromJson);
  }

  /// fetchNetworkDetail.
  @override
  Future<List<ImageLayer>> fetchImageLayers(String reference) async {
    final uri = Uri.parse(
      '$baseUrl/v1/images/layers',
    ).replace(queryParameters: {'reference': reference});
    final response = await httpClient.get(uri).timeout(timeout);
    return _decodeList(response, ImageLayer.fromJson);
  }

  /// fetchNetworkDetail.
  @override
  Future<List<VolumeItem>> fetchVolumes() async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/volumes'))
        .timeout(CalfDefaults.volumeActionTimeout);
    return _decodeList(response, VolumeItem.fromJson);
  }

  /// fetchNetworkDetail.
  @override
  Future<List<NetworkItem>> fetchNetworks() async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/networks'))
        .timeout(timeout);
    return _decodeList(response, NetworkItem.fromJson);
  }

  /// Fetches detailed information for a network.
  @override
  Future<NetworkDetail> fetchNetworkDetail(String name) async {
    final json = await _getJson('/v1/networks/${Uri.encodeComponent(name)}');
    return NetworkDetail.fromJson(json);
  }

  /// Fetches detailed information for a volume.
  @override
  Future<VolumeDetail> fetchVolumeDetail(String name) async {
    final json = await _getJson(
      '/v1/volumes/${Uri.encodeComponent(name)}',
      timeout: CalfDefaults.volumeActionTimeout,
    );
    return VolumeDetail.fromJson(json);
  }

  /// createVolumeExport.
  @override
  Future<List<ContainerFileEntry>> fetchVolumeFiles(
    String name, {
    String path = '/',
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/files',
    ).replace(queryParameters: {'path': path});
    final response = await httpClient
        .get(uri)
        .timeout(CalfDefaults.volumeActionTimeout);
    return _decodeList(response, ContainerFileEntry.fromJson);
  }

  /// createVolumeExport.
  @override
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name) async {
    final response = await httpClient
        .get(
          Uri.parse(
            '$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/containers',
          ),
        )
        .timeout(CalfDefaults.volumeActionTimeout);
    return _decodeList(response, VolumeContainerUsage.fromJson);
  }

  /// createVolumeExport.
  @override
  Future<List<VolumeExportItem>> fetchVolumeExports(String name) async {
    final response = await httpClient
        .get(
          Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/exports'),
        )
        .timeout(CalfDefaults.volumeActionTimeout);
    return _decodeList(response, VolumeExportItem.fromJson);
  }

  /// Starts a new export for a volume.
  @override
  Future<VolumeExportItem> createVolumeExport({
    required String name,
    required String type,
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/exports'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'type': type,
            if (fileName.isNotEmpty) 'file_name': fileName,
            if (folder.isNotEmpty) 'folder': folder,
            if (imageRef.isNotEmpty) 'image_ref': imageRef,
          }),
        )
        .timeout(CalfDefaults.volumeExportTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return VolumeExportItem.fromJson(json);
  }

  /// createVolumeExportSchedule.
  @override
  Future<List<int>> downloadVolumeExport(
    String volumeName,
    String exportId,
  ) async {
    final response = await httpClient
        .get(
          Uri.parse(
            '$baseUrl/v1/volumes/${Uri.encodeComponent(volumeName)}/exports/${Uri.encodeComponent(exportId)}/download',
          ),
        )
        .timeout(CalfDefaults.volumeExportTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    return response.bodyBytes;
  }

  /// createVolumeExportSchedule.
  @override
  Future<List<VolumeExportScheduleItem>> fetchVolumeExportSchedules(
    String name,
  ) async {
    final response = await httpClient
        .get(
          Uri.parse(
            '$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/export-schedules',
          ),
        )
        .timeout(CalfDefaults.volumeActionTimeout);
    return _decodeList(response, VolumeExportScheduleItem.fromJson);
  }

  /// Creates a new scheduled export for a volume.
  @override
  Future<VolumeExportScheduleItem> createVolumeExportSchedule({
    required String name,
    required String type,
    bool enabled = false,
    List<VolumeExportDayTimes> dayTimes = const [],
    String fileName = '',
    String folder = '',
    String imageRef = '',
  }) async {
    final body = <String, dynamic>{
      'enabled': enabled,
      if (type.isNotEmpty) 'type': type,
      if (fileName.isNotEmpty) 'file_name': fileName,
      if (folder.isNotEmpty) 'folder': folder,
      if (imageRef.isNotEmpty) 'image_ref': imageRef,
    };
    if (dayTimes.isNotEmpty) {
      body.addAll(_scheduleTimingBody(dayTimes));
    }

    final response = await httpClient
        .post(
          Uri.parse(
            '$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/export-schedules',
          ),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(CalfDefaults.volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return VolumeExportScheduleItem.fromJson(json);
  }

  /// Updates an existing scheduled export.
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
  }) async {
    final body = <String, dynamic>{};
    if (enabled != null) {
      body['enabled'] = enabled;
    }
    if (dayTimes != null) {
      body.addAll(_scheduleTimingBody(dayTimes));
    }
    if (type.isNotEmpty) {
      body['type'] = type;
    }
    if (fileName.isNotEmpty) {
      body['file_name'] = fileName;
    }
    if (folder.isNotEmpty) {
      body['folder'] = folder;
    }
    if (imageRef.isNotEmpty) {
      body['image_ref'] = imageRef;
    }

    final response = await httpClient
        .put(
          Uri.parse(
            '$baseUrl/v1/volumes/${Uri.encodeComponent(volumeName)}/export-schedules/${Uri.encodeComponent(scheduleId)}',
          ),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(CalfDefaults.volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return VolumeExportScheduleItem.fromJson(json);
  }

  /// Deletes a scheduled export.
  @override
  Future<void> deleteVolumeExportSchedule(
    String volumeName,
    String scheduleId,
  ) async {
    await _delete(
      '/v1/volumes/${Uri.encodeComponent(volumeName)}/export-schedules/${Uri.encodeComponent(scheduleId)}',
    );
  }

  /// fetchBuildDetail.
  @override
  Future<List<BuildItem>> fetchBuilds({String? tag}) async {
    final uri = Uri.parse('$baseUrl/v1/builds').replace(
      queryParameters: tag == null || tag.isEmpty ? null : {'tag': tag},
    );
    final response = await httpClient.get(uri).timeout(timeout);
    return _decodeList(response, BuildItem.fromJson);
  }

  /// Fetches full details for a build.
  @override
  Future<BuildDetail> fetchBuildDetail(String id) async {
    final json = await _getJson('/v1/builds/${Uri.encodeComponent(id)}');
    return BuildDetail.fromJson(json);
  }

  /// Fetches the Dockerfile source for a build.
  @override
  Future<BuildSource> fetchBuildSource(String id) async {
    final json = await _getJson('/v1/builds/${Uri.encodeComponent(id)}/source');
    return BuildSource.fromJson(json);
  }

  /// Fetches build logs and step breakdown.
  @override
  Future<BuildLogs> fetchBuildLogs(String id) async {
    final json = await _getJson('/v1/builds/${Uri.encodeComponent(id)}/logs');
    return BuildLogs.fromJson(json);
  }

  /// Downloads a build result artifact JSON by digest.
  @override
  Future<List<int>> downloadBuildArtifact(String id, String digest) async {
    final response = await httpClient
        .get(
          Uri.parse(
            '$baseUrl/v1/builds/${Uri.encodeComponent(id)}/artifacts/download',
          ).replace(queryParameters: {'digest': digest}),
        )
        .timeout(CalfDefaults.volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    return response.bodyBytes;
  }

  /// Fetches the current daemon configuration.
  @override
  Future<Config> fetchConfig() async {
    final json = await _getJson('/v1/config');
    return Config.fromJson(json);
  }

  /// Updates the daemon configuration.
  @override
  Future<Config> updateConfig(Config config) async {
    final response = await httpClient
        .put(
          Uri.parse('$baseUrl/v1/config'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(config.toJson()),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return Config.fromJson(json);
  }

  /// Fetches the current Docker Desktop migration status.
  @override
  Future<MigrationStatus> fetchDockerDesktopMigration() async {
    final json = await _getJson('/v1/migrate/docker-desktop');
    return MigrationStatus.fromJson(json);
  }

  /// Starts migration from Docker Desktop.
  @override
  Future<MigrationStatus> startDockerDesktopMigration() async {
    final response = await httpClient
        .post(Uri.parse('$baseUrl/v1/migrate/docker-desktop'))
        .timeout(timeout);

    if (response.statusCode != 200 && response.statusCode != 202) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return MigrationStatus.fromJson(json);
  }

  /// Fetches the current registry login status.
  @override
  Future<RegistryLoginStatus> fetchRegistryStatus() async {
    final json = await _getJson('/v1/registry');
    return RegistryLoginStatus.fromJson(json);
  }

  /// Starts a Docker Hub browser-based login flow.
  @override
  Future<RegistryBrowserLoginStart> startRegistryBrowserLogin() async {
    final response = await httpClient
        .post(Uri.parse('$baseUrl/v1/registry/login'))
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return RegistryBrowserLoginStart.fromJson(json);
  }

  /// Polls the status of a browser login session.
  @override
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(
    String sessionId,
  ) async {
    final json = await _getJson('/v1/registry/login/$sessionId');
    return RegistryBrowserLoginStatus.fromJson(json);
  }

  /// Cancels a pending browser login session.
  @override
  Future<void> cancelRegistryBrowserLogin(String sessionId) async {
    await _delete('/v1/registry/login/$sessionId');
  }

  /// Logs in to a container registry with username and password.
  @override
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  }) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/registry'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': password,
            if (server.isNotEmpty) 'server': server,
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Logs out from a container registry.
  @override
  Future<void> logoutRegistry({String server = 'docker.io'}) async {
    final uri = Uri.parse(
      '$baseUrl/v1/registry',
    ).replace(queryParameters: server.isNotEmpty ? {'server': server} : null);
    final response = await httpClient.delete(uri).timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Starts a stopped container.
  @override
  Future<void> startContainer(String id) async {
    await _postEmpty('/v1/containers/$id/start');
  }

  /// Stops a running container.
  @override
  Future<void> stopContainer(String id) async {
    await _postEmpty('/v1/containers/$id/stop');
  }

  /// Removes a container.
  @override
  Future<void> removeContainer(String id) async {
    await _delete('/v1/containers/$id');
  }

  /// Restarts a container.
  @override
  Future<void> restartContainer(String id) async {
    await _postEmpty('/v1/containers/$id/restart');
  }

  /// Fetches raw inspect JSON for a container.
  @override
  Future<String> fetchContainerInspect(String id, {String? section}) async {
    final uri = Uri.parse('$baseUrl/v1/containers/$id/inspect').replace(
      queryParameters: section == null || section.isEmpty
          ? null
          : {'section': section},
    );
    final response = await httpClient.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
    return response.body;
  }

  /// execContainer.
  @override
  Future<List<ContainerMount>> fetchContainerMounts(String id) async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/containers/$id/mounts'))
        .timeout(timeout);
    return _decodeList(response, ContainerMount.fromJson);
  }

  /// execContainer.
  @override
  Future<List<ContainerFileEntry>> fetchContainerFiles(
    String id, {
    String path = '/',
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/containers/$id/files',
    ).replace(queryParameters: {'path': path});
    final response = await httpClient.get(uri).timeout(timeout);
    return _decodeList(response, ContainerFileEntry.fromJson);
  }

  /// Runs a one-shot command inside a container.
  @override
  Future<ContainerExecResult> execContainer(String id, String command) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/containers/$id/exec'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'command': command}),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return ContainerExecResult(
      output: json['output'] as String? ?? '',
      error: json['error'] as String?,
    );
  }

  /// Fetches resource usage stats for a container.
  @override
  Future<ContainerStats> fetchContainerStats(String id) async {
    final json = await _getJson('/v1/containers/$id/stats');
    return ContainerStats.fromJson(json);
  }

  /// Pulls an image from a registry.
  @override
  Future<void> pullImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(CalfDefaults.imageActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Pushes an image to a registry.
  @override
  Future<void> pushImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images/push'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(CalfDefaults.imageActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Creates and starts a container from an image reference.
  @override
  Future<String> runImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images/run'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(CalfDefaults.imageActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['container_id'] as String? ?? '';
  }

  /// Removes an image.
  @override
  Future<void> removeImage(String reference) async {
    await _delete('/v1/images/$reference');
  }

  /// Creates a new volume.
  @override
  Future<void> createVolume(String name) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/volumes'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name}),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Clones an existing volume to a new name.
  @override
  Future<void> cloneVolume(String source, String name) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(source)}/clone'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name}),
        )
        .timeout(CalfDefaults.volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Removes a volume.
  @override
  Future<void> removeVolume(String name) async {
    await _delete('/v1/volumes/$name');
  }

  /// Removes a network.
  @override
  Future<void> removeNetwork(String name) async {
    await _delete('/v1/networks/${Uri.encodeComponent(name)}');
  }

  /// Triggers a new image build.
  @override
  Future<BuildItem> runBuild({
    required String context,
    required String tag,
    String dockerfile = '',
    String platform = '',
  }) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/builds'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'context': context,
            'tag': tag,
            if (dockerfile.isNotEmpty) 'dockerfile': dockerfile,
            if (platform.isNotEmpty) 'platform': platform,
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200 && response.statusCode != 202) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return BuildItem.fromJson(json);
  }

  /// Returns a stream of log lines from a container.
  @override
  Stream<String> streamContainerLogs(String id) {
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? subscription;
    late final StreamController<String> controller;

    controller = StreamController<String>(
      onListen: () {
        channel = WebSocketChannel.connect(containerLogsWebSocketUri(id));
        subscription = channel!.stream.listen(
          (event) => controller.add(event.toString()),
          onError: controller.addError,
          onDone: controller.close,
          cancelOnError: false,
        );
      },
      onCancel: () {
        subscription?.cancel();
        channel?.sink.close();
      },
    );

    return controller.stream;
  }

  /// Returns the WebSocket URI for container log streaming.
  @override
  Uri containerLogsWebSocketUri(String id) =>
      _webSocketUri('/v1/containers/$id/logs');

  /// Returns the WebSocket URI for interactive container exec.
  @override
  Uri containerExecWebSocketUri(String id) =>
      _webSocketUri('/v1/containers/$id/exec');

  /// Builds a WebSocket URI for the given API path.
  Uri _webSocketUri(String path) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  /// Performs a GET request and returns the decoded JSON object.
  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration? timeout,
  }) async {
    final requestTimeout = timeout ?? this.timeout;
    try {
      final response = await httpClient
          .get(Uri.parse('$baseUrl$path'))
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw ApiException(
          _errorMessage(response),
          statusCode: response.statusCode,
        );
      }

      return _decodeObject(response);
    } on TimeoutException {
      throw ApiException('Request timed out');
    }
  }

  /// Performs a POST request with no body and returns the decoded JSON object.
  Future<Map<String, dynamic>> _postEmptyJson(
    String path, {
    Duration? timeout,
  }) async {
    final requestTimeout = timeout ?? this.timeout;
    try {
      final response = await httpClient
          .post(Uri.parse('$baseUrl$path'))
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw ApiException(
          _errorMessage(response),
          statusCode: response.statusCode,
        );
      }
      return _decodeObject(response);
    } on TimeoutException {
      throw ApiException('Request timed out');
    }
  }

  /// Performs a POST request with no body and checks for success.
  Future<void> _postEmpty(String path) async {
    final response = await httpClient
        .post(Uri.parse('$baseUrl$path'))
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Performs a DELETE request and checks for success.
  Future<void> _delete(String path) async {
    final response = await httpClient
        .delete(Uri.parse('$baseUrl$path'))
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  /// Decodes a JSON array response into a typed list.
  List<T> _decodeList<T>(
    http.Response response,
    T Function(Map<String, dynamic>) mapper,
  ) {
    if (response.statusCode != 200) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final json = _decodeJson(response);
    if (json is! List<dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON array',
        statusCode: response.statusCode,
      );
    }

    return json.map((item) {
      if (item is! Map) {
        throw ApiException(
          'Invalid response: expected JSON object in array',
          statusCode: response.statusCode,
        );
      }
      return mapper(Map<String, dynamic>.from(item));
    }).toList();
  }

  /// Decodes a JSON object response.
  Map<String, dynamic> _decodeObject(http.Response response) {
    final json = _decodeJson(response);
    if (json is! Map<String, dynamic>) {
      throw ApiException(
        'Invalid response: expected JSON object',
        statusCode: response.statusCode,
      );
    }

    return json;
  }

  /// Decodes the response body as JSON, rejecting HTML error pages.
  dynamic _decodeJson(http.Response response) {
    final body = response.body.trimLeft();
    if (body.startsWith('<!DOCTYPE') || body.startsWith('<html')) {
      throw ApiException(
        'calf API returned HTML instead of JSON. Check that the backend is running on $baseUrl and that no container is using the same port.',
        statusCode: response.statusCode,
      );
    }

    return jsonDecode(response.body);
  }

  /// Extracts an error message from a failed API response.
  String _errorMessage(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body.containsKey('error')) {
        final error = body['error'];
        if (error is String && error.isNotEmpty) {
          return error;
        }
        if (error != null) {
          return error.toString();
        }
      }
    } catch (_) {}
    return 'Error: ${response.statusCode}';
  }

  /// Builds the day_times JSON body for schedule create/update requests.
  Map<String, dynamic> _scheduleTimingBody(
    List<VolumeExportDayTimes> dayTimes,
  ) {
    final entries = dayTimes.where((entry) => entry.times.isNotEmpty).toList();
    if (entries.isEmpty) {
      return const {};
    }

    return {'day_times': entries.map((entry) => entry.toJson()).toList()};
  }
}

/// Error thrown by [ApiClient] when a request fails or returns an
/// unexpected response.
class ApiException implements Exception {
  /// Creates an API exception with [message] and optional [statusCode].
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// Returns the exception message as a string.
  @override
  String toString() => message;
}
