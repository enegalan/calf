import 'package:ui/constants/calf_constants.dart';

/// Detected TCP port conflict blocking the container engine from binding a host port.
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

/// Snapshot of container engine runtime state, including any host port conflicts.
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

/// Overall calf daemon status: version, uptime, listen address, and runtime state.
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

/// A single container as listed by the container engine.
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

  /// Returns the first "host:container" published port mapping, if any.
  String? get primaryPortMapping {
    final match = RegExp(r':(\d+)->(\d+)/').firstMatch(ports);
    if (match == null) {
      return null;
    }
    return '${match.group(1)}:${match.group(2)}';
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

/// A bind mount or volume mount attached to a container.
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

/// A file or directory entry from a container or volume file listing.
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

/// One point-in-time resource usage sample for a container.
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

/// Current resource usage stats for a container, with recent history samples.
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

/// Result of a one-shot command executed inside a container.
class ContainerExecResult {
  /// Creates a [ContainerExecResult] instance.
  const ContainerExecResult({required this.output, this.error});

  final String output;
  final String? error;
}

/// A single image as listed by the container engine.
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

/// One layer in an image's build history.
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

/// A single volume as listed by the container engine.
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

/// A single network as listed by the container engine.
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

/// Detailed information for a single network.
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

/// Detailed information for a single volume.
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

/// A container that mounts a given volume.
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

/// One completed or in-progress export of a volume.
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

/// Scheduled export run times for a single weekday.
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

/// A recurring scheduled export configuration for a volume.
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

/// A single image build as listed by the build history.
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

/// One step in a build's execution log.
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

/// One base-image or stage dependency used by a build.
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

/// One result artifact produced by a build.
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

/// One tag applied to a build's resulting image.
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

/// Breakdown of time spent in each phase of a build.
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

/// Full details for a single build, extending the summary [BuildItem].
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

/// Raw log and step breakdown for a build.
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

/// Dockerfile source content and metadata for a build.
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

/// Current login status for a container registry.
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

/// Session details for a newly started Docker Hub browser login.
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

/// Poll result for a pending Docker Hub browser login session.
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

/// One reclaimable item in a prune category preview.
class PruneItem {
  /// Creates a [PruneItem] instance.
  const PruneItem({
    required this.id,
    required this.name,
    this.size = '',
    this.sizeBytes = 0,
  });

  final String id;
  final String name;
  final String size;
  final int sizeBytes;

  /// Creates a [PruneItem] from a JSON map.
  factory PruneItem.fromJson(Map<String, dynamic> json) {
    return PruneItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: json['size'] as String? ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Preview for one prune category (containers, images, …).
class PruneCategoryPreview {
  /// Creates a [PruneCategoryPreview] instance.
  const PruneCategoryPreview({
    required this.items,
    this.reclaimableBytes = 0,
    this.reclaimableSize = '0 B',
  });

  final List<PruneItem> items;
  final int reclaimableBytes;
  final String reclaimableSize;

  /// Creates a [PruneCategoryPreview] from a JSON map.
  factory PruneCategoryPreview.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <PruneItem>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map<String, dynamic>) {
          items.add(PruneItem.fromJson(entry));
        } else if (entry is Map) {
          items.add(PruneItem.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }
    return PruneCategoryPreview(
      items: items,
      reclaimableBytes: (json['reclaimable_bytes'] as num?)?.toInt() ?? 0,
      reclaimableSize: json['reclaimable_size'] as String? ?? '0 B',
    );
  }
}

/// One TYPE row from engine system df (Images, Containers, Local Volumes, Build Cache).
class DiskUsageRow {
  /// Creates a [DiskUsageRow] instance.
  const DiskUsageRow({
    required this.type,
    this.size = '0 B',
    this.sizeBytes = 0,
    this.reclaimable = '0 B',
    this.reclaimableBytes = 0,
  });

  final String type;
  final String size;
  final int sizeBytes;
  final String reclaimable;
  final int reclaimableBytes;

  /// Creates a [DiskUsageRow] from a JSON map.
  factory DiskUsageRow.fromJson(Map<String, dynamic> json) {
    return DiskUsageRow(
      type: json['type'] as String? ?? '',
      size: json['size'] as String? ?? '0 B',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      reclaimable: json['reclaimable'] as String? ?? '0 B',
      reclaimableBytes: (json['reclaimable_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Engine disk breakdown from system df.
class SystemDiskUsage {
  /// Creates a [SystemDiskUsage] instance.
  const SystemDiskUsage({this.rows = const []});

  final List<DiskUsageRow> rows;

  /// Creates a [SystemDiskUsage] from a JSON map.
  factory SystemDiskUsage.fromJson(Map<String, dynamic> json) {
    final rawRows = json['rows'];
    final rows = <DiskUsageRow>[];
    if (rawRows is List) {
      for (final entry in rawRows) {
        if (entry is Map<String, dynamic>) {
          rows.add(DiskUsageRow.fromJson(entry));
        } else if (entry is Map) {
          rows.add(DiskUsageRow.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }
    return SystemDiskUsage(rows: rows);
  }
}

/// Full clean-disk prune preview across categories.
class PrunePreview {
  /// Creates a [PrunePreview] instance.
  const PrunePreview({
    required this.containers,
    required this.images,
    required this.volumes,
    required this.networks,
    required this.buildCache,
    this.diskUsage = const SystemDiskUsage(),
    this.totalReclaimableBytes = 0,
    this.totalReclaimableSize = '0 B',
  });

  final PruneCategoryPreview containers;
  final PruneCategoryPreview images;
  final PruneCategoryPreview volumes;
  final PruneCategoryPreview networks;
  final PruneCategoryPreview buildCache;
  final SystemDiskUsage diskUsage;
  final int totalReclaimableBytes;
  final String totalReclaimableSize;

  /// Creates a [PrunePreview] from a JSON map.
  factory PrunePreview.fromJson(Map<String, dynamic> json) {
    PruneCategoryPreview category(String key) {
      final value = json[key];
      if (value is Map<String, dynamic>) {
        return PruneCategoryPreview.fromJson(value);
      }
      if (value is Map) {
        return PruneCategoryPreview.fromJson(Map<String, dynamic>.from(value));
      }
      return const PruneCategoryPreview(items: []);
    }

    SystemDiskUsage diskUsage = const SystemDiskUsage();
    final rawUsage = json['disk_usage'];
    if (rawUsage is Map<String, dynamic>) {
      diskUsage = SystemDiskUsage.fromJson(rawUsage);
    } else if (rawUsage is Map) {
      diskUsage = SystemDiskUsage.fromJson(Map<String, dynamic>.from(rawUsage));
    }

    return PrunePreview(
      containers: category('containers'),
      images: category('images'),
      volumes: category('volumes'),
      networks: category('networks'),
      buildCache: category('build_cache'),
      diskUsage: diskUsage,
      totalReclaimableBytes:
          (json['total_reclaimable_bytes'] as num?)?.toInt() ?? 0,
      totalReclaimableSize: json['total_reclaimable_size'] as String? ?? '0 B',
    );
  }
}

/// Result of executing a selective prune.
class PruneResult {
  /// Creates a [PruneResult] instance.
  const PruneResult({
    this.containers = false,
    this.images = false,
    this.volumes = false,
    this.networks = false,
    this.buildCache = false,
    this.reclaimedBytes = 0,
    this.reclaimedSize = '0 B',
  });

  final bool containers;
  final bool images;
  final bool volumes;
  final bool networks;
  final bool buildCache;
  final int reclaimedBytes;
  final String reclaimedSize;

  /// Creates a [PruneResult] from a JSON map.
  factory PruneResult.fromJson(Map<String, dynamic> json) {
    return PruneResult(
      containers: json['containers'] as bool? ?? false,
      images: json['images'] as bool? ?? false,
      volumes: json['volumes'] as bool? ?? false,
      networks: json['networks'] as bool? ?? false,
      buildCache: json['build_cache'] as bool? ?? false,
      reclaimedBytes: (json['reclaimed_bytes'] as num?)?.toInt() ?? 0,
      reclaimedSize: json['reclaimed_size'] as String? ?? '0 B',
    );
  }
}

/// Aggregate counts from a Docker Desktop migration run.
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

/// Current phase, progress, and summary of a Docker Desktop migration.
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

/// Daemon configuration: resource limits, proxy settings, and host capacity.
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
    this.dockerBuildxAvailable = false,
    this.dockerComposeAvailable = false,
    this.dockerPluginsHint = '',
    this.rootless = false,
    this.httpProxy = '',
    this.httpsProxy = '',
    this.noProxy = '',
    this.resourceSaverEnabled = true,
    this.resourceSaverTimeoutSec = 300,
    this.logLevel = 'info',
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
  final bool dockerBuildxAvailable;
  final bool dockerComposeAvailable;
  final String dockerPluginsHint;
  final bool rootless;
  final String httpProxy;
  final String httpsProxy;
  final String noProxy;
  final bool resourceSaverEnabled;
  final int resourceSaverTimeoutSec;
  final String logLevel;

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
    'log_level': logLevel,
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
      dockerBuildxAvailable: json['docker_buildx_available'] as bool? ?? false,
      dockerComposeAvailable:
          json['docker_compose_available'] as bool? ?? false,
      dockerPluginsHint: json['docker_plugins_hint'] as String? ?? '',
      rootless: json['rootless'] as bool? ?? false,
      httpProxy: json['http_proxy'] as String? ?? '',
      httpsProxy: json['https_proxy'] as String? ?? '',
      noProxy: json['no_proxy'] as String? ?? '',
      resourceSaverEnabled: json['resource_saver_enabled'] as bool? ?? true,
      resourceSaverTimeoutSec:
          (json['resource_saver_timeout_sec'] as num?)?.toInt() ?? 300,
      logLevel: json['log_level'] as String? ?? 'info',
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
    bool? dockerBuildxAvailable,
    bool? dockerComposeAvailable,
    String? dockerPluginsHint,
    bool? rootless,
    String? httpProxy,
    String? httpsProxy,
    String? noProxy,
    bool? resourceSaverEnabled,
    int? resourceSaverTimeoutSec,
    String? logLevel,
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
      dockerBuildxAvailable:
          dockerBuildxAvailable ?? this.dockerBuildxAvailable,
      dockerComposeAvailable:
          dockerComposeAvailable ?? this.dockerComposeAvailable,
      dockerPluginsHint: dockerPluginsHint ?? this.dockerPluginsHint,
      rootless: rootless ?? this.rootless,
      httpProxy: httpProxy ?? this.httpProxy,
      httpsProxy: httpsProxy ?? this.httpsProxy,
      noProxy: noProxy ?? this.noProxy,
      resourceSaverEnabled: resourceSaverEnabled ?? this.resourceSaverEnabled,
      resourceSaverTimeoutSec:
          resourceSaverTimeoutSec ?? this.resourceSaverTimeoutSec,
      logLevel: logLevel ?? this.logLevel,
    );
  }
}

/// Recent daemon log file contents for the Debug viewer.
class DaemonLogs {
  /// Creates a [DaemonLogs] instance.
  const DaemonLogs({this.text = '', this.path = ''});

  final String text;
  final String path;

  /// Creates a [DaemonLogs] from a JSON map.
  factory DaemonLogs.fromJson(Map<String, dynamic> json) {
    return DaemonLogs(
      text: json['text'] as String? ?? '',
      path: json['path'] as String? ?? '',
    );
  }
}
