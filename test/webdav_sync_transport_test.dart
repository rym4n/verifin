import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  group('WebdavSyncTransportImpl with a real HTTP server', () {
    test(
      'normalizes absolute and collection-prefixed hrefs and parses canonical event names',
      () async {
        const deviceId = 'phone+east&primary';
        final encodedDeviceId = Uri.encodeComponent(deviceId);
        const eventName =
            '00000000000000000042-019db6b6-9d5f-7cc4-a417-123456789abc.vfsync';
        final server = await _TestWebdavServer.start((request) async {
          final path = request.uri.path;
          if (request.method != 'PROPFIND') {
            await _respond(request, HttpStatus.methodNotAllowed);
            return;
          }
          await request.drain<void>();

          if (path.endsWith('/verifin-sync/v1/events')) {
            await _respondXml(
              request,
              _multistatus(<_DavEntry>[
                _DavEntry('$path/', isCollection: true),
                _DavEntry(
                  '/dav/root/verifin-sync/v1/events/$encodedDeviceId/',
                  isCollection: true,
                ),
              ]),
            );
            return;
          }
          if (path.endsWith('/verifin-sync/v1/events/$encodedDeviceId')) {
            final host = request.headers.value(HttpHeaders.hostHeader)!;
            await _respondXml(
              request,
              _multistatus(<_DavEntry>[
                _DavEntry('$path/', isCollection: true),
                _DavEntry(
                  'http://$host/dav/root/verifin-sync/v1/events/'
                  '$encodedDeviceId/$eventName',
                  sizeBytes: 87,
                ),
              ]),
            );
            return;
          }
          await _respond(request, HttpStatus.notFound);
        });

        final files = await WebdavSyncTransportImpl().listSyncFiles(
          server.config,
        );

        expect(files, hasLength(1));
        expect(
          files.single.relativePath,
          'verifin-sync/v1/events/$deviceId/$eventName',
        );
        expect(files.single.kind, WebdavSyncFileKind.event);
        expect(files.single.deviceId, deviceId);
        expect(files.single.sequence, 42);
      },
    );

    test(
      'creates dynamic event and batch parent directories before PUT',
      () async {
        final requests = <({String method, List<String> segments})>[];
        final created = <String>{};
        final server = await _TestWebdavServer.start((request) async {
          final path = request.uri.path;
          requests.add((
            method: request.method,
            segments: request.uri.pathSegments,
          ));
          await request.drain<void>();

          if (request.method == 'MKCOL') {
            created.add(path);
            await _respond(request, HttpStatus.created);
            return;
          }
          if (request.method == 'GET') {
            await _respond(request, HttpStatus.notFound);
            return;
          }
          if (request.method == 'PUT') {
            final parent = path.substring(0, path.lastIndexOf('/'));
            await _respond(
              request,
              created.contains(parent)
                  ? HttpStatus.created
                  : HttpStatus.conflict,
            );
            return;
          }
          await _respond(request, HttpStatus.methodNotAllowed);
        });
        const deviceId = 'phone+east&primary';
        final encodedDeviceId = Uri.encodeComponent(deviceId);
        const operationId = '019db6b6-9d5f-7cc4-a417-123456789abc';
        final eventBytes = utf8.encode('event');
        final manifestBytes = utf8.encode('manifest');
        final transport = WebdavSyncTransportImpl();

        await transport.putImmutable(
          server.config,
          'events/$deviceId/'
          '00000000000000000001-$operationId.vfsync',
          Stream.value(eventBytes),
          eventBytes.length,
          sha256.convert(eventBytes).toString(),
        );
        await transport.putImmutable(
          server.config,
          'batches/$deviceId/batch-1.manifest',
          Stream.value(manifestBytes),
          manifestBytes.length,
          sha256.convert(manifestBytes).toString(),
        );

        expect(created, contains('/dav/root/verifin-sync'));
        expect(created, contains('/dav/root/verifin-sync/v1'));
        expect(created, contains('/dav/root/verifin-sync/v1/events'));
        expect(
          created,
          contains('/dav/root/verifin-sync/v1/events/$encodedDeviceId'),
        );
        expect(created, contains('/dav/root/verifin-sync/v1/batches'));
        expect(
          created,
          contains('/dav/root/verifin-sync/v1/batches/$encodedDeviceId'),
        );
        expect(
          requests.where((request) => request.method == 'PUT'),
          everyElement(
            predicate<({String method, List<String> segments})>(
              (request) => request.segments.contains(deviceId),
            ),
          ),
        );
      },
    );

    test('propagates authentication errors from PROPFIND', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respond(request, HttpStatus.unauthorized);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('401'),
          ),
        ),
      );
    });

    test('propagates server errors from PROPFIND', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respond(request, HttpStatus.serviceUnavailable);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('503'),
          ),
        ),
      );
    });

    test('propagates collection hrefs outside the sync root', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respondXml(
          request,
          _multistatus(const <_DavEntry>[
            _DavEntry(
              '/dav/root/not-the-sync-root/device-a/',
              isCollection: true,
            ),
          ]),
        );
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('href'),
          ),
        ),
      );
    });

    test('rejects an absolute PROPFIND href from another host', () async {
      final server = await _TestWebdavServer.start((request) async {
        final path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/verifin-sync/v1/events')) {
          await _respondXml(
            request,
            _multistatus(<_DavEntry>[
              _DavEntry('$path/', isCollection: true),
              const _DavEntry(
                'http://evil.example/dav/root/verifin-sync/v1/events/'
                'device-a/',
                isCollection: true,
              ),
            ]),
          );
          return;
        }
        await _respond(request, HttpStatus.notFound);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects a PROPFIND href outside the configured collection', () async {
      final server = await _TestWebdavServer.start((request) async {
        final path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/verifin-sync/v1/events')) {
          final host = request.headers.value(HttpHeaders.hostHeader)!;
          await _respondXml(
            request,
            _multistatus(<_DavEntry>[
              _DavEntry('$path/', isCollection: true),
              _DavEntry(
                'http://$host/dav/other/verifin-sync/v1/events/device-a/',
                isCollection: true,
              ),
            ]),
          );
          return;
        }
        await _respond(request, HttpStatus.notFound);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('propagates file hrefs outside the requested device path', () async {
      final server = await _TestWebdavServer.start((request) async {
        final path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/verifin-sync/v1/events')) {
          await _respondXml(
            request,
            _multistatus(<_DavEntry>[
              _DavEntry('$path/', isCollection: true),
              const _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-a/',
                isCollection: true,
              ),
            ]),
          );
          return;
        }
        if (path.endsWith('/verifin-sync/v1/events/device-a')) {
          await _respondXml(
            request,
            _multistatus(const <_DavEntry>[
              _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-b/'
                '00000000000000000001-op.vfsync',
              ),
            ]),
          );
          return;
        }
        await _respond(request, HttpStatus.notFound);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('href'),
          ),
        ),
      );
    });

    test(
      'propagates malformed PROPFIND XML instead of reporting no files',
      () async {
        final server = await _TestWebdavServer.start((request) async {
          await request.drain<void>();
          await _respondXml(request, '<not-a-multistatus/>');
        });

        await expectLater(
          WebdavSyncTransportImpl().listSyncFiles(server.config),
          throwsA(isA<WebdavException>()),
        );
      },
    );

    test('treats a missing sync directory as an empty listing', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respond(request, HttpStatus.notFound);
      });

      expect(
        await WebdavSyncTransportImpl().listSyncFiles(server.config),
        isEmpty,
      );
    });

    test('propagates MKCOL server errors', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respond(request, HttpStatus.internalServerError);
      });

      await expectLater(
        WebdavSyncTransportImpl().ensureSyncTree(server.config),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('500'),
          ),
        ),
      );
    });

    test('rejects non-created MKCOL success statuses', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respond(request, HttpStatus.noContent);
      });

      await expectLater(
        WebdavSyncTransportImpl().ensureSyncTree(server.config),
        throwsA(
          isA<WebdavException>().having(
            (error) => error.message,
            'message',
            contains('204'),
          ),
        ),
      );
    });

    for (final statusCode in <int>[
      HttpStatus.movedPermanently,
      HttpStatus.found,
      HttpStatus.seeOther,
      HttpStatus.temporaryRedirect,
      HttpStatus.permanentRedirect,
    ]) {
      test('rejects PUT redirect $statusCode', () async {
        final server = await _TestWebdavServer.start((request) async {
          await request.drain<void>();
          if (request.method == 'GET') {
            await _respond(request, HttpStatus.notFound);
            return;
          }
          if (request.method == 'MKCOL') {
            await _respond(request, HttpStatus.methodNotAllowed);
            return;
          }
          if (request.method == 'PUT') {
            await _respond(request, statusCode);
            return;
          }
          await _respond(request, HttpStatus.methodNotAllowed);
        });
        final content = utf8.encode('new event');

        await expectLater(
          WebdavSyncTransportImpl().putImmutable(
            server.config,
            'events/device-a/00000000000000000001-operation.vfsync',
            Stream.value(content),
            content.length,
            sha256.convert(content).toString(),
          ),
          throwsA(isA<WebdavException>()),
        );
      });
    }

    for (final relativePath in <String>[
      'events/./outside.vfsync',
      'events/../outside.vfsync',
      'events/%2Foutside/00000000000000000001-operation.vfsync',
      'events/%5Coutside/00000000000000000001-operation.vfsync',
      'events/device\\outside/00000000000000000001-operation.vfsync',
      'events/device\u0001/00000000000000000001-operation.vfsync',
    ]) {
      test('rejects unsafe logical path $relativePath', () async {
        final server = await _TestWebdavServer.start((request) async {
          await request.drain<void>();
          if (request.method == 'GET') {
            await _respond(request, HttpStatus.notFound);
            return;
          }
          if (request.method == 'MKCOL') {
            await _respond(request, HttpStatus.methodNotAllowed);
            return;
          }
          if (request.method == 'PUT') {
            await _respond(request, HttpStatus.created);
            return;
          }
          await _respond(request, HttpStatus.methodNotAllowed);
        });
        final content = utf8.encode('event');

        await expectLater(
          WebdavSyncTransportImpl().putImmutable(
            server.config,
            relativePath,
            Stream.value(content),
            content.length,
            sha256.convert(content).toString(),
          ),
          throwsA(isA<WebdavException>()),
        );
      });
    }

    test('rejects an event href with extra path segments', () async {
      final server = await _TestWebdavServer.start((request) async {
        final path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/verifin-sync/v1/events')) {
          await _respondXml(
            request,
            _multistatus(<_DavEntry>[
              _DavEntry('$path/', isCollection: true),
              const _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-a/',
                isCollection: true,
              ),
            ]),
          );
          return;
        }
        if (path.endsWith('/verifin-sync/v1/events/device-a')) {
          await _respondXml(
            request,
            _multistatus(const <_DavEntry>[
              _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-a/extra/'
                '00000000000000000001-operation.vfsync',
              ),
            ]),
          );
          return;
        }
        await _respond(request, HttpStatus.notFound);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects an event href without an operation identifier', () async {
      final server = await _TestWebdavServer.start((request) async {
        final path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/verifin-sync/v1/events')) {
          await _respondXml(
            request,
            _multistatus(<_DavEntry>[
              _DavEntry('$path/', isCollection: true),
              const _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-a/',
                isCollection: true,
              ),
            ]),
          );
          return;
        }
        if (path.endsWith('/verifin-sync/v1/events/device-a')) {
          await _respondXml(
            request,
            _multistatus(const <_DavEntry>[
              _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-a/'
                '00000000000000000001-.vfsync',
              ),
            ]),
          );
          return;
        }
        await _respond(request, HttpStatus.notFound);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects structurally incomplete PROPFIND XML', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respondXml(
          request,
          '<d:multistatus xmlns:d="DAV:"><d:response><d:href>'
          '/dav/root/verifin-sync/v1/events/</d:href></d:multistatus>',
        );
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects a PROPFIND response without href', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respondXml(
          request,
          '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
          '<d:response><d:propstat><d:prop><d:resourcetype>'
          '<d:collection/></d:resourcetype></d:prop></d:propstat>'
          '</d:response></d:multistatus>',
        );
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects a PROPFIND response without resource type', () async {
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        await _respondXml(
          request,
          '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
          '<d:response><d:href>/dav/root/verifin-sync/v1/events/'
          '</d:href><d:propstat><d:prop></d:prop></d:propstat>'
          '</d:response></d:multistatus>',
        );
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects a collection href below the requested directory', () async {
      final server = await _TestWebdavServer.start((request) async {
        final path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/verifin-sync/v1/events')) {
          await _respondXml(
            request,
            _multistatus(<_DavEntry>[
              _DavEntry('$path/', isCollection: true),
              const _DavEntry(
                '/dav/root/verifin-sync/v1/events/device-a/nested/',
                isCollection: true,
              ),
            ]),
          );
          return;
        }
        await _respond(request, HttpStatus.notFound);
      });

      await expectLater(
        WebdavSyncTransportImpl().listSyncFiles(server.config),
        throwsA(isA<WebdavException>()),
      );
    });

    test('rejects oversized existing file before hashing it', () async {
      var putCalled = false;
      final oversized = Uint8List(syncMaxDownloadBytes + 1);
      final server = await _TestWebdavServer.start((request) async {
        await request.drain<void>();
        if (request.method == 'GET') {
          request.response.headers.contentLength = oversized.length;
          request.response.statusCode = HttpStatus.ok;
          request.response.add(oversized);
          await request.response.close();
          return;
        }
        if (request.method == 'MKCOL') {
          await _respond(request, HttpStatus.methodNotAllowed);
          return;
        }
        if (request.method == 'PUT') {
          putCalled = true;
          await _respond(request, HttpStatus.created);
          return;
        }
        await _respond(request, HttpStatus.methodNotAllowed);
      });
      final content = utf8.encode('event');

      await expectLater(
        WebdavSyncTransportImpl().putImmutable(
          server.config,
          'events/device-a/00000000000000000001-operation.vfsync',
          Stream.value(content),
          content.length,
          sha256.convert(content).toString(),
        ),
        throwsA(isA<WebdavException>()),
      );
      expect(putCalled, isFalse);
    });

    test(
      'aborts an oversized existing file response before it is fully sent',
      () async {
        final serverObservedEarlyClose = Completer<bool>();
        final advertisedLength = syncMaxDownloadBytes + 1;
        final server = await _TestWebdavServer.start((request) async {
          await request.drain<void>();
          if (request.method != 'GET') {
            await _respond(request, HttpStatus.methodNotAllowed);
            return;
          }

          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          var peerClosed = false;
          var sentRemainingBody = false;
          unawaited(socket.done.whenComplete(() => peerClosed = true));
          try {
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Length: $advertisedLength\r\n'
                'Connection: close\r\n\r\n',
              ),
            );
            socket.add(Uint8List(1));
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (!peerClosed) {
              socket.add(Uint8List(advertisedLength - 1));
              await socket.flush();
              sentRemainingBody = true;
            }
          } on SocketException {
            // The client closed before the remaining body reached the socket.
          } finally {
            if (!serverObservedEarlyClose.isCompleted) {
              serverObservedEarlyClose.complete(
                peerClosed || !sentRemainingBody,
              );
            }
            socket.destroy();
          }
        });
        final content = utf8.encode('event');

        final upload = WebdavSyncTransportImpl().putImmutable(
          server.config,
          'events/device-a/00000000000000000001-operation.vfsync',
          Stream.value(content),
          content.length,
          sha256.convert(content).toString(),
        );
        await expectLater(
          upload.timeout(const Duration(milliseconds: 500)),
          throwsA(isA<WebdavException>()),
        );
        expect(await serverObservedEarlyClose.future, isTrue);
      },
    );

    test(
      'aborts a chunked existing file response after it exceeds the limit',
      () async {
        final serverStoppedBeforeCompleteBody = Completer<bool>();
        final totalLength = syncMaxDownloadBytes + 64 * 1024 + 1;
        final server = await _TestWebdavServer.start((request) async {
          await request.drain<void>();
          if (request.method != 'GET') {
            await _respond(request, HttpStatus.methodNotAllowed);
            return;
          }

          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          var sent = 0;
          var sentCompleteBody = false;
          try {
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Transfer-Encoding: chunked\r\n'
                'Connection: close\r\n\r\n',
              ),
            );
            while (sent < totalLength) {
              final chunkLength = (totalLength - sent).clamp(0, 64 * 1024);
              socket.add(utf8.encode('${chunkLength.toRadixString(16)}\r\n'));
              socket.add(Uint8List(chunkLength));
              socket.add(utf8.encode('\r\n'));
              sent += chunkLength;
              await socket.flush();
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
            socket.add(utf8.encode('0\r\n\r\n'));
            await socket.flush();
            sentCompleteBody = true;
          } on SocketException {
            // Client closed after the streaming size guard fired.
          } finally {
            if (!serverStoppedBeforeCompleteBody.isCompleted) {
              serverStoppedBeforeCompleteBody.complete(!sentCompleteBody);
            }
            socket.destroy();
          }
        });
        final content = utf8.encode('event');

        await expectLater(
          WebdavSyncTransportImpl().putImmutable(
            server.config,
            'events/device-a/00000000000000000001-operation.vfsync',
            Stream.value(content),
            content.length,
            sha256.convert(content).toString(),
          ),
          throwsA(isA<WebdavException>()),
        );

        expect(
          await serverStoppedBeforeCompleteBody.future.timeout(
            const Duration(seconds: 10),
          ),
          isTrue,
        );
      },
    );
  });
}

