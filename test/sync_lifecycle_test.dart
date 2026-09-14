import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/backup_settings.dart';
import 'package:verifin/app/sync/sync_coordinator.dart';
import 'package:verifin/app/sync/sync_engine.dart';

/// Task 8 Step 1: lifecycle and debounce tests.
///
/// Assert startup and resumed trigger one run each, rapid local mutations
/// collapse into one debounced run, manual sync bypasses debounce, concurrent
/// triggers use one global run, and auto-upload mode never invokes sync engine.
void main() {
  group('SyncCoordinator lifecycle', () {
    test('onStartup triggers immediate sync run', () {
      fakeAsync((async) {
        var runCount = 0;
        SyncTrigger? lastTrigger;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            lastTrigger = trigger;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        coordinator.onStartup();
        async.flushMicrotasks();

        expect(runCount, 1);
        expect(lastTrigger, SyncTrigger.startup);
      });
    });

    test('onResumed triggers immediate sync run', () {
      fakeAsync((async) {
        var runCount = 0;
        SyncTrigger? lastTrigger;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            lastTrigger = trigger;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        coordinator.onResumed();
        async.flushMicrotasks();

        expect(runCount, 1);
        expect(lastTrigger, SyncTrigger.resumed);
      });
    });

    test('onLocalMutation debounces rapid calls into one run', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
          debounceDuration: const Duration(milliseconds: 500),
        );

        // Rapid mutations within 500ms window
        coordinator.onLocalMutation();
        async.elapse(const Duration(milliseconds: 100));
        coordinator.onLocalMutation();
        async.elapse(const Duration(milliseconds: 100));
        coordinator.onLocalMutation();
        async.elapse(const Duration(milliseconds: 100));
        coordinator.onLocalMutation();

        // Still within window - no run yet
        expect(runCount, 0);

        // Let debounce expire
        async.elapse(const Duration(milliseconds: 500));

        expect(runCount, 1, reason: 'Four mutations should collapse into one run');
      });
    });

    test('runManual bypasses debounce and runs immediately', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
          debounceDuration: const Duration(milliseconds: 500),
        );

        final resultFuture = coordinator.runManual();
        async.flushMicrotasks();

        expect(runCount, 1, reason: 'Manual sync should run immediately');

        async.elapse(const Duration(milliseconds: 1000));
        resultFuture.then((result) {
          expect(result.errorCode, isNull);
        });
      });
    });

    test('concurrent triggers share one global run', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        // Start multiple triggers concurrently
        coordinator.onStartup();
        coordinator.onResumed();
        coordinator.onLocalMutation();
        async.flushMicrotasks();

        expect(runCount, 1, reason: 'Concurrent triggers should share one run');

        // Complete the run
        async.elapse(const Duration(milliseconds: 200));

        // Debounced mutation may trigger second run
        expect(runCount, greaterThanOrEqualTo(1));
        expect(runCount, lessThanOrEqualTo(2));
      });
    });

    test('auto-upload mode does not trigger sync engine', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoUpload,
          runSync: (trigger) async {
            runCount++;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        coordinator.onStartup();
        coordinator.onResumed();
        coordinator.onLocalMutation();
        async.elapse(const Duration(seconds: 2));

        expect(runCount, 0, reason: 'autoUpload mode should not invoke sync engine');
      });
    });

    test('manual mode does not trigger sync engine', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.manual,
          runSync: (trigger) async {
            runCount++;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        coordinator.onStartup();
        coordinator.onResumed();
        coordinator.onLocalMutation();
        async.elapse(const Duration(seconds: 2));

        expect(runCount, 0, reason: 'manual mode should not invoke sync engine');
      });
    });

    test('runManual works in manual mode', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.manual,
          runSync: (trigger) async {
            runCount++;
            return const SyncRunResult(
              uploaded: 1,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        final resultFuture = coordinator.runManual();
        async.flushMicrotasks();

        expect(runCount, 1, reason: 'Manual sync should work even in manual mode');

        resultFuture.then((result) {
          expect(result.uploaded, 1);
        });
      });
    });

    test('dispose cancels pending debounce', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
          debounceDuration: const Duration(milliseconds: 500),
        );

        coordinator.onLocalMutation();
        coordinator.dispose();

        async.elapse(const Duration(seconds: 2));

        expect(runCount, 0, reason: 'Disposed coordinator should not run');
      });
    });
  });
}
