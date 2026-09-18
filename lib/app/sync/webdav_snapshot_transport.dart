import 'dart:typed_data';

import '../backup/webdav_config.dart';
import 'sync_snapshot.dart';

class WebdavRootFile {
  const WebdavRootFile({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final SnapshotFileName name;
  final int sizeBytes;
  final DateTime? modifiedAt;
}

class DownloadedWebdavRootFile {
  const DownloadedWebdavRootFile({required this.name, required this.bytes});

  final SnapshotFileName name;
  final Uint8List bytes;
}

class WebdavRootListing {
  const WebdavRootListing({
    required this.files,
    required this.legacyTreePresent,
  });

  final List<WebdavRootFile> files;
  final bool legacyTreePresent;
}

abstract interface class WebdavSnapshotTransport {
  Future<WebdavRootListing> listRoot(WebdavConfig config);

  Future<void> putSnapshot(
    WebdavConfig config,
    SnapshotFileName name,
    Stream<List<int>> bytes,
    int length,
  );

  Future<void> putBlob(
    WebdavConfig config,
    SnapshotFileName name,
    Stream<List<int>> bytes,
    int length,
  );

  Future<DownloadedWebdavRootFile> downloadRootFile(
    WebdavConfig config,
    SnapshotFileName name, {
    required int maxBytes,
  });

  Future<void> deleteSnapshot(WebdavConfig config, SnapshotFileName name);
}
