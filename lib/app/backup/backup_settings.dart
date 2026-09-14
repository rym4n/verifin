import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../l10n/app_localizations.dart';

/// 自动备份触发频率。
enum BackupFrequency {
  /// 不自动备份，仅手动「立即备份」。
  manual,

  /// 每次打开应用（冷启动 / 回前台解锁后）时备份。
  onOpen,

  /// 每次记账（新增交易）后备份。
  onEntry,

  /// 每隔 N 小时备份（打开应用时检查是否到期）。
  everyNHours;

  String label(AppLocalizations l10n) {
    switch (this) {
      case BackupFrequency.manual:
        return l10n.backupFreqManual;
      case BackupFrequency.onOpen:
        return l10n.backupFreqOnOpen;
      case BackupFrequency.onEntry:
        return l10n.backupFreqOnEntry;
      case BackupFrequency.everyNHours:
        return l10n.backupFreqEveryN;
    }
  }

  static BackupFrequency fromStorage(String? value) {
    return BackupFrequency.values.firstWhere(
      (item) => item.name == value,
      orElse: () => BackupFrequency.manual,
    );
  }
}

/// 备份目录与自动备份配置。目录在 Android 上是 SAF 树 URI，在桌面上是路径。
class BackupSettings {
  const BackupSettings({
    this.directoryUri = '',
    this.directoryLabel = '',
    this.frequency = BackupFrequency.manual,
    this.intervalHours = 24,
    this.retention = 10,
    this.lastBackupAt,
  });

  final String directoryUri;
  final String directoryLabel;
  final BackupFrequency frequency;
  final int intervalHours;
  final int retention;
  final DateTime? lastBackupAt;

  bool get hasDirectory => directoryUri.isNotEmpty;

  /// 是否配置了自动备份（非「仅手动」）。
  bool get autoBackupEnabled => frequency != BackupFrequency.manual;

  BackupSettings copyWith({
    String? directoryUri,
    String? directoryLabel,
    BackupFrequency? frequency,
    int? intervalHours,
    int? retention,
    DateTime? lastBackupAt,
    bool clearLastBackupAt = false,
    bool clearDirectory = false,
  }) {
    return BackupSettings(
      directoryUri: clearDirectory ? '' : (directoryUri ?? this.directoryUri),
      directoryLabel: clearDirectory
          ? ''
          : (directoryLabel ?? this.directoryLabel),
      frequency: frequency ?? this.frequency,
      intervalHours: intervalHours ?? this.intervalHours,
      retention: retention ?? this.retention,
      lastBackupAt: clearLastBackupAt
          ? null
          : (lastBackupAt ?? this.lastBackupAt),
    );
  }

  /// 仅按频率与上次备份时间判断在 [now] 是否到期（不要求已配置目录）。
  /// [afterEntry] 表示当前调用是否由「记账后」事件触发。供本地目录与 WebDAV 共用。
  bool isFrequencyDue(DateTime now, {bool afterEntry = false}) {
    switch (frequency) {
      case BackupFrequency.manual:
        return false;
      case BackupFrequency.onOpen:
        return !afterEntry;
      case BackupFrequency.onEntry:
        return afterEntry;
      case BackupFrequency.everyNHours:
        if (afterEntry) {
          return false;
        }
        final last = lastBackupAt;
        if (last == null) {
          return true;
        }
        final elapsed = now.difference(last);
        return elapsed.inMinutes >= intervalHours * 60;
    }
  }

  /// 依据频率与上次备份时间，判断在 [now] 是否应触发本地目录自动备份。
  bool shouldAutoBackup(DateTime now, {bool afterEntry = false}) {
    return hasDirectory && isFrequencyDue(now, afterEntry: afterEntry);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'directoryUri': directoryUri,
      'directoryLabel': directoryLabel,
      'frequency': frequency.name,
      'intervalHours': intervalHours,
      'retention': retention,
      'lastBackupAt': lastBackupAt?.toIso8601String(),
    };
  }

  static BackupSettings fromJson(Map<String, Object?> json) {
    final rawLast = json['lastBackupAt'] as String?;
    final rawInterval = (json['intervalHours'] as num?)?.toInt() ?? 24;
    final rawRetention = (json['retention'] as num?)?.toInt() ?? 10;
    return BackupSettings(
      directoryUri: json['directoryUri'] as String? ?? '',
      directoryLabel: json['directoryLabel'] as String? ?? '',
      frequency: BackupFrequency.fromStorage(json['frequency'] as String?),
      intervalHours: rawInterval < 1 ? 1 : rawInterval,
      retention: rawRetention < 1 ? 1 : rawRetention,
      lastBackupAt: rawLast == null ? null : DateTime.tryParse(rawLast),
    );
  }

  static BackupSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const BackupSettings();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return BackupSettings.fromJson(Map<String, Object?>.from(decoded));
      }
    } catch (_) {
      // 损坏配置退回默认。
    }
    return const BackupSettings();
  }

  String encode() => jsonEncode(toJson());
}

