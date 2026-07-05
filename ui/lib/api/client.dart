import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const defaultBaseUrl = 'http://127.0.0.1:8765';
const defaultRequestTimeout = Duration(seconds: 5);
const imageActionTimeout = Duration(minutes: 10);
const volumeActionTimeout = Duration(seconds: 30);
const volumeExportTimeout = Duration(minutes: 30);

class PortConflict {
  const PortConflict({
    required this.port,
    required this.process,
    required this.hint,
  });

  final int port;
  final String process;
  final String hint;

  factory PortConflict.fromJson(Map<String, dynamic> json) {
    return PortConflict(
      port: json['port'] as int? ?? 0,
      process: json['process'] as String? ?? '',
      hint: json['hint'] as String? ?? '',
    );
  }
}

class RuntimeStatus {
  const RuntimeStatus({
    required this.mode,
    required this.state,
    required this.dockerSocket,
    this.vmName,
    this._portConflicts,
  });

  final String mode;
  final String state;
  final String dockerSocket;
  final String? vmName;
  final List<PortConflict>? _portConflicts;

  List<PortConflict> get portConflicts => _portConflicts ?? const [];

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
      vmName: json['vm_name'] as String?,
      portConflicts: conflicts,
    );
  }
}

class DaemonStatus {
  const DaemonStatus({
    this.version = '',
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

  bool get isRunning =>
      state == 'running' || status.toLowerCase().startsWith('up');

  bool get isCompose => composeProject.isNotEmpty;

  String get shortId => id.length > 12 ? id.substring(0, 12) : id;

  String get displayName =>
      composeService.isNotEmpty ? composeService : name;

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

  int? get primaryHostPort {
    final match = RegExp(r':(\d+)->').firstMatch(ports);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  String get displayImage {
    var value = image;
    value = value.replaceFirst(RegExp(r'^docker\.io/library/'), '');
    value = value.replaceFirst(RegExp(r'^docker\.io/'), '');
    return value;
  }

  String get displayPorts {
    final value = ports.trim();
    if (value.isEmpty) {
      return '—';
    }
    return value.replaceAll('0.0.0.0:', '');
  }

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
  const ContainerMount({
    required this.type,
    required this.source,
    required this.destination,
    this.mode = '',
    this.rw = true,
  });

  final String type;
  final String source;
  final String destination;
  final String mode;
  final bool rw;

  factory ContainerMount.fromJson(Map<String, dynamic> json) {
    return ContainerMount(
      type: json['type'] as String? ?? '',
      source: json['source'] as String? ?? '',
      destination: json['destination'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      rw: json['rw'] as bool? ?? true,
    );
  }
}

class ContainerFileEntry {
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

class ContainerStats {
  const ContainerStats({
    required this.cpuPercent,
    required this.memUsage,
    required this.memPercent,
    required this.netIo,
    required this.blockIo,
    required this.pids,
  });

  final String cpuPercent;
  final String memUsage;
  final String memPercent;
  final String netIo;
  final String blockIo;
  final String pids;

  factory ContainerStats.fromJson(Map<String, dynamic> json) {
    return ContainerStats(
      cpuPercent: json['cpu_percent'] as String? ?? '',
      memUsage: json['mem_usage'] as String? ?? '',
      memPercent: json['mem_percent'] as String? ?? '',
      netIo: json['net_io'] as String? ?? '',
      blockIo: json['block_io'] as String? ?? '',
      pids: json['pids'] as String? ?? '',
    );
  }
}

class ContainerExecResult {
  const ContainerExecResult({
    required this.output,
    this.error,
  });

  final String output;
  final String? error;
}

class ImageItem {
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

  String get reference {
    if (tag.isEmpty || tag == '<none>') {
      return repository;
    }
    return '$repository:$tag';
  }

  String get shortId => id.length > 12 ? id.substring(0, 12) : id;

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

  factory VolumeItem.fromJson(Map<String, dynamic> json) {
    return VolumeItem(
      name: json['name'] as String? ?? '',
      driver: json['driver'] as String? ?? '',
      inUse: json['in_use'] as bool? ?? false,
      size: json['size'] as String? ?? '',
      created: json['created'] as String? ?? '',
    );
  }

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

class VolumeDetail {
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

  String get summary {
    if (type == 'local_file') {
      return fileName.isNotEmpty ? fileName : filePath;
    }

    return imageRef;
  }

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
  const VolumeExportDayTimes({
    required this.day,
    required this.times,
  });

  final int day;
  final List<String> times;

  factory VolumeExportDayTimes.fromJson(Map<String, dynamic> json) {
    return VolumeExportDayTimes(
      day: json['day'] as int? ?? 0,
      times: (json['times'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'day': day,
        'times': times,
      };
}

class VolumeExportScheduleItem {
  const VolumeExportScheduleItem({
    required this.id,
    required this.volume,
    required this.enabled,
    required this.type,
    List<VolumeExportDayTimes>? dayTimes,
    this.daysOfWeek = const [],
    this.times = const [],
    this.frequency = '',
    this.timeOfDay = '',
    this.dayOfWeek = 0,
    this.dayOfMonth = 1,
    this.fileName = '',
    this.folder = '',
    this.imageRef = '',
    this.createdAt = '',
    this.lastRunAt = '',
    this.nextRunAt = '',
    this.lastStatus = '',
    this.lastError = '',
  }) : _storedDayTimes = dayTimes;

  final List<VolumeExportDayTimes>? _storedDayTimes;

  List<VolumeExportDayTimes> get dayTimes {
    final stored = _storedDayTimes;
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }

    if (daysOfWeek.isNotEmpty && times.isNotEmpty) {
      return daysOfWeek.map((day) => VolumeExportDayTimes(day: day, times: times)).toList();
    }

    return const [];
  }

  final String id;
  final String volume;
  final bool enabled;
  final List<int> daysOfWeek;
  final List<String> times;
  final String frequency;
  final String timeOfDay;
  final int dayOfWeek;
  final int dayOfMonth;
  final String type;
  final String fileName;
  final String folder;
  final String imageRef;
  final String createdAt;
  final String lastRunAt;
  final String nextRunAt;
  final String lastStatus;
  final String lastError;

  String get scheduleSummary {
    if (!enabled) {
      return 'Schedule paused';
    }

    if (dayTimes.isEmpty) {
      if (daysOfWeek.isEmpty || times.isEmpty) {
        return 'Not configured';
      }

      final dayLabels = daysOfWeek.map(weekdayShort).join(', ');
      final timeLabels = times.join(', ');
      final runCount = times.length;
      final runLabel = runCount == 1 ? 'export' : 'exports';

      return '$runCount $runLabel per day on $dayLabels at $timeLabels';
    }

    return dayTimes
        .map((entry) => '${weekdayShort(entry.day)} at ${entry.times.join(', ')}')
        .join('; ');
  }

  String get destinationSummary {
    if (type == 'local_file') {
      return fileName.isNotEmpty ? fileName : folder;
    }

    return imageRef;
  }

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

  static String weekdayShort(int day) {
    const labels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    if (day < 0 || day >= labels.length) {
      return '?';
    }

    return labels[day];
  }

  static int compareWeekdays(int left, int right) {
    int order(int day) => day == 0 ? 7 : day;

    return order(left).compareTo(order(right));
  }

  static List<int> _daysFromJson(Map<String, dynamic> json) {
    final raw = json['days_of_week'];
    if (raw is List) {
      return raw.whereType<num>().map((value) => value.toInt()).toList()
        ..sort(compareWeekdays);
    }

    final frequency = json['frequency'] as String? ?? '';
    if (frequency == 'weekly') {
      return [json['day_of_week'] as int? ?? 0];
    }

    if (frequency == 'daily') {
      return [1, 2, 3, 4, 5, 6, 0];
    }

    return const [];
  }

  static List<String> _timesFromJson(Map<String, dynamic> json) {
    final raw = json['times'];
    if (raw is List) {
      return raw.whereType<String>().where((value) => value.trim().isNotEmpty).toList();
    }

    final legacy = json['time_of_day'] as String? ?? '';
    if (legacy.isNotEmpty) {
      return [legacy];
    }

    return const [];
  }

  static List<VolumeExportDayTimes> _dayTimesFromJson(Map<String, dynamic> json) {
    final raw = json['day_times'];
    if (raw is List && raw.isNotEmpty) {
      final entries = raw
          .whereType<Map>()
          .map((value) => VolumeExportDayTimes.fromJson(Map<String, dynamic>.from(value)))
          .toList()
        ..sort((left, right) => compareWeekdays(left.day, right.day));
      return entries;
    }

    final days = _daysFromJson(json);
    final times = _timesFromJson(json);
    if (days.isEmpty || times.isEmpty) {
      return const [];
    }

    return days.map((day) => VolumeExportDayTimes(day: day, times: times)).toList();
  }

  factory VolumeExportScheduleItem.fromJson(Map<String, dynamic> json) {
    final dayTimes = _dayTimesFromJson(json);

    return VolumeExportScheduleItem(
      id: json['id'] as String? ?? '',
      volume: json['volume'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      dayTimes: dayTimes,
      daysOfWeek: dayTimes.isNotEmpty ? dayTimes.map((entry) => entry.day).toList() : _daysFromJson(json),
      times: dayTimes.isNotEmpty
          ? dayTimes.expand((entry) => entry.times).toSet().toList()
          : _timesFromJson(json),
      frequency: json['frequency'] as String? ?? '',
      timeOfDay: json['time_of_day'] as String? ?? '',
      dayOfWeek: json['day_of_week'] as int? ?? 0,
      dayOfMonth: json['day_of_month'] as int? ?? 1,
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
  const BuildDependency({
    required this.source,
    required this.platform,
    required this.digest,
  });

  final String source;
  final String platform;
  final String digest;

  factory BuildDependency.fromJson(Map<String, dynamic> json) {
    return BuildDependency(
      source: json['source'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      digest: json['digest'] as String? ?? '',
    );
  }
}

class BuildArtifact {
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
  const BuildTag({
    required this.tag,
    required this.digest,
  });

  final String tag;
  final String digest;

  factory BuildTag.fromJson(Map<String, dynamic> json) {
    return BuildTag(
      tag: json['tag'] as String? ?? '',
      digest: json['digest'] as String? ?? '',
    );
  }
}

class BuildTiming {
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
      dependencies: _decodeObjectList(json['dependencies'], BuildDependency.fromJson),
      results: _decodeObjectList(json['results'], BuildArtifact.fromJson),
      tags: _decodeObjectList(json['tags'], BuildTag.fromJson),
      timing: BuildTiming.fromJson(json['timing'] as Map<String, dynamic>? ?? const {}),
      sourceRevision: json['source_revision'] as String? ?? '',
      remoteSource: json['remote_source'] as String? ?? '',
      rawLog: json['raw_log'] as String? ?? '',
    );
  }
}

class BuildLogs {
  const BuildLogs({
    this.rawLog = '',
    this.steps = const [],
  });

  final String rawLog;
  final List<BuildStep> steps;

  factory BuildLogs.fromJson(Map<String, dynamic> json) {
    return BuildLogs(
      rawLog: json['raw_log'] as String? ?? '',
      steps: _decodeObjectList(json['steps'], BuildStep.fromJson),
    );
  }
}

class BuildSource {
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

  factory BuildSource.fromJson(Map<String, dynamic> json) {
    return BuildSource(
      path: json['path'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      content: json['content'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
    );
  }
}

List<T> _decodeObjectList<T>(Object? value, T Function(Map<String, dynamic> json) mapper) {
  if (value is! List) {
    return const [];
  }

  return value
      .whereType<Map>()
      .map((item) => mapper(Map<String, dynamic>.from(item)))
      .toList();
}

class RegistryLoginStatus {
  const RegistryLoginStatus({
    required this.loggedIn,
    required this.server,
    this.username,
  });

  final bool loggedIn;
  final String server;
  final String? username;

  factory RegistryLoginStatus.fromJson(Map<String, dynamic> json) {
    return RegistryLoginStatus(
      loggedIn: json['logged_in'] as bool? ?? false,
      server: json['server'] as String? ?? 'docker.io',
      username: json['username'] as String?,
    );
  }
}

class RegistryBrowserLoginStart {
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
  const RegistryBrowserLoginStatus({
    required this.status,
    this.username,
    this.error,
  });

  final String status;
  final String? username;
  final String? error;

  bool get isPending => status == 'pending' || status == 'saving';
  bool get isComplete => status == 'complete';
  bool get isFailed => status == 'failed' || status == 'expired';

  factory RegistryBrowserLoginStatus.fromJson(Map<String, dynamic> json) {
    return RegistryBrowserLoginStatus(
      status: json['status'] as String? ?? 'failed',
      username: json['username'] as String?,
      error: json['error'] as String?,
    );
  }
}

abstract class StatusClient {
  Future<DaemonStatus> fetchStatus();
}

abstract class CalfClient implements StatusClient {
  Future<List<ContainerItem>> fetchContainers();
  Future<List<ImageItem>> fetchImages();
  Future<List<ImageLayer>> fetchImageLayers(String reference);
  Future<List<VolumeItem>> fetchVolumes();
  Future<VolumeDetail> fetchVolumeDetail(String name);
  Future<List<ContainerFileEntry>> fetchVolumeFiles(String name, {String path = '/'});
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name);
  Future<List<VolumeExportItem>> fetchVolumeExports(String name);
  Future<VolumeExportItem> createVolumeExport({
    required String name,
    required String type,
    String fileName = '',
    String folder = '',
    String imageRef = '',
  });
  Future<List<int>> downloadVolumeExport(String volumeName, String exportId);
  Future<List<VolumeExportScheduleItem>> fetchVolumeExportSchedules(String name);
  Future<VolumeExportScheduleItem> createVolumeExportSchedule({
    required String name,
    required String type,
    bool enabled = false,
    List<VolumeExportDayTimes> dayTimes = const [],
    List<int> daysOfWeek = const [],
    List<String> times = const [],
    String fileName = '',
    String folder = '',
    String imageRef = '',
  });
  Future<VolumeExportScheduleItem> updateVolumeExportSchedule({
    required String volumeName,
    required String scheduleId,
    bool? enabled,
    List<VolumeExportDayTimes>? dayTimes,
    List<int>? daysOfWeek,
    List<String>? times,
    String type = '',
    String fileName = '',
    String folder = '',
    String imageRef = '',
  });
  Future<void> deleteVolumeExportSchedule(String volumeName, String scheduleId);
  Future<List<BuildItem>> fetchBuilds({String? tag});
  Future<BuildDetail> fetchBuildDetail(String id);
  Future<BuildSource> fetchBuildSource(String id);
  Future<BuildLogs> fetchBuildLogs(String id);
  Future<void> startContainer(String id);
  Future<void> stopContainer(String id);
  Future<void> removeContainer(String id);
  Future<void> restartContainer(String id);
  Future<String> fetchContainerInspect(String id, {String? section});
  Future<List<ContainerMount>> fetchContainerMounts(String id);
  Future<List<ContainerFileEntry>> fetchContainerFiles(String id, {String path = '/'});
  Future<ContainerExecResult> execContainer(String id, String command);
  Future<ContainerStats> fetchContainerStats(String id);
  Future<void> pullImage(String reference);
  Future<void> pushImage(String reference);
  Future<String> runImage(String reference);
  Future<void> removeImage(String reference);
  Future<void> createVolume(String name);
  Future<void> cloneVolume(String source, String name);
  Future<void> removeVolume(String name);
  Future<BuildItem> runBuild({required String context, required String tag, String dockerfile = ''});
  Stream<String> streamContainerLogs(String id);
  Uri containerLogsWebSocketUri(String id);
  Uri containerExecWebSocketUri(String id);
  Future<Config> fetchConfig();
  Future<Config> updateConfig(Config config);
  Future<MigrationStatus> fetchDockerDesktopMigration();
  Future<MigrationStatus> startDockerDesktopMigration();
  Future<RegistryLoginStatus> fetchRegistryStatus();
  Future<RegistryBrowserLoginStart> startRegistryBrowserLogin();
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(String sessionId);
  Future<void> loginRegistry({
    required String username,
    required String password,
    String server = 'docker.io',
  });
  Future<void> logoutRegistry({String server = 'docker.io'});
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
  Future<List<ImageLayer>> fetchImageLayers(String reference) async {
    final uri = Uri.parse('$baseUrl/v1/images/layers').replace(
      queryParameters: {'reference': reference},
    );
    final response = await httpClient.get(uri).timeout(timeout);
    return _decodeList(response, ImageLayer.fromJson);
  }

  @override
  Future<List<VolumeItem>> fetchVolumes() async {
    final response = await httpClient.get(Uri.parse('$baseUrl/v1/volumes')).timeout(volumeActionTimeout);
    return _decodeList(response, VolumeItem.fromJson);
  }

  @override
  Future<VolumeDetail> fetchVolumeDetail(String name) async {
    final json = await _getJson(
      '/v1/volumes/${Uri.encodeComponent(name)}',
      timeout: volumeActionTimeout,
    );
    return VolumeDetail.fromJson(json);
  }

  @override
  Future<List<ContainerFileEntry>> fetchVolumeFiles(String name, {String path = '/'}) async {
    final uri = Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/files').replace(
      queryParameters: {'path': path},
    );
    final response = await httpClient.get(uri).timeout(volumeActionTimeout);
    return _decodeList(response, ContainerFileEntry.fromJson);
  }

  @override
  Future<List<VolumeContainerUsage>> fetchVolumeContainers(String name) async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/containers'))
        .timeout(volumeActionTimeout);
    return _decodeList(response, VolumeContainerUsage.fromJson);
  }

  @override
  Future<List<VolumeExportItem>> fetchVolumeExports(String name) async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/exports'))
        .timeout(volumeActionTimeout);
    return _decodeList(response, VolumeExportItem.fromJson);
  }

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
        .timeout(volumeExportTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return VolumeExportItem.fromJson(json);
  }

  @override
  Future<List<int>> downloadVolumeExport(String volumeName, String exportId) async {
    final response = await httpClient
        .get(
          Uri.parse(
            '$baseUrl/v1/volumes/${Uri.encodeComponent(volumeName)}/exports/${Uri.encodeComponent(exportId)}/download',
          ),
        )
        .timeout(volumeExportTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    return response.bodyBytes;
  }

  @override
  Future<List<VolumeExportScheduleItem>> fetchVolumeExportSchedules(String name) async {
    final response = await httpClient
        .get(Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/export-schedules'))
        .timeout(volumeActionTimeout);
    return _decodeList(response, VolumeExportScheduleItem.fromJson);
  }

  @override
  Future<VolumeExportScheduleItem> createVolumeExportSchedule({
    required String name,
    required String type,
    bool enabled = false,
    List<VolumeExportDayTimes> dayTimes = const [],
    List<int> daysOfWeek = const [],
    List<String> times = const [],
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
    } else {
      if (daysOfWeek.isNotEmpty) {
        body['days_of_week'] = daysOfWeek;
      }
      if (times.isNotEmpty) {
        body['times'] = times;
      }
    }

    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(name)}/export-schedules'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return VolumeExportScheduleItem.fromJson(json);
  }

  @override
  Future<VolumeExportScheduleItem> updateVolumeExportSchedule({
    required String volumeName,
    required String scheduleId,
    bool? enabled,
    List<VolumeExportDayTimes>? dayTimes,
    List<int>? daysOfWeek,
    List<String>? times,
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
    if (daysOfWeek != null) {
      body['days_of_week'] = daysOfWeek;
    }
    if (times != null) {
      body['times'] = times;
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
        .timeout(volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return VolumeExportScheduleItem.fromJson(json);
  }

  @override
  Future<void> deleteVolumeExportSchedule(String volumeName, String scheduleId) async {
    await _delete(
      '/v1/volumes/${Uri.encodeComponent(volumeName)}/export-schedules/${Uri.encodeComponent(scheduleId)}',
    );
  }

  @override
  Future<List<BuildItem>> fetchBuilds({String? tag}) async {
    final uri = Uri.parse('$baseUrl/v1/builds').replace(
      queryParameters: tag == null || tag.isEmpty ? null : {'tag': tag},
    );
    final response = await httpClient.get(uri).timeout(timeout);
    return _decodeList(response, BuildItem.fromJson);
  }

  @override
  Future<BuildDetail> fetchBuildDetail(String id) async {
    final json = await _getJson('/v1/builds/${Uri.encodeComponent(id)}');
    return BuildDetail.fromJson(json);
  }

  @override
  Future<BuildSource> fetchBuildSource(String id) async {
    final json = await _getJson('/v1/builds/${Uri.encodeComponent(id)}/source');
    return BuildSource.fromJson(json);
  }

  @override
  Future<BuildLogs> fetchBuildLogs(String id) async {
    final json = await _getJson('/v1/builds/${Uri.encodeComponent(id)}/logs');
    return BuildLogs.fromJson(json);
  }

  @override
  Future<Config> fetchConfig() async {
    final json = await _getJson('/v1/config');
    return Config.fromJson(json);
  }

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
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return Config.fromJson(json);
  }

  @override
  Future<MigrationStatus> fetchDockerDesktopMigration() async {
    final json = await _getJson('/v1/migrate/docker-desktop');
    return MigrationStatus.fromJson(json);
  }

  @override
  Future<MigrationStatus> startDockerDesktopMigration() async {
    final response = await httpClient
        .post(Uri.parse('$baseUrl/v1/migrate/docker-desktop'))
        .timeout(timeout);

    if (response.statusCode != 200 && response.statusCode != 202) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return MigrationStatus.fromJson(json);
  }

  @override
  Future<RegistryLoginStatus> fetchRegistryStatus() async {
    final json = await _getJson('/v1/registry');
    return RegistryLoginStatus.fromJson(json);
  }

  @override
  Future<RegistryBrowserLoginStart> startRegistryBrowserLogin() async {
    final response = await httpClient
        .post(Uri.parse('$baseUrl/v1/registry/login'))
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return RegistryBrowserLoginStart.fromJson(json);
  }

  @override
  Future<RegistryBrowserLoginStatus> fetchRegistryBrowserLogin(String sessionId) async {
    final json = await _getJson('/v1/registry/login/$sessionId');
    return RegistryBrowserLoginStatus.fromJson(json);
  }

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
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  @override
  Future<void> logoutRegistry({String server = 'docker.io'}) async {
    final uri = Uri.parse('$baseUrl/v1/registry').replace(
      queryParameters: server.isNotEmpty ? {'server': server} : null,
    );
    final response = await httpClient.delete(uri).timeout(timeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
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
  Future<void> restartContainer(String id) async {
    await _postEmpty('/v1/containers/$id/restart');
  }

  @override
  Future<String> fetchContainerInspect(String id, {String? section}) async {
    final uri = Uri.parse('$baseUrl/v1/containers/$id/inspect').replace(
      queryParameters: section == null || section.isEmpty ? null : {'section': section},
    );
    final response = await httpClient.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
    return response.body;
  }

  @override
  Future<List<ContainerMount>> fetchContainerMounts(String id) async {
    final response = await httpClient.get(Uri.parse('$baseUrl/v1/containers/$id/mounts')).timeout(timeout);
    return _decodeList(response, ContainerMount.fromJson);
  }

  @override
  Future<List<ContainerFileEntry>> fetchContainerFiles(String id, {String path = '/'}) async {
    final uri = Uri.parse('$baseUrl/v1/containers/$id/files').replace(
      queryParameters: {'path': path},
    );
    final response = await httpClient.get(uri).timeout(timeout);
    return _decodeList(response, ContainerFileEntry.fromJson);
  }

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
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return ContainerExecResult(
      output: json['output'] as String? ?? '',
      error: json['error'] as String?,
    );
  }

  @override
  Future<ContainerStats> fetchContainerStats(String id) async {
    final json = await _getJson('/v1/containers/$id/stats');
    return ContainerStats.fromJson(json);
  }

  @override
  Future<void> pullImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(imageActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  @override
  Future<void> pushImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images/push'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(imageActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  @override
  Future<String> runImage(String reference) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/images/run'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'reference': reference}),
        )
        .timeout(imageActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['container_id'] as String? ?? '';
  }

  @override
  Future<void> removeImage(String reference) async {
    await _delete('/v1/images/$reference');
  }

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
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  @override
  Future<void> cloneVolume(String source, String name) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/volumes/${Uri.encodeComponent(source)}/clone'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name}),
        )
        .timeout(volumeActionTimeout);

    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  @override
  Future<void> removeVolume(String name) async {
    await _delete('/v1/volumes/$name');
  }

  @override
  Future<BuildItem> runBuild({required String context, required String tag, String dockerfile = ''}) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/v1/builds'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'context': context,
            'tag': tag,
            if (dockerfile.isNotEmpty) 'dockerfile': dockerfile,
          }),
        )
        .timeout(timeout);

    if (response.statusCode != 200 && response.statusCode != 202) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return BuildItem.fromJson(json);
  }

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

  @override
  Uri containerLogsWebSocketUri(String id) => _webSocketUri('/v1/containers/$id/logs');

  @override
  Uri containerExecWebSocketUri(String id) => _webSocketUri('/v1/containers/$id/exec');

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

  Future<Map<String, dynamic>> _getJson(String path, {Duration? timeout}) async {
    final requestTimeout = timeout ?? this.timeout;
    try {
      final response = await httpClient.get(Uri.parse('$baseUrl$path')).timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw ApiException(_errorMessage(response), statusCode: response.statusCode);
      }

      return _decodeObject(response);
    } on TimeoutException {
      throw ApiException('Request timed out');
    }
  }

  Future<void> _postEmpty(String path) async {
    final response = await httpClient.post(Uri.parse('$baseUrl$path')).timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  Future<void> _delete(String path) async {
    final response = await httpClient.delete(Uri.parse('$baseUrl$path')).timeout(timeout);
    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }
  }

  List<T> _decodeList<T>(http.Response response, T Function(Map<String, dynamic>) mapper) {
    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response), statusCode: response.statusCode);
    }

    final json = _decodeJson(response);
    if (json is! List<dynamic>) {
      throw ApiException('Invalid response: expected JSON array', statusCode: response.statusCode);
    }

    return json.map((item) => mapper(item as Map<String, dynamic>)).toList();
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final json = _decodeJson(response);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Invalid response: expected JSON object', statusCode: response.statusCode);
    }

    return json;
  }

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

  String _errorMessage(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body.containsKey('error')) {
        return body['error'] as String;
      }
    } catch (_) {}
    return 'Error: ${response.statusCode}';
  }