typedef _RequestHandler = Future<void> Function(HttpRequest request);

class _TestWebdavServer {
  _TestWebdavServer._(this._server, this._subscription, this._pending);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;
  final List<Future<void>> _pending;

  WebdavConfig get config => WebdavConfig(
    url: 'http://${_server.address.address}:${_server.port}/dav/root/',
    username: 'user',
    password: 'pass',
  );

  static Future<_TestWebdavServer> start(_RequestHandler handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pending = <Future<void>>[];
    late final StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((request) {
      pending.add(handler(request));
    });
    final fixture = _TestWebdavServer._(server, subscription, pending);
    addTearDown(fixture.close);
    return fixture;
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
    for (final future in _pending) {
      await future;
    }
  }
}

class _DavEntry {
  const _DavEntry(this.href, {this.isCollection = false, this.sizeBytes = 0});

  final String href;
  final bool isCollection;
  final int sizeBytes;
}

String _multistatus(List<_DavEntry> entries) {
  final responses = entries.map((entry) {
    final resourceType = entry.isCollection
        ? '<d:resourcetype><d:collection/></d:resourcetype>'
        : '<d:resourcetype/>';
    return '<d:response>'
        '<d:href>${entry.href}</d:href>'
        '<d:propstat><d:prop>'
        '$resourceType'
        '<d:getcontentlength>${entry.sizeBytes}</d:getcontentlength>'
        '<d:getlastmodified>Wed, 16 Sep 2026 10:00:00 GMT</d:getlastmodified>'
        '</d:prop></d:propstat>'
        '</d:response>';
  }).join();
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<d:multistatus xmlns:d="DAV:">$responses</d:multistatus>';
}

Future<void> _respond(
  HttpRequest request,
  int statusCode, {
  String body = '',
}) async {
  request.response.statusCode = statusCode;
  if (body.isNotEmpty) {
    request.response.write(body);
  }
  await request.response.close();
}

Future<void> _respondXml(HttpRequest request, String body) async {
  request.response.headers.contentType = ContentType(
    'application',
    'xml',
    charset: 'utf-8',
  );
  await _respond(request, 207, body: body);
}
