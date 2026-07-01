import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const defaultBaseUrl = 'http://localhost:8080';
const defaultRequestTimeout = Duration(seconds: 5);

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

    return DaemonStatus(
      version: version,
      uptimeSeconds: uptimeSeconds,
      listenAddr: listenAddr,
      logLevel: logLevel,
    );
  }
}

abstract class StatusClient {
  Future<DaemonStatus> fetchStatus();
}

class ApiClient implements StatusClient {
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
    try {
      final response = await httpClient
          .get(Uri.parse('$baseUrl/v1/status'))
          .timeout(timeout);

      if (response.statusCode != 200) {
        throw ApiException(
          'Error: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) {
        throw ApiException(
          'Invalid status response: expected JSON object',
          statusCode: response.statusCode,
        );
      }

      try {
        return DaemonStatus.fromJson(json);
      } on FormatException catch (error) {
        throw ApiException(
          'Invalid status response: ${error.message}',
          statusCode: response.statusCode,
        );
      }
    } on TimeoutException {
      throw ApiException('Request timed out');
    }
  }
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