  Map<String, dynamic> _scheduleTimingBody(List<VolumeExportDayTimes> dayTimes) {
    final entries = dayTimes.where((entry) => entry.times.isNotEmpty).toList();
    if (entries.isEmpty) {
      return const {};
    }

    final times = entries.expand((entry) => entry.times).toSet().toList()..sort();

    return {
      'day_times': entries.map((entry) => entry.toJson()).toList(),
      'days_of_week': entries.map((entry) => entry.day).toList(),
      'times': times,
    };
  }
}

class MigrationSummary {
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

  bool get isRunning => phase == 'running';

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
  const Config({
    required this.pollIntervalMs,
    required this.cpus,
    required this.memoryGB,
    this.memorySwapGB = 1,
    this.hostCPUs = 4,
    this.hostMemoryGB = 8,
    this.dockerContextManaged = true,
    this.dockerContextActive = false,
    this.dockerContextName = '',
    this.dockerCliAvailable = false,
  });

  final int pollIntervalMs;
  final int cpus;
  final int memoryGB;
  final int memorySwapGB;
  final int hostCPUs;
  final int hostMemoryGB;
  final bool dockerContextManaged;
  final bool dockerContextActive;
  final String dockerContextName;
  final bool dockerCliAvailable;

  Map<String, dynamic> toJson() => {
        'cpus': cpus,
        'memory_gb': memoryGB,
        'memory_swap_gb': memorySwapGB,
        'docker_context_managed': dockerContextManaged,
      };

