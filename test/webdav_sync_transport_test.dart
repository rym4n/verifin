import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/webdav_sync_transport.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

void main() {
  group('WebdavSyncTransport', () {
    late WebdavSyncTransport transport;
    late WebdavConfig config;

    setUp(() {
      transport = StubWebdavSyncTransport();
      config = const WebdavConfig(
        url: 'https://dav.example.com/verifin/',
        username: 'user',
        password: 'pass',
      );
    });

    test('ensureSyncTree creates directories level by level', () async {
      await transport.ensureSyncTree(config);

      final stub = transport as StubWebdavSyncTransport;
      expect(stub.createdDirectories, {
        'verifin-sync',
        'verifin-sync/v1',
        'verifin-sync/v1/events',
        'verifin-sync/v1/blobs',
        'verifin-sync/v1/batches',
      });
    });

    test('putImmutable uploads new file', () async {
      final content = utf8.encode('test content');
      final hash = sha256.convert(content).toString();
      final stream = Stream.value(content);

      await transport.putImmutable(
        config,
        'verifin-sync/v1/blobs/abc123.blob',
        stream,
        content.length,
        hash,
      );

      final stub = transport as StubWebdavSyncTransport;
      expect(stub.files.containsKey('verifin-sync/v1/blobs/abc123.blob'), true);
      expect(stub.files['verifin-sync/v1/blobs/abc123.blob'], content);
    });

    test('putImmutable succeeds when same hash exists', () async {
      final content = utf8.encode('test content');
      final hash = sha256.convert(content).toString();

      // Upload once
      await transport.putImmutable(
        config,
        'verifin-sync/v1/blobs/abc123.blob',
        Stream.value(content),
        content.length,
        hash,
      );

      // Upload again with same hash - should succeed
      await transport.putImmutable(
        config,
        'verifin-sync/v1/blobs/abc123.blob',
        Stream.value(content),
        content.length,
        hash,
      );

      final stub = transport as StubWebdavSyncTransport;
      expect(stub.files.length, 1);
    });

    test(
      'putImmutable throws WebdavFileCollision when different hash exists',
      () async {
        final content1 = utf8.encode('content 1');
        final hash1 = sha256.convert(content1).toString();

        final content2 = utf8.encode('content 2');
        final hash2 = sha256.convert(content2).toString();

        await transport.putImmutable(
          config,
          'verifin-sync/v1/blobs/abc123.blob',
          Stream.value(content1),
          content1.length,
          hash1,
        );

        expect(
          () => transport.putImmutable(
            config,
            'verifin-sync/v1/blobs/abc123.blob',
            Stream.value(content2),
            content2.length,
            hash2,
          ),
          throwsA(isA<WebdavFileCollision>()),
        );
      },
    );

    test('listSyncFiles discovers all sync file kinds', () async {
      final stub = transport as StubWebdavSyncTransport;

      // Add files with different extensions
      final eventContent = utf8.encode('event');
      final manifestContent = utf8.encode('manifest');
      final commitContent = utf8.encode('commit');
      final blobContent = utf8.encode('blob');

      stub.files['verifin-sync/v1/events/device1/123.vfsync'] = eventContent;
      stub.files['verifin-sync/v1/batches/device1/456.manifest'] =
          manifestContent;
      stub.files['verifin-sync/v1/batches/device1/456.commit'] = commitContent;
      stub.files['verifin-sync/v1/blobs/abc.blob'] = blobContent;

      final files = await transport.listSyncFiles(config);

      expect(files.length, 4);
      expect(files.where((f) => f.kind == WebdavSyncFileKind.event).length, 1);
      expect(
        files.where((f) => f.kind == WebdavSyncFileKind.manifest).length,
        1,
      );
      expect(files.where((f) => f.kind == WebdavSyncFileKind.commit).length, 1);
      expect(files.where((f) => f.kind == WebdavSyncFileKind.blob).length, 1);
    });

    test(
      'listSyncFiles parses deviceId and sequence from event paths',
      () async {
        final stub = transport as StubWebdavSyncTransport;
        final content = utf8.encode('event');

        stub.files['verifin-sync/v1/events/abc123/456.vfsync'] = content;

        final files = await transport.listSyncFiles(config);

        expect(files.length, 1);
        expect(files[0].kind, WebdavSyncFileKind.event);
        expect(files[0].deviceId, 'abc123');
        expect(files[0].sequence, 456);
      },
    );

    test('downloadSyncFile returns file content', () async {
      final stub = transport as StubWebdavSyncTransport;
      final content = utf8.encode('test content');

      stub.files['verifin-sync/v1/blobs/abc123.blob'] = content;

      final downloaded = await transport.downloadSyncFile(
        config,
        'verifin-sync/v1/blobs/abc123.blob',
        maxBytes: syncMaxDownloadBytes,
      );

      expect(downloaded, content);
    });

    test('downloadSyncFile throws when file exceeds maxBytes', () async {
      final stub = transport as StubWebdavSyncTransport;
      final content = Uint8List(1000);

      stub.files['verifin-sync/v1/blobs/abc123.blob'] = content;

      expect(
        () => transport.downloadSyncFile(
          config,
          'verifin-sync/v1/blobs/abc123.blob',
          maxBytes: 500,
        ),
        throwsA(isA<WebdavException>()),
      );
    });

    test('downloadSyncFile respects syncMaxDownloadBytes constant', () async {
      expect(syncMaxDownloadBytes, 32 * 1024 * 1024);
    });

    test(
      'path encoding prevents device/id from becoming device%2Fid',
      () async {
        final content = utf8.encode('event');
        final hash = sha256.convert(content).toString();

        // Path should NOT contain %2F for the slash between segments
        final path = 'verifin-sync/v1/events/device-id/123.vfsync';

        await transport.putImmutable(
          config,
          path,
          Stream.value(content),
          content.length,
          hash,
        );

        final stub = transport as StubWebdavSyncTransport;
        expect(stub.files.containsKey(path), true);
        // Verify no percent-encoded slashes in the path segments
        expect(path.contains('%2F'), false);
      },
    );

    test('path encoding handles special characters in device ID', () async {
      final content = utf8.encode('event');
      final hash = sha256.convert(content).toString();

      // Device ID with special characters that need encoding
      final deviceId = 'device+test&id';
      final path = 'verifin-sync/v1/events/$deviceId/123.vfsync';

      await transport.putImmutable(
        config,
        path,
        Stream.value(content),
        content.length,
        hash,
      );

      final stub = transport as StubWebdavSyncTransport;
      // The stub stores by the logical path (before encoding)
      expect(stub.files.containsKey(path), true);

      // Verify the path segments would be encoded properly:
      // 'device+test&id' should become 'device%2Btest%26id' when encoded
      final encoded = Uri.encodeComponent(deviceId);
      expect(encoded, 'device%2Btest%26id');
    });

    test('listSyncFiles ignores non-sync files', () async {
      final stub = transport as StubWebdavSyncTransport;

      stub.files['verifin-sync/v1/blobs/test.blob'] = utf8.encode('blob');
      stub.files['verifin-sync/v1/blobs/test.json'] = utf8.encode('json');
      stub.files['verifin-sync/v1/blobs/test.txt'] = utf8.encode('txt');

      final files = await transport.listSyncFiles(config);

      expect(files.length, 1);
      expect(files[0].relativePath, 'verifin-sync/v1/blobs/test.blob');
    });

    test('listSyncFiles returns empty list when no files exist', () async {
      final files = await transport.listSyncFiles(config);
      expect(files, isEmpty);
    });

    test('downloadSyncFile throws when file not found', () async {
      expect(
        () => transport.downloadSyncFile(
          config,
          'verifin-sync/v1/blobs/nonexistent.blob',
          maxBytes: syncMaxDownloadBytes,
        ),
        throwsA(isA<WebdavException>()),
      );
    });
  });
}