/// 备份目录中的一个文件的元数据。
class BackupFileInfo {
  const BackupFileInfo({
    required this.uri,
    required this.name,
    required this.modifiedAt,
    required this.sizeBytes,
  });

  final String uri;
  final String name;
  final DateTime modifiedAt;
  final int sizeBytes;

  static BackupFileInfo fromMap(Map<Object?, Object?> map) {
    final millis = (map['modifiedAt'] as num?)?.toInt() ?? 0;
    return BackupFileInfo(
      uri: map['uri'] as String? ?? '',
      name: map['name'] as String? ?? '',
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(millis),
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 备份/WebDAV 传输模式：替代旧的 `BackupFrequency` 非手动值与
/// `WebdavConfig.autoUpload` 二元组合，三者互斥、单一真相。
///
/// - [manual]：仅手动「立即上传」，不自动触发任何 WebDAV 传输。
/// - [autoUpload]：本地自动备份触发时单向上传到 WebDAV（沿用旧
///   `WebdavConfig.autoUpload` 语义）。
/// - [autoSync]：启用双向同步引擎，与 [autoUpload] 互斥（引擎自行决定何时上传/下载）。
enum BackupTransportMode {
  manual,
  autoUpload,
  autoSync;

  String label(AppLocalizations l10n) {
    switch (this) {
      case BackupTransportMode.manual:
        return l10n.syncModeManual;
      case BackupTransportMode.autoUpload:
        return l10n.syncModeAutoUpload;
      case BackupTransportMode.autoSync:
        return l10n.syncModeAutoSync;
    }
  }

  static BackupTransportMode? fromName(String? value) {
    for (final mode in BackupTransportMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return null;
  }
}

/// [BackupTransportMode] 的持久化编解码：带版本号与校验和的 JSON，
/// 用于探测「写到一半被打断」的损坏值（SharedPreferences 不保证跨键原子性，
/// 单键写入本身也可能因平台/进程被杀而只落一半）。校验和不匹配一律当作
/// 「未写入」处理，交给迁移逻辑从旧字段重新推导，绝不把损坏值当成合法模式使用。
abstract final class BackupTransportModeCodec {
  static const int _schemaVersion = 1;

  static String _checksum(int version, String mode) =>
      sha256.convert(utf8.encode('$version:$mode')).toString();

  static String encode(BackupTransportMode mode) {
    return jsonEncode(<String, Object?>{
      'version': _schemaVersion,
      'mode': mode.name,
      'checksum': _checksum(_schemaVersion, mode.name),
    });
  }

  /// 解析失败（缺失/格式错误/版本未知/校验和不匹配）一律返回 null。
  static BackupTransportMode? decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final version = (decoded['version'] as num?)?.toInt();
      final modeName = decoded['mode'] as String?;
      final checksum = decoded['checksum'] as String?;
      if (version == null || modeName == null || checksum == null) {
        return null;
      }
      if (checksum != _checksum(version, modeName)) {
        return null;
      }
      return BackupTransportMode.fromName(modeName);
    } catch (_) {
      return null;
    }
  }
}

/// 自动备份文件名前缀，与手动导出（`verifin-backup-`）区分。
const String autoBackupFilePrefix = 'verifin-auto-';

/// 根据保留份数，从 [files] 中挑出应删除的旧自动备份（按修改时间倒序保留最新 N 份）。
/// 只处理自动备份文件（前缀 [autoBackupFilePrefix]），手动导出不参与清理。
List<BackupFileInfo> autoBackupsToPrune(
  List<BackupFileInfo> files,
  int retention,
) {
  final autoFiles =
      files.where((file) => file.name.startsWith(autoBackupFilePrefix)).toList()
        ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  if (retention < 1 || autoFiles.length <= retention) {
    return const <BackupFileInfo>[];
  }
  return autoFiles.sublist(retention);
}
