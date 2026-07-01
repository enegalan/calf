import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const defaultBaseUrl = 'http://localhost:8080';
const defaultRequestTimeout = Duration(seconds: 5);

class RuntimeStatus {
  const RuntimeStatus({
    required this.mode,
    required this.state,
    required this.dockerSocket,
    this.vmName,
  });

  final String mode;
  final String state;
  final String dockerSocket;
  final String? vmName;

  factory RuntimeStatus.fromJson(Map<String, dynamic> json) {
    return RuntimeStatus(
      mode: json['mode'] as String? ?? 'unknown',
      state: json['state'] as String? ?? 'unknown',
      dockerSocket: json['docker_socket'] as String? ?? '',
      vmName: json['vm_name'] as String?,
    );
  }
}

class DaemonStatus {
  const DaemonStatus({
    required this.version,
    required this.uptimeSeconds,
    required this.listenAddr,
    required this.logLevel,
    required this.runtime,
  });

  final String version;
  final int uptimeSeconds;
  final String listenAddr;
  final String logLevel;
  final RuntimeStatus runtime;

  factory DaemonStatus.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! String) {
      throw FormatException('expected string "version", got $version');
    }

    final uptimeSeconds = json['uptime_seconds'];
    if (uptimeSeconds is! int) {
      throw FormatException('expected int "uptime_seconds", got $uptimeSeconds');
    }

    final listenAddr = json['listen_addr'];
    if (listenAddr is! String) {
      throw FormatException('expected string "listen_addr", got $listenAddr');
    }

    final logLevel = json['log_level'];
    if (logLevel is! String) {
      throw FormatException('expected string "log_level", got $logLevel');
    }

    final runtimeJson = json['runtime'];
    if (runtimeJson is! Map<String, dynamic>) {
      throw FormatException('expected object "runtime", got $runtimeJson');
    }

    return DaemonStatus(
      version: version,
      uptimeSeconds: uptimeSeconds,
      listenAddr: listenAddr,
      logLevel: logLevel,
      runtime: RuntimeStatus.fromJson(runtimeJson),
    );
  }
}

class ContainerItem {
  const ContainerItem({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;

  factory ContainerItem.fromJson(Map<String, dynamic> json) {
    return ContainerItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      image: json['image'] as String? ?? '',
      state: json['state'] as String? ?? '',
      status: json['status'] as String? ?? '',
    );
  }
}

class ImageItem {
  const ImageItem({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
  });

  final String id;
  final String repository;
  final String tag;
  final String size;

  factory ImageItem.fromJson(Map<String, dynamic> json) {
    return ImageItem(
      id: json['id'] as String? ?? '',
      repository: json['repository'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      size: json['size'] as String? ?? '',
    );
  }
}

abstract class StatusClient {
  Future<DaemonStatus> fetchStatus();
}

abstract class CalfClient implements StatusClient {
  Future<List<ContainerItem>> fetchContainers();
  Future<List<ImageItem>> fetchImages();
  Future<void> startContainer(String id);
  Future<void> stopContainer(String id);
  Future<void> removeContainer(String id);
  Future<void> pullImage(String reference);
  Future<void> removeImage(String reference);
  Stream<String> streamContainerLogs(String id);
}

class ApiClient implements CalfClient {
  ApiClient({
    this.baseUrl = defaultBaseUrl,
    http.Client? httpClient,
    this.timeout = defaultRequestTimeout,
  }) : httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client httpClient;
  final Duration timeout;

  @override
  Future<DaemonStatus> fetchStatus() async {
    final json = await _getJson('/v1/status');
    return DaemonStatus.fromJson(json);
  }

  @override
  Future<List<ContainerItem>> fetchContainers() async {
    final response = await httpClient.get(Uri.parse('$baseUrl/v1/containers')).timeout(timeout);
    return _decodeList(response, ContainerItem.fromJson);
  }

  @override
  Future<List<ImageItem>> fetchImages() async {
    final response = await httpClient.get(Uri.parse('$baseUrl/v1/images')).timeout(timeout);
    return _decodeList(response, ImageItem.fromJson);
  }

  @override
  Future<void> startContainer(String id) async {
    await _postEmpty('/v1/containers/$id/start');
  }

  @override
  Future<void> stopContainer(String id) async {
    await _postEmpty('/v1/containers/$id/stop');
  }

  @override
  Future<void> removeContainer(String id) async {
    await _delete('/v1/containers/$id');
  }

  @override
  Future<void> pullImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException('Error: ${response.statusCode}', statusCode: response.statusCode);
    }
  }

  @override
  Future<void> removeImage(String reference) async {
    await _delete('/v1/images/$reference');
  }

  @override
  Stream<String> streamContainerLogs(String id) {
    final channel = WebSocketChannel.connect(Uri.parse('${baseUrl.replaceFirst('http', 'ws')}/v1/containers/$id/logs'));
    return channel.stream.map((event) => event.toString());
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    try {
      final response = await httpClient.get(Uri.parse('$baseUrl$path')).timeout(timeout);
      if (response.statusCode != 200) {
        throw ApiException('Error: ${response.statusCode}', statusCode: response.statusCode);
      }

      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) {
        throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
      }

      return json;
    } on TimeoutException {
      throw ApiException('Request timed out');
    }
  }

  Future<void> _postEmpty(String path) async {
    final response = await httpClient.post(Uri.parse('$baseUrl$path')).timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException('Error: ${response.statusCode}', statusCode: response.statusCode);
    }
  }

  Future<void> _delete(String path) async {
    final response = await httpClient.delete(Uri.parse('$baseUrl$path')).timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException('Error: ${response.statusCode}', statusCode: response.statusCode);
    }
  }

  List<T> _decodeList<T>(http.Response response, T Function(Map<String, dynamic>) mapper) {
    if (response.statusCode != 200) {
      throw ApiException('Error: ${response.statusCode}', statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! List<dynamic>) {
      throw ApiException('Invalid response: expected JSON array', statusCode: response.statusCode);
    }

    return json.map((item) => mapper(item as Map<String, dynamic>)).toList();
  }
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
