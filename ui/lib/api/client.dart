import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:ui/constants/calf_constants.dart';

class PortConflict {
  /// Creates a [PortConflict] instance.
  const PortConflict({
    required this.port,
    required this.process,
    required this.hint,
  });

  final int port;
  final String process;
  final String hint;

  /// Creates a [PortConflict] from a JSON map.
  factory PortConflict.fromJson(Map<String, dynamic> json) {
    return PortConflict(
      port: json['port'] as int? ?? 0,
      process: json['process'] as String? ?? '',
      hint: json['hint'] as String? ?? '',
    );
  }
}

class RuntimeStatus {
  /// Creates a [RuntimeStatus] instance.
  const RuntimeStatus({
    required this.mode,
    required this.state,
    required this.dockerSocket,
    this.rootless = false,
    this.vmName,
    this._portConflicts,
  });

  final String mode;
  final String state;
  final String dockerSocket;
  final bool rootless;
  final String? vmName;
  final List<PortConflict>? _portConflicts;

  /// Returns the list of port conflicts, or empty if none.
  List<PortConflict> get portConflicts => _portConflicts ?? const [];

  /// Whether the container engine reports as running.
  bool get isRunning => state == 'running';

  /// Creates a [RuntimeStatus] from a JSON map.
  factory RuntimeStatus.fromJson(Map<String, dynamic> json) {
    final conflictsJson = json['port_conflicts'];
    final conflicts = conflictsJson is List
        ? conflictsJson
              .whereType<Map<String, dynamic>>()
              .map(PortConflict.fromJson)
              .toList()
        : const <PortConflict>[];

    return RuntimeStatus(
      mode: json['mode'] as String? ?? 'unknown',
      state: json['state'] as String? ?? 'unknown',
      dockerSocket: json['docker_socket'] as String? ?? '',
      rootless: json['rootless'] as bool? ?? false,
      vmName: json['vm_name'] as String?,
      portConflicts: conflicts,
    );
  }
}

/// Live engine CPU, RAM, and disk usage relative to reserved capacity.
class EngineResources {
  /// Creates an [EngineResources] instance.
  const EngineResources({
    this.cpuPercent = 0,
    this.memoryUsedBytes = 0,
    this.memoryReservedBytes = 0,
    this.diskUsedBytes = 0,
    this.diskReservedBytes = 0,
  });

  final double cpuPercent;
  final int memoryUsedBytes;
  final int memoryReservedBytes;
  final int diskUsedBytes;
  final int diskReservedBytes;

