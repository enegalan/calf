import 'dart:convert';

import 'package:http/http.dart' as http;

const defaultBaseUrl = 'http://localhost:8080';

class DaemonStatus {
  const DaemonStatus({
    required this.version,
    required this.uptimeSeconds,
    required this.listenAddr,
    required this.logLevel,
  });

  final String version;
  final int uptimeSeconds;
  final String listenAddr;
  final String logLevel;

  factory DaemonStatus.fromJson(Map<String, dynamic> json) {
    return DaemonStatus(
      version: json['version'] as String,
      uptimeSeconds: json['uptime_seconds'] as int,
      listenAddr: json['listen_addr'] as String,
      logLevel: json['log_level'] as String,
    );
  }
}

class ApiClient {
  const ApiClient({this.baseUrl = defaultBaseUrl});

  final String baseUrl;

  Future<DaemonStatus> fetchStatus() async {
    final response = await http.get(Uri.parse('$baseUrl/v1/status'));

    if (response.statusCode != 200) {
      throw ApiException('Error: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return DaemonStatus.fromJson(json);
  }
}

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