  factory Config.fromJson(Map<String, dynamic> json) {
    return Config(
      pollIntervalMs: (json['poll_interval_ms'] as num?)?.toInt() ?? 3000,
      cpus: (json['cpus'] as num?)?.toInt() ?? 4,
      memoryGB: (json['memory_gb'] as num?)?.toInt() ?? 4,
      memorySwapGB: (json['memory_swap_gb'] as num?)?.toInt() ?? 1,
      hostCPUs: (json['host_cpus'] as num?)?.toInt() ?? 4,
      hostMemoryGB: (json['host_memory_gb'] as num?)?.toInt() ?? 8,
      dockerContextManaged: json['docker_context_managed'] as bool? ?? true,
      dockerContextActive: json['docker_context_active'] as bool? ?? false,
      dockerContextName: json['docker_context_name'] as String? ?? '',
      dockerCliAvailable: json['docker_cli_available'] as bool? ?? false,
    );
  }

  Config copyWith({
    int? pollIntervalMs,
    int? cpus,
    int? memoryGB,
    int? memorySwapGB,
    int? hostCPUs,
    int? hostMemoryGB,
    bool? dockerContextManaged,
    bool? dockerContextActive,
    String? dockerContextName,
    bool? dockerCliAvailable,
  }) {
    return Config(
      pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
      cpus: cpus ?? this.cpus,
      memoryGB: memoryGB ?? this.memoryGB,
      memorySwapGB: memorySwapGB ?? this.memorySwapGB,
      hostCPUs: hostCPUs ?? this.hostCPUs,
      hostMemoryGB: hostMemoryGB ?? this.hostMemoryGB,
      dockerContextManaged: dockerContextManaged ?? this.dockerContextManaged,
      dockerContextActive: dockerContextActive ?? this.dockerContextActive,
      dockerContextName: dockerContextName ?? this.dockerContextName,
      dockerCliAvailable: dockerCliAvailable ?? this.dockerCliAvailable,
    );
  }
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