  /// Creates an [EngineResources] from a JSON map.
  factory EngineResources.fromJson(Map<String, dynamic> json) {
    return EngineResources(
      cpuPercent: (json['cpu_percent'] as num?)?.toDouble() ?? 0,
      memoryUsedBytes: (json['memory_used_bytes'] as num?)?.toInt() ?? 0,
      memoryReservedBytes:
          (json['memory_reserved_bytes'] as num?)?.toInt() ?? 0,
      diskUsedBytes: (json['disk_used_bytes'] as num?)?.toInt() ?? 0,
      diskReservedBytes: (json['disk_reserved_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class DaemonStatus {
  /// Creates a [DaemonStatus] instance.
  const DaemonStatus({
    this.version = '',
    required this.uptimeSeconds,
    required this.listenAddr,
    required this.logLevel,
    required this.runtime,
    this.resources = const EngineResources(),
    this.resourceSaverActive = false,
  });

  final String version;
  final int uptimeSeconds;
  final String listenAddr;
  final String logLevel;
  final RuntimeStatus runtime;
  final EngineResources resources;
  final bool resourceSaverActive;

  /// Creates a [DaemonStatus] from a JSON map.
  factory DaemonStatus.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! String) {
      throw FormatException('expected string "version", got $version');
    }

    final uptimeSeconds = json['uptime_seconds'];
    if (uptimeSeconds is! int) {
      throw FormatException(
        'expected int "uptime_seconds", got $uptimeSeconds',
      );
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

    final resourcesJson = json['resources'];
    final resources = resourcesJson is Map<String, dynamic>
        ? EngineResources.fromJson(resourcesJson)
        : const EngineResources();

    return DaemonStatus(
      version: version,
      uptimeSeconds: uptimeSeconds,
      listenAddr: listenAddr,
      logLevel: logLevel,
      runtime: RuntimeStatus.fromJson(runtimeJson),
      resources: resources,
      resourceSaverActive: json['resource_saver_active'] as bool? ?? false,
    );
  }
}

class ContainerItem {
  /// Creates a [ContainerItem] instance.
  const ContainerItem({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    this.ports = '',
    this.created = '',
    this.composeProject = '',
    this.composeService = '',
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
  final String ports;
  final String created;
  final String composeProject;
  final String composeService;

  /// Whether the container is in a running state.
  bool get isRunning =>
      state == 'running' || status.toLowerCase().startsWith('up');

  /// Whether this container belongs to a Compose project.
  bool get isCompose => composeProject.isNotEmpty;

  /// Returns the first 12 characters of the ID.
  String get shortId => id.length > 12 ? id.substring(0, 12) : id;

  /// Returns the compose service name when set, otherwise the container name.
  String get displayName => composeService.isNotEmpty ? composeService : name;

  /// Returns a subtitle string for list display.
  String get subtitle {
    final image = displayImage;
    if (image.contains('/') || image.contains(':')) {
      return image;
    }
    if (composeProject.isNotEmpty && composeService.isNotEmpty) {
      return '$composeProject-$composeService';
    }
    return image.isNotEmpty ? image : name;
  }

  /// Returns published host ports mapped by this container.
  List<int> get hostPorts {
    final seen = <int>{};
    final result = <int>[];
    for (final match in RegExp(r':(\d+)->').allMatches(ports)) {
      final port = int.tryParse(match.group(1)!);
      if (port == null || !seen.add(port)) {
        continue;
      }
      result.add(port);
    }
    return result;
  }

  /// Returns the first host port mapped by this container, if any.
  int? get primaryHostPort {
    final ports = hostPorts;
    return ports.isEmpty ? null : ports.first;
  }

  /// Returns the image reference with docker.io prefixes stripped.
  String get displayImage {
    var value = image;
    value = value.replaceFirst(RegExp(r'^docker\.io/library/'), '');
    value = value.replaceFirst(RegExp(r'^docker\.io/'), '');
    return value;
  }

  /// Returns port mappings with 0.0.0.0 prefixes removed, or an em dash if empty.
  String get displayPorts {
    final value = ports.trim();
    if (value.isEmpty) {
      return '—';
    }
    return value.replaceAll('0.0.0.0:', '');
  }

  /// Creates a [ContainerItem] from a JSON map.
  factory ContainerItem.fromJson(Map<String, dynamic> json) {
    return ContainerItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      image: json['image'] as String? ?? '',
      state: json['state'] as String? ?? '',
      status: json['status'] as String? ?? '',
      ports: json['ports'] as String? ?? '',
      created: json['created'] as String? ?? '',
      composeProject: json['compose_project'] as String? ?? '',
      composeService: json['compose_service'] as String? ?? '',
    );
  }
}

class ContainerMount {
  /// Creates a [ContainerMount] instance.
  const ContainerMount({
    required this.type,
    required this.source,
    required this.destination,
    this.name = '',
    this.mode = '',
    this.rw = true,
  });

  final String type;
  final String name;
  final String source;
  final String destination;
  final String mode;
  final bool rw;

  /// Creates a [ContainerMount] from a JSON map.
  factory ContainerMount.fromJson(Map<String, dynamic> json) {
    return ContainerMount(
      type: json['type'] as String? ?? '',
      name: json['name'] as String? ?? '',
      source: json['source'] as String? ?? '',
      destination: json['destination'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      rw: json['rw'] as bool? ?? true,
    );
  }
}

class ContainerFileEntry {
  /// Creates a [ContainerFileEntry] instance.
  const ContainerFileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.mode,
    this.modified = '',
    this.note = '',
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final String mode;
  final String modified;
  final String note;

  /// Creates a [ContainerFileEntry] from a JSON map.
  factory ContainerFileEntry.fromJson(Map<String, dynamic> json) {
    return ContainerFileEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      isDir: json['is_dir'] as bool? ?? false,
      size: (json['size'] as num?)?.toInt() ?? 0,
      mode: json['mode'] as String? ?? '',
      modified: json['modified'] as String? ?? '',
      note: json['note'] as String? ?? '',
    );
  }
}

class ContainerStatsSample {
  /// Creates a [ContainerStatsSample] instance.
  const ContainerStatsSample({
    required this.t,
    required this.cpuPercent,
    required this.memUsage,
    required this.memPercent,
    required this.netIo,
    required this.blockIo,
    required this.pids,
  });

  final int t;
  final String cpuPercent;
  final String memUsage;
  final String memPercent;
  final String netIo;
  final String blockIo;
  final String pids;

  /// Creates a [ContainerStatsSample] from a JSON map.
  factory ContainerStatsSample.fromJson(Map<String, dynamic> json) {
    return ContainerStatsSample(
      t: (json['t'] as num?)?.toInt() ?? 0,
      cpuPercent: json['cpu_percent'] as String? ?? '',
      memUsage: json['mem_usage'] as String? ?? '',
      memPercent: json['mem_percent'] as String? ?? '',
      netIo: json['net_io'] as String? ?? '',
      blockIo: json['block_io'] as String? ?? '',
      pids: json['pids'] as String? ?? '',
    );
  }
}

class ContainerStats {
  /// Creates a [ContainerStats] instance.
  const ContainerStats({
    required this.cpuPercent,
    required this.memUsage,
    required this.memPercent,
    required this.netIo,
    required this.blockIo,
    required this.pids,
    this.samples = const [],
  });

  final String cpuPercent;
  final String memUsage;
  final String memPercent;
  final String netIo;
  final String blockIo;
  final String pids;
  final List<ContainerStatsSample> samples;

  /// Creates a [ContainerStats] from a JSON map.
  factory ContainerStats.fromJson(Map<String, dynamic> json) {
    final rawSamples = json['samples'];
    final samples = <ContainerStatsSample>[];
    if (rawSamples is List) {
      for (final entry in rawSamples) {
        if (entry is Map<String, dynamic>) {
          samples.add(ContainerStatsSample.fromJson(entry));
        } else if (entry is Map) {
          samples.add(
            ContainerStatsSample.fromJson(Map<String, dynamic>.from(entry)),
          );
        }
      }
    }

    return ContainerStats(
      cpuPercent: json['cpu_percent'] as String? ?? '',
      memUsage: json['mem_usage'] as String? ?? '',
      memPercent: json['mem_percent'] as String? ?? '',
      netIo: json['net_io'] as String? ?? '',
      blockIo: json['block_io'] as String? ?? '',
      pids: json['pids'] as String? ?? '',
      samples: samples,
    );
  }
}

class ContainerExecResult {
  /// Creates a [ContainerExecResult] instance.
  const ContainerExecResult({required this.output, this.error});

  final String output;
  final String? error;
}

class ImageItem {
  /// Creates a [ImageItem] instance.
  const ImageItem({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    this.created = '',
  });

  final String id;
  final String repository;
  final String tag;
  final String size;
  final String created;

  /// Returns the full image reference as repository:tag.
  String get reference {
    if (tag.isEmpty || tag == '<none>') {
      return repository;
    }
    return '$repository:$tag';
  }

  /// Returns the first 12 characters of the ID.
  String get shortId => id.length > 12 ? id.substring(0, 12) : id;

  /// Creates a [ImageItem] from a JSON map.
  factory ImageItem.fromJson(Map<String, dynamic> json) {
    return ImageItem(
      id: json['id'] as String? ?? '',
      repository: json['repository'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      size: json['size'] as String? ?? '',
      created: json['created'] as String? ?? '',
    );
  }
}

class ImageLayer {
  /// Creates a [ImageLayer] instance.
  const ImageLayer({
    required this.index,
    required this.createdBy,
    required this.size,
    this.created = '',
  });

  final int index;
  final String createdBy;
  final String size;
  final String created;

  /// Creates a [ImageLayer] from a JSON map.
  factory ImageLayer.fromJson(Map<String, dynamic> json) {
    return ImageLayer(
      index: json['index'] as int? ?? 0,
      createdBy: json['created_by'] as String? ?? '',
      size: json['size'] as String? ?? '',
      created: json['created'] as String? ?? '',
    );
  }
}

class VolumeItem {
  /// Creates a [VolumeItem] instance.
  const VolumeItem({
    required this.name,
    required this.driver,
    required this.inUse,
    this.size = '',
    this.created = '',
  });

  final String name;
  final String driver;
  final bool inUse;
  final String size;
  final String created;

  /// Creates a [VolumeItem] from a JSON map.
  factory VolumeItem.fromJson(Map<String, dynamic> json) {
    return VolumeItem(
      name: json['name'] as String? ?? '',
      driver: json['driver'] as String? ?? '',
      inUse: json['in_use'] as bool? ?? false,
      size: json['size'] as String? ?? '',
      created: json['created'] as String? ?? '',
    );
  }

  /// Returns a subtitle string for list display.
  String get subtitle {
    final parts = <String>[];
    if (size.isNotEmpty) {
      parts.add(size);
    }
    if (created.isNotEmpty) {
      parts.add('Created $created');
    }
    return parts.join(' · ');
  }
}

class NetworkItem {
  /// Creates a [NetworkItem] instance.
  const NetworkItem({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
    this.subnet = '',
    this.created = '',
  });

  final String id;
  final String name;
  final String driver;
  final String scope;
  final String subnet;
  final String created;

  /// Creates a [NetworkItem] from a JSON map.
  factory NetworkItem.fromJson(Map<String, dynamic> json) {
    return NetworkItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      driver: json['driver'] as String? ?? '',
      scope: json['scope'] as String? ?? '',
      subnet: json['subnet'] as String? ?? '',
      created: json['created'] as String? ?? '',
    );
  }
}

class NetworkDetail {
  /// Creates a [NetworkDetail] instance.
  const NetworkDetail({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
    required this.subnet,
    required this.gateway,
    required this.created,
    this.options = const {},
  });

  final String id;
  final String name;
  final String driver;
  final String scope;
  final String subnet;
  final String gateway;
  final String created;
  final Map<String, String> options;

  /// Creates a [NetworkDetail] from a JSON map.
  factory NetworkDetail.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = <String, String>{};
    if (rawOptions is Map) {
      for (final entry in rawOptions.entries) {
        options['${entry.key}'] = '${entry.value}';
      }
    }

    return NetworkDetail(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      driver: json['driver'] as String? ?? '',
      scope: json['scope'] as String? ?? '',
      subnet: json['subnet'] as String? ?? '',
      gateway: json['gateway'] as String? ?? '',
      created: json['created'] as String? ?? '',
      options: options,
    );
  }
}

class VolumeDetail {
  /// Creates a [VolumeDetail] instance.
  const VolumeDetail({
    required this.name,
    required this.driver,
    required this.created,
    required this.inUse,
    this.mountpoint = '',
  });

  final String name;
  final String driver;
  final String created;
  final bool inUse;
  final String mountpoint;

  /// Creates a [VolumeDetail] from a JSON map.
  factory VolumeDetail.fromJson(Map<String, dynamic> json) {
    return VolumeDetail(
      name: json['name'] as String? ?? '',
      driver: json['driver'] as String? ?? '',
      created: json['created'] as String? ?? '',
      inUse: json['in_use'] as bool? ?? false,
      mountpoint: json['mountpoint'] as String? ?? '',
    );
  }
}

class VolumeContainerUsage {
  /// Creates a [VolumeContainerUsage] instance.
  const VolumeContainerUsage({
    required this.id,
    required this.name,
    required this.image,
    required this.port,
    required this.target,
  });

  final String id;
  final String name;
  final String image;
  final String port;
  final String target;

  /// Creates a [VolumeContainerUsage] from a JSON map.
  factory VolumeContainerUsage.fromJson(Map<String, dynamic> json) {
    return VolumeContainerUsage(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      image: json['image'] as String? ?? '',
      port: json['port'] as String? ?? '',
      target: json['target'] as String? ?? '',
    );
  }
}

class VolumeExportItem {
  /// Creates a [VolumeExportItem] instance.
  const VolumeExportItem({
    required this.id,
    required this.volume,
    required this.type,
    required this.status,
    required this.createdAt,
    this.fileName = '',
    this.filePath = '',
    this.imageRef = '',
    this.size = '',
    this.error = '',
    this.downloadable = false,
  });

  final String id;
  final String volume;
  final String type;
  final String status;
  final String createdAt;
  final String fileName;
  final String filePath;
  final String imageRef;
  final String size;
  final String error;
  final bool downloadable;

  /// Returns a human-readable label for the export type.
  String get typeLabel {
    switch (type) {
      case 'local_file':
        return 'Local file';
      case 'local_image':
        return 'Local image';
      case 'new_image':
        return 'New image';
      case 'registry':
        return 'Registry';
      default:
        return type;
    }
  }

  /// Returns a one-line summary of the export destination.
  String get summary {
    if (type == 'local_file') {
      return fileName.isNotEmpty ? fileName : filePath;
    }

    return imageRef;
  }

  /// Creates a [VolumeExportItem] from a JSON map.
  factory VolumeExportItem.fromJson(Map<String, dynamic> json) {
    return VolumeExportItem(
      id: json['id'] as String? ?? '',
      volume: json['volume'] as String? ?? '',
      type: json['type'] as String? ?? '',
      status: json['status'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      filePath: json['file_path'] as String? ?? '',
      imageRef: json['image_ref'] as String? ?? '',
      size: json['size'] as String? ?? '',
      error: json['error'] as String? ?? '',
      downloadable: json['downloadable'] as bool? ?? false,
    );
  }
}

class VolumeExportDayTimes {
  /// Creates a [VolumeExportDayTimes] instance.
  const VolumeExportDayTimes({required this.day, required this.times});

  final int day;
  final List<String> times;

  /// Creates a [VolumeExportDayTimes] from a JSON map.
  factory VolumeExportDayTimes.fromJson(Map<String, dynamic> json) {
    return VolumeExportDayTimes(
      day: json['day'] as int? ?? 0,
      times: (json['times'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }

  /// Serializes this [VolumeExportDayTimes] to a JSON map.
  Map<String, dynamic> toJson() => {'day': day, 'times': times};
}

class VolumeExportScheduleItem {
  /// Creates a [VolumeExportScheduleItem] instance.
  const VolumeExportScheduleItem({
    required this.id,
    required this.volume,
    required this.enabled,
    required this.type,
    this.dayTimes = const [],
    this.fileName = '',
    this.folder = '',
    this.imageRef = '',
    this.createdAt = '',
    this.lastRunAt = '',
    this.nextRunAt = '',
    this.lastStatus = '',
    this.lastError = '',
  });

  final String id;
  final String volume;
  final bool enabled;
  final List<VolumeExportDayTimes> dayTimes;
  final String type;
  final String fileName;
  final String folder;
  final String imageRef;
  final String createdAt;
  final String lastRunAt;
  final String nextRunAt;
  final String lastStatus;
  final String lastError;

  /// Returns a human-readable summary of the schedule.
  String get scheduleSummary {
    if (!enabled) {
      return 'Schedule paused';
    }

    if (dayTimes.isEmpty) {
      return 'Not configured';
    }

    return dayTimes
        .map(
          (entry) => '${weekdayShort(entry.day)} at ${entry.times.join(', ')}',
        )
        .join('; ');
  }

  /// Returns a one-line summary of the export destination.
  String get destinationSummary {
    if (type == 'local_file') {
      return fileName.isNotEmpty ? fileName : folder;
    }

    return imageRef;
  }

  /// Returns a human-readable label for the export type.
  String get typeLabel {
    switch (type) {
      case 'local_image':
        return 'Local image';
      case 'new_image':
        return 'New image';
      case 'registry':
        return 'Registry';
      default:
        return 'Local file';
    }
  }

  /// Returns the next scheduled run time formatted for display.
  String get formattedNextRun {
    if (nextRunAt.isEmpty) {
      return '';
    }

    try {
      final runAt = DateTime.parse(nextRunAt).toLocal();
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final weekday = weekdays[runAt.weekday - 1];
      final month = runAt.month.toString().padLeft(2, '0');
      final day = runAt.day.toString().padLeft(2, '0');
      final hour = runAt.hour.toString().padLeft(2, '0');
      final minute = runAt.minute.toString().padLeft(2, '0');

      return '$weekday $month/$day at $hour:$minute';
    } on FormatException {
      return nextRunAt;
    }
  }

  /// Returns a short weekday label for the given day index (0=Sun).
  static String weekdayShort(int day) {
    const labels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    if (day < 0 || day >= labels.length) {
      return '?';
    }

    return labels[day];
  }

  /// Compares two weekday indices with Sunday treated as last.
  static int compareWeekdays(int left, int right) {
    /// Maps Sunday (0) to 7 so weekdays sort Monday-first.
    int order(int day) => day == 0 ? 7 : day;

    return order(left).compareTo(order(right));
  }

  /// Parses and sorts day_times entries from a JSON map.
  static List<VolumeExportDayTimes> _dayTimesFromJson(
    Map<String, dynamic> json,
  ) {
    final raw = json['day_times'];
    if (raw is! List || raw.isEmpty) {
      return const [];
    }

    final entries =
        raw
            .whereType<Map>()
            .map(
              (value) => VolumeExportDayTimes.fromJson(
                Map<String, dynamic>.from(value),
              ),
            )
            .toList()
          ..sort((left, right) => compareWeekdays(left.day, right.day));
    return entries;
  }

  /// Creates a [VolumeExportScheduleItem] from a JSON map.
  factory VolumeExportScheduleItem.fromJson(Map<String, dynamic> json) {
    return VolumeExportScheduleItem(
      id: json['id'] as String? ?? '',
      volume: json['volume'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      dayTimes: _dayTimesFromJson(json),
      type: json['type'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      folder: json['folder'] as String? ?? '',
      imageRef: json['image_ref'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      lastRunAt: json['last_run_at'] as String? ?? '',
      nextRunAt: json['next_run_at'] as String? ?? '',
      lastStatus: json['last_status'] as String? ?? '',
      lastError: json['last_error'] as String? ?? '',
    );
  }
}

class BuildItem {
  /// Creates a [BuildItem] instance.
  const BuildItem({
    required this.id,
    required this.tag,
    required this.context,
    required this.status,
    required this.createdAt,
    this.dockerfile = 'Dockerfile',
    this.platform = '',
    this.durationMs = 0,
    this.builder = 'default',
    this.cachedSteps = 0,
    this.totalSteps = 0,
  });

  final String id;
  final String tag;
  final String context;
  final String status;
  final String createdAt;
  final String dockerfile;
  final String platform;
  final int durationMs;
  final String builder;
  final int cachedSteps;
  final int totalSteps;

  /// Creates a [BuildItem] from a JSON map.
  factory BuildItem.fromJson(Map<String, dynamic> json) {
    return BuildItem(
      id: json['id'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      context: json['context'] as String? ?? '',
      status: json['status'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      dockerfile: json['dockerfile'] as String? ?? 'Dockerfile',
      platform: json['platform'] as String? ?? '',
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      builder: json['builder'] as String? ?? 'default',
      cachedSteps: (json['cached_steps'] as num?)?.toInt() ?? 0,
      totalSteps: (json['total_steps'] as num?)?.toInt() ?? 0,
    );
  }
}

class BuildStep {
  /// Creates a [BuildStep] instance.
  const BuildStep({
    required this.index,
    required this.total,
    required this.name,
    required this.cached,
    required this.durationMs,
    this.log = '',
  });

  final int index;
  final int total;
  final String name;
  final bool cached;
  final int durationMs;
  final String log;

  /// Creates a [BuildStep] from a JSON map.
  factory BuildStep.fromJson(Map<String, dynamic> json) {
    return BuildStep(
      index: (json['index'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      cached: json['cached'] as bool? ?? false,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      log: json['log'] as String? ?? '',
    );
  }
}

class BuildDependency {
  /// Creates a [BuildDependency] instance.
  const BuildDependency({
    required this.source,
    required this.platform,
    required this.digest,
  });

  final String source;
  final String platform;
  final String digest;

  /// Creates a [BuildDependency] from a JSON map.
  factory BuildDependency.fromJson(Map<String, dynamic> json) {
    return BuildDependency(
      source: json['source'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      digest: json['digest'] as String? ?? '',
    );
  }
}

class BuildArtifact {
  /// Creates a [BuildArtifact] instance.
  const BuildArtifact({
    required this.name,
    required this.platform,
    required this.digest,
    required this.size,
  });

  final String name;
  final String platform;
  final String digest;
  final String size;

  /// Creates a [BuildArtifact] from a JSON map.
  factory BuildArtifact.fromJson(Map<String, dynamic> json) {
    return BuildArtifact(
      name: json['name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      digest: json['digest'] as String? ?? '',
      size: json['size'] as String? ?? '',
    );
  }
}

class BuildTag {
  /// Creates a [BuildTag] instance.
  const BuildTag({required this.tag, required this.digest});

  final String tag;
  final String digest;

  /// Creates a [BuildTag] from a JSON map.
  factory BuildTag.fromJson(Map<String, dynamic> json) {
    return BuildTag(
      tag: json['tag'] as String? ?? '',
      digest: json['digest'] as String? ?? '',
    );
  }
}

class BuildTiming {
  /// Creates a [BuildTiming] instance.
  const BuildTiming({
    this.imagePullsMs = 0,
    this.localTransfersMs = 0,
    this.executionsMs = 0,
    this.fileOperationsMs = 0,
    this.resultExportsMs = 0,
    this.idleMs = 0,
  });

  final int imagePullsMs;
  final int localTransfersMs;
  final int executionsMs;
  final int fileOperationsMs;
  final int resultExportsMs;
  final int idleMs;

  /// Creates a [BuildTiming] from a JSON map.
  factory BuildTiming.fromJson(Map<String, dynamic> json) {
    return BuildTiming(
      imagePullsMs: (json['image_pulls_ms'] as num?)?.toInt() ?? 0,
      localTransfersMs: (json['local_transfers_ms'] as num?)?.toInt() ?? 0,
      executionsMs: (json['executions_ms'] as num?)?.toInt() ?? 0,
      fileOperationsMs: (json['file_operations_ms'] as num?)?.toInt() ?? 0,
      resultExportsMs: (json['result_exports_ms'] as num?)?.toInt() ?? 0,
      idleMs: (json['idle_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class BuildDetail extends BuildItem {
  /// Creates a [BuildDetail] instance.
  const BuildDetail({
    required super.id,
    required super.tag,
    required super.context,
    required super.status,
    required super.createdAt,
    super.dockerfile,
    super.platform,
    super.durationMs,
    super.builder,
    super.cachedSteps,
    super.totalSteps,
    this.finishedAt = '',
    this.error = '',
    this.steps = const [],
    this.dependencies = const [],
    this.results = const [],
    this.tags = const [],
    this.timing = const BuildTiming(),
    this.sourceRevision = '',
    this.remoteSource = '',
    this.rawLog = '',
  });

  final String finishedAt;
  final String error;
  final List<BuildStep> steps;
  final List<BuildDependency> dependencies;
  final List<BuildArtifact> results;
  final List<BuildTag> tags;
  final BuildTiming timing;
  final String sourceRevision;
  final String remoteSource;
  final String rawLog;

  /// Creates a [BuildDetail] from a JSON map.
  factory BuildDetail.fromJson(Map<String, dynamic> json) {
    return BuildDetail(
      id: json['id'] as String? ?? '',
      tag: json['tag'] as String? ?? '',
      context: json['context'] as String? ?? '',
      status: json['status'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      dockerfile: json['dockerfile'] as String? ?? 'Dockerfile',
      platform: json['platform'] as String? ?? '',
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      builder: json['builder'] as String? ?? 'default',
      cachedSteps: (json['cached_steps'] as num?)?.toInt() ?? 0,
      totalSteps: (json['total_steps'] as num?)?.toInt() ?? 0,
      finishedAt: json['finished_at'] as String? ?? '',
      error: json['error'] as String? ?? '',
      steps: _decodeObjectList(json['steps'], BuildStep.fromJson),
      dependencies: _decodeObjectList(
        json['dependencies'],
        BuildDependency.fromJson,
      ),
      results: _decodeObjectList(json['results'], BuildArtifact.fromJson),
      tags: _decodeObjectList(json['tags'], BuildTag.fromJson),
      timing: BuildTiming.fromJson(
        json['timing'] as Map<String, dynamic>? ?? const {},
      ),
      sourceRevision: json['source_revision'] as String? ?? '',
      remoteSource: json['remote_source'] as String? ?? '',
      rawLog: json['raw_log'] as String? ?? '',
    );
  }
}

class BuildLogs {
  /// Creates a [BuildLogs] instance.
  const BuildLogs({this.rawLog = '', this.steps = const []});

  final String rawLog;
  final List<BuildStep> steps;

  /// Creates a [BuildLogs] from a JSON map.
  factory BuildLogs.fromJson(Map<String, dynamic> json) {
    return BuildLogs(
      rawLog: json['raw_log'] as String? ?? '',
      steps: _decodeObjectList(json['steps'], BuildStep.fromJson),
    );
  }
}

class BuildSource {
  /// Creates a [BuildSource] instance.
  const BuildSource({
    required this.path,
    required this.filename,
    required this.content,
    required this.platform,
  });

  final String path;
  final String filename;
  final String content;
  final String platform;

  /// Creates a [BuildSource] from a JSON map.
  factory BuildSource.fromJson(Map<String, dynamic> json) {
    return BuildSource(
      path: json['path'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      content: json['content'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
    );
  }
}

/// Decodes a JSON array of objects using the given [mapper].
List<T> _decodeObjectList<T>(
  Object? value,
  T Function(Map<String, dynamic> json) mapper,
) {
  if (value is! List) {
    return const [];
  }

  return value
      .whereType<Map>()
      .map((item) => mapper(Map<String, dynamic>.from(item)))
      .toList();
}

class RegistryLoginStatus {
  /// Creates a [RegistryLoginStatus] instance.
  const RegistryLoginStatus({
    required this.loggedIn,
    required this.server,
    this.username,
  });

  final bool loggedIn;
  final String server;
  final String? username;

  /// Creates a [RegistryLoginStatus] from a JSON map.
  factory RegistryLoginStatus.fromJson(Map<String, dynamic> json) {
    return RegistryLoginStatus(
      loggedIn: json['logged_in'] as bool? ?? false,
      server: json['server'] as String? ?? 'docker.io',
      username: json['username'] as String?,
    );
  }
}

class RegistryBrowserLoginStart {
  /// Creates a [RegistryBrowserLoginStart] instance.
  const RegistryBrowserLoginStart({
    required this.sessionId,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
  });

  final String sessionId;
  final String userCode;
  final String verificationUrl;
  final int expiresIn;

  /// Creates a [RegistryBrowserLoginStart] from a JSON map.
  factory RegistryBrowserLoginStart.fromJson(Map<String, dynamic> json) {
    return RegistryBrowserLoginStart(
      sessionId: json['session_id'] as String? ?? '',
      userCode: json['user_code'] as String? ?? '',
      verificationUrl: json['verification_url'] as String? ?? '',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
    );
  }
}

class RegistryBrowserLoginStatus {
  /// Creates a [RegistryBrowserLoginStatus] instance.
  const RegistryBrowserLoginStatus({
    required this.status,
    this.username,
    this.error,
  });

  final String status;
  final String? username;
  final String? error;

  /// Whether the browser login session is still pending.
  bool get isPending => status == 'pending' || status == 'saving';

  /// Whether the browser login session completed successfully.
  bool get isComplete => status == 'complete';

  /// Whether the browser login session failed or expired.
  bool get isFailed => status == 'failed' || status == 'expired';

  /// Creates a [RegistryBrowserLoginStatus] from a JSON map.
  factory RegistryBrowserLoginStatus.fromJson(Map<String, dynamic> json) {
    return RegistryBrowserLoginStatus(
      status: json['status'] as String? ?? 'failed',
      username: json['username'] as String?,
      error: json['error'] as String?,
    );
  }
}

abstract class StatusClient {
  /// Fetches the daemon status including runtime state.
  Future<DaemonStatus> fetchStatus();
}

abstract class CalfClient implements StatusClient {
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

  /// Stops the engine, wipes Calf data, and restores default settings.
  Future<void> factoryReset();
}

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

  /// Stops the engine, wipes Calf data, and restores default settings.
  @override
  Future<void> factoryReset() async {
    await _postEmptyJson(
      '/v1/troubleshoot/factory-reset',
      timeout: CalfDefaults.troubleshootActionTimeout,
    );
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

    return json.map((item) => mapper(item as Map<String, dynamic>)).toList();
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
        'Calf API returned HTML instead of JSON. Check that the backend is running on $baseUrl and that no container is using the same port.',
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
        return body['error'] as String;
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

class MigrationSummary {
  /// Creates a [MigrationSummary] instance.
  const MigrationSummary({
    required this.configApplied,
    required this.imagesTotal,
    required this.imagesOK,
    required this.volumesTotal,
    required this.volumesOK,
    required this.containersTotal,
    required this.containersOK,
    required this.buildsTotal,
    required this.buildsOK,
  });

  final bool configApplied;
  final int imagesTotal;
  final int imagesOK;
  final int volumesTotal;
  final int volumesOK;
  final int containersTotal;
  final int containersOK;
  final int buildsTotal;
  final int buildsOK;

  /// Creates a [MigrationSummary] from a JSON map.
  factory MigrationSummary.fromJson(Map<String, dynamic> json) {
    return MigrationSummary(
      configApplied: json['config_applied'] as bool? ?? false,
      imagesTotal: (json['images_total'] as num?)?.toInt() ?? 0,
      imagesOK: (json['images_ok'] as num?)?.toInt() ?? 0,
      volumesTotal: (json['volumes_total'] as num?)?.toInt() ?? 0,
      volumesOK: (json['volumes_ok'] as num?)?.toInt() ?? 0,
      containersTotal: (json['containers_total'] as num?)?.toInt() ?? 0,
      containersOK: (json['containers_ok'] as num?)?.toInt() ?? 0,
      buildsTotal: (json['builds_total'] as num?)?.toInt() ?? 0,
      buildsOK: (json['builds_ok'] as num?)?.toInt() ?? 0,
    );
  }
}

class MigrationStatus {
  /// Creates a [MigrationStatus] instance.
  const MigrationStatus({
    required this.phase,
    required this.step,
    required this.progress,
    required this.message,
    this.error,
    required this.summary,
  });

  final String phase;
  final String step;
  final int progress;
  final String message;
  final String? error;
  final MigrationSummary summary;

  /// Whether the migration is currently in progress.
  bool get isRunning => phase == 'running';

  /// Creates a [MigrationStatus] from a JSON map.
  factory MigrationStatus.fromJson(Map<String, dynamic> json) {
    final summaryJson = json['summary'];
    return MigrationStatus(
      phase: json['phase'] as String? ?? 'idle',
      step: json['step'] as String? ?? '',
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      message: json['message'] as String? ?? '',
      error: json['error'] as String?,
      summary: summaryJson is Map<String, dynamic>
          ? MigrationSummary.fromJson(summaryJson)
          : const MigrationSummary(
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
  }
}

class Config {
  /// Creates a [Config] instance.
  const Config({
    required this.pollIntervalMs,
    required this.cpus,
    required this.memoryGB,
    this.memorySwapGB = 1,
    this.diskGB = 100,
    this.diskImage = '',
    this.hostCPUs = 4,
    this.hostMemoryGB = 8,
    this.hostDiskGB = 500,
    this.dockerContextManaged = true,
    this.dockerContextActive = false,
    this.dockerContextName = '',
    this.dockerCliAvailable = false,
    this.rootless = false,
    this.httpProxy = '',
    this.httpsProxy = '',
    this.noProxy = '',
    this.resourceSaverEnabled = true,
    this.resourceSaverTimeoutSec = 300,
  });

  final int pollIntervalMs;
  final int cpus;
  final int memoryGB;
  final int memorySwapGB;
  final int diskGB;
  final String diskImage;
  final int hostCPUs;
  final int hostMemoryGB;
  final int hostDiskGB;
  final bool dockerContextManaged;
  final bool dockerContextActive;
  final String dockerContextName;
  final bool dockerCliAvailable;
  final bool rootless;
  final String httpProxy;
  final String httpsProxy;
  final String noProxy;
  final bool resourceSaverEnabled;
  final int resourceSaverTimeoutSec;

  /// Serializes this [Config] to a JSON map.
  Map<String, dynamic> toJson() => {
    'cpus': cpus,
    'memory_gb': memoryGB,
    'memory_swap_gb': memorySwapGB,
    'disk_gb': diskGB,
    'disk_image': diskImage,
    'docker_context_managed': dockerContextManaged,
    'rootless': rootless,
    'http_proxy': httpProxy,
    'https_proxy': httpsProxy,
    'no_proxy': noProxy,
    'resource_saver_enabled': resourceSaverEnabled,
    'resource_saver_timeout_sec': resourceSaverTimeoutSec,
  };

  /// Creates a [Config] from a JSON map.
  factory Config.fromJson(Map<String, dynamic> json) {
    return Config(
      pollIntervalMs:
          (json['poll_interval_ms'] as num?)?.toInt() ??
          CalfDefaults.defaultPollIntervalMs,
      cpus: (json['cpus'] as num?)?.toInt() ?? 4,
      memoryGB: (json['memory_gb'] as num?)?.toInt() ?? 4,
      memorySwapGB: (json['memory_swap_gb'] as num?)?.toInt() ?? 1,
      diskGB: (json['disk_gb'] as num?)?.toInt() ?? 100,
      diskImage: json['disk_image'] as String? ?? '',
      hostCPUs: (json['host_cpus'] as num?)?.toInt() ?? 4,
      hostMemoryGB: (json['host_memory_gb'] as num?)?.toInt() ?? 8,
      hostDiskGB: (json['host_disk_gb'] as num?)?.toInt() ?? 500,
      dockerContextManaged: json['docker_context_managed'] as bool? ?? true,
      dockerContextActive: json['docker_context_active'] as bool? ?? false,
      dockerContextName: json['docker_context_name'] as String? ?? '',
      dockerCliAvailable: json['docker_cli_available'] as bool? ?? false,
      rootless: json['rootless'] as bool? ?? false,
      httpProxy: json['http_proxy'] as String? ?? '',
      httpsProxy: json['https_proxy'] as String? ?? '',
      noProxy: json['no_proxy'] as String? ?? '',
      resourceSaverEnabled: json['resource_saver_enabled'] as bool? ?? true,
      resourceSaverTimeoutSec:
          (json['resource_saver_timeout_sec'] as num?)?.toInt() ?? 300,
    );
  }

  /// Returns a copy of this [Config] with the given fields replaced.
  Config copyWith({
    int? pollIntervalMs,
    int? cpus,
    int? memoryGB,
    int? memorySwapGB,
    int? diskGB,
    String? diskImage,
    int? hostCPUs,
    int? hostMemoryGB,
    int? hostDiskGB,
    bool? dockerContextManaged,
    bool? dockerContextActive,
    String? dockerContextName,
    bool? dockerCliAvailable,
    bool? rootless,
    String? httpProxy,
    String? httpsProxy,
    String? noProxy,
    bool? resourceSaverEnabled,
    int? resourceSaverTimeoutSec,
  }) {
    return Config(
      pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
      cpus: cpus ?? this.cpus,
      memoryGB: memoryGB ?? this.memoryGB,
      memorySwapGB: memorySwapGB ?? this.memorySwapGB,
      diskGB: diskGB ?? this.diskGB,
      diskImage: diskImage ?? this.diskImage,
      hostCPUs: hostCPUs ?? this.hostCPUs,
      hostMemoryGB: hostMemoryGB ?? this.hostMemoryGB,
      hostDiskGB: hostDiskGB ?? this.hostDiskGB,
      dockerContextManaged: dockerContextManaged ?? this.dockerContextManaged,
      dockerContextActive: dockerContextActive ?? this.dockerContextActive,
      dockerContextName: dockerContextName ?? this.dockerContextName,
      dockerCliAvailable: dockerCliAvailable ?? this.dockerCliAvailable,
      rootless: rootless ?? this.rootless,
      httpProxy: httpProxy ?? this.httpProxy,
      httpsProxy: httpsProxy ?? this.httpsProxy,
      noProxy: noProxy ?? this.noProxy,
      resourceSaverEnabled: resourceSaverEnabled ?? this.resourceSaverEnabled,
      resourceSaverTimeoutSec:
          resourceSaverTimeoutSec ?? this.resourceSaverTimeoutSec,
    );
  }
}

class ApiException implements Exception {
  /// Creates an API exception with [message] and optional [statusCode].
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// Returns the exception message as a string.
  @override
  String toString() => message;
}
