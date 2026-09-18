import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/webdav_client.dart' show webdavList;
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/app/sync/sync_snapshot.dart';
import 'package:verifin/app/sync/webdav_sync_transport.dart';
import 'package:verifin/app/sync/webdav_sync_transport_stub.dart';

const _config = WebdavConfig(
  url: 'https://dav.example.com/verifin/',
  username: 'user',
  password: 'pass',
);
const _deviceId = '4f8c19e6d7134be39c25820b2f55a912';

void main() {
  group('composite WebDAV snapshot transport', () {
    test(
      'root listing accepts only strict v2 snapshot and blob names',
      () async {
        final transport = StubWebdavSyncTransport();
        final snapshotBytes = utf8.encode('{"protocolVersion":2}');
        final snapshot = _snapshotName(snapshotBytes);
        final blobBytes = utf8.encode('blob');
        final blob = SnapshotFileName.blob(
          fileHash: sha256.convert(blobBytes).toString(),
        );
        transport.files[snapshot.toString()] = snapshotBytes;
        transport.files[blob.toString()] = blobBytes;
        transport.files['verifin-backup-20260918.zip'] = utf8.encode('backup');
        transport.files['verifin-sync-v2-invalid.json'] = utf8.encode('bad');

        final listing = await transport.listRoot(_config);

        expect(listing.files.map((file) => file.name.toString()).toSet(), {
          snapshot.toString(),
          blob.toString(),
        });
        expect(transport.snapshotRequestCounts['PROPFIND'], 1);
        expect(transport.v1RequestCounts, isEmpty);
      },
    );

    test(
      'snapshot PUT is idempotent but rejects same name with other bytes',
      () async {
        final transport = StubWebdavSyncTransport();
        final bytes = utf8.encode('snapshot');
        final name = _snapshotName(bytes);

        await transport.putSnapshot(
          _config,
          name,
          Stream.value(bytes),
          bytes.length,
        );
        await transport.putSnapshot(
          _config,
          name,
          Stream.value(bytes),
          bytes.length,
        );
        transport.files[name.toString()] = utf8.encode('other');
        await expectLater(
          transport.putSnapshot(
            _config,
            name,
            Stream.value(bytes),
            bytes.length,
          ),
          throwsA(isA<WebdavFileCollision>()),
        );

        expect(transport.snapshotRequestCounts['PUT'], 3);
        expect(transport.v1RequestCounts, isEmpty);
      },
    );

    test('download returns exact bytes with parsed source metadata', () async {
      final transport = StubWebdavSyncTransport();
      final bytes = utf8.encode('snapshot');
      final name = _snapshotName(bytes);
      transport.files[name.toString()] = bytes;

      final downloaded = await transport.downloadRootFile(
        _config,
        name,
        maxBytes: 1024,
      );

      expect(downloaded.name.toString(), name.toString());
      expect(downloaded.bytes, bytes);
      expect(transport.snapshotRequestCounts['GET'], 1);
      expect(transport.v1RequestCounts, isEmpty);
    });

    test('v1 bridge calls do not increment snapshot counters', () async {
      final transport = StubWebdavSyncTransport();

      await transport.ensureSyncTree(_config);
      await transport.listSyncFiles(_config);

      expect(transport.v1RequestCounts['MKCOL'], 1);
      expect(transport.v1RequestCounts['PROPFIND'], 1);
      expect(transport.snapshotRequestCounts, isEmpty);
    });
  });

  group('real HTTP root snapshot transport', () {
    test('discovers root files with one PROPFIND and no MKCOL', () async {
      final snapshotBytes = utf8.encode('snapshot');
      final snapshot = _snapshotName(snapshotBytes);
      final methods = <String>[];
      final server = await _SnapshotServer.start((request) async {
        methods.add(request.method);
        await request.drain<void>();
        if (request.method != 'PROPFIND') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.multiStatus;
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        request.response.write('''
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
  </d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/${snapshot.toString()}</d:href><d:propstat><d:prop>
    <d:getcontentlength>${snapshotBytes.length}</d:getcontentlength><d:resourcetype/>
  </d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/verifin-backup.zip</d:href><d:propstat><d:prop>
    <d:getcontentlength>1</d:getcontentlength><d:resourcetype/>
  </d:prop></d:propstat></d:response>
</d:multistatus>''');
        await request.response.close();
      });
      addTearDown(server.close);

      final listing = await WebdavSyncTransportImpl().listRoot(server.config);

      expect(listing.files.map((file) => file.name.toString()), [
        snapshot.toString(),
      ]);
      expect(methods, ['PROPFIND']);
    });

    test('uploads and deletes a root snapshot without MKCOL or GET', () async {
      final bytes = utf8.encode('snapshot');
      final name = _snapshotName(bytes);
      final methods = <String>[];
      final server = await _SnapshotServer.start((request) async {
        methods.add(request.method);
        if (request.method == 'PUT') {
          expect(request.uri.path, '/dav/${name.toString()}');
          expect(
            await request.fold<int>(0, (sum, chunk) => sum + chunk.length),
            bytes.length,
          );
          request.response.statusCode = HttpStatus.created;
        } else if (request.method == 'DELETE') {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.noContent;
        } else {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final transport = WebdavSyncTransportImpl();

      await transport.putSnapshot(
        server.config,
        name,
        Stream.value(bytes),
        bytes.length,
      );
      await transport.deleteSnapshot(server.config, name);

      expect(methods, ['PUT', 'DELETE']);
    });

    test(
      'follows same-origin GET redirect and verifies filename hash',
      () async {
        final bytes = utf8.encode('snapshot');
        final name = _snapshotName(bytes);
        var redirectedHadAuth = false;
        final server = await _SnapshotServer.start((request) async {
          await request.drain<void>();
          if (request.uri.queryParameters['download'] != '1') {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              '${request.uri.path}?download=1',
            );
          } else {
            redirectedHadAuth =
                request.headers.value(HttpHeaders.authorizationHeader) != null;
            request.response.statusCode = HttpStatus.ok;
            request.response.add(bytes);
          }
          await request.response.close();
        });
        addTearDown(server.close);

        final downloaded = await WebdavSyncTransportImpl().downloadRootFile(
          server.config,
          name,
          maxBytes: 1024,
        );

        expect(downloaded.bytes, bytes);
        expect(redirectedHadAuth, isTrue);
      },
    );

    test(
      'rejects response bytes that do not match the filename hash',
      () async {
        final name = _snapshotName(utf8.encode('expected'));
        final server = await _SnapshotServer.start((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.ok;
          request.response.add(utf8.encode('corrupt'));
          await request.response.close();
        });
        addTearDown(server.close);

        await expectLater(
          WebdavSyncTransportImpl().downloadRootFile(
            server.config,
            name,
            maxBytes: 1024,
          ),
          throwsA(isA<WebdavException>()),
        );
      },
    );

    test(
      'rejects a root PROPFIND href outside the configured origin',
      () async {
        final server = await _SnapshotServer.start((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.multiStatus;
          request.response.write('''
<d:multistatus xmlns:d="DAV:"><d:response>
  <d:href>https://evil.example/private.json</d:href>
  <d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength>
  <d:resourcetype/></d:prop></d:propstat>
</d:response></d:multistatus>''');
          await request.response.close();
        });
        addTearDown(server.close);

        await expectLater(
          WebdavSyncTransportImpl().listRoot(server.config),
          throwsA(isA<WebdavException>()),
        );
      },
    );

    test(
      'aborts a root download when streamed bytes exceed the bound',
      () async {
        final name = _snapshotName(utf8.encode('12345'));
        final server = await _SnapshotServer.start((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.ok;
          request.response.add(utf8.encode('123'));
          request.response.add(utf8.encode('45'));
          await request.response.close();
        });
        addTearDown(server.close);

        await expectLater(
          WebdavSyncTransportImpl().downloadRootFile(
            server.config,
            name,
            maxBytes: 4,
          ),
          throwsA(isA<WebdavException>()),
        );
      },
    );
  });

  test('ordinary backup listing hides v2 files and unsafe hrefs', () async {
    final snapshotBytes = utf8.encode('snapshot');
    final snapshot = _snapshotName(snapshotBytes);
    final server = await _SnapshotServer.start((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.write('''
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/verifin-backup-1.zip</d:href><d:propstat><d:prop>
    <d:getcontentlength>1</d:getcontentlength><d:resourcetype/>
  </d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/${snapshot.toString()}</d:href><d:propstat><d:prop>
    <d:getcontentlength>1</d:getcontentlength><d:resourcetype/>
  </d:prop></d:propstat></d:response>
  <d:response><d:href>https://evil.example/backup.zip</d:href><d:propstat><d:prop>
    <d:getcontentlength>1</d:getcontentlength><d:resourcetype/>
  </d:prop></d:propstat></d:response>
</d:multistatus>''');
      await request.response.close();
    });
    addTearDown(server.close);

    final files = await webdavList(server.config);

    expect(files.map((file) => file.name), ['verifin-backup-1.zip']);
  });
}

SnapshotFileName _snapshotName(List<int> bytes) => SnapshotFileName.snapshot(
  deviceId: _deviceId,
  snapshotSequence: 1,
  createdAtUtc: DateTime.utc(2026, 9, 18, 3, 15, 22, 417),
  fileHash: sha256.convert(bytes).toString(),
);

class _SnapshotServer {
  _SnapshotServer._(this._server, this.config);

  final HttpServer _server;
  final WebdavConfig config;

  static Future<_SnapshotServer> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    return _SnapshotServer._(
      server,
      WebdavConfig(
        url: 'http://${server.address.host}:${server.port}/dav/',
        username: 'user',
        password: 'pass',
      ),
    );
  }

  Future<void> close() => _server.close(force: true);
}
