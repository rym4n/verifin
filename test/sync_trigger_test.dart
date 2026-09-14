import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/backup_settings.dart';
import 'package:verifin/app/sync/sync_coordinator.dart';
import 'package:verifin/app/sync/sync_engine.dart';

/// Task 8 Step 1: trigger deduplication and error propagation tests.
void main() {
  group('SyncCoordinator trigger deduplication', () {
    test('mutation during active run triggers rerun after completion', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        // Start first run
        coordinator.onStartup();
        async.flushMicrotasks();
        expect(runCount, 1);

        // Mutation arrives during run
        async.elapse(const Duration(milliseconds: 100));
        coordinator.onLocalMutation();

        // First run completes
        async.elapse(const Duration(milliseconds: 200));

        // Debounced mutation should trigger second run
        async.elapse(const Duration(milliseconds: 500));
        expect(runCount, 2, reason: 'Mutation during run should trigger rerun');
      });
    });

    test('multiple mutations during run collapse into one rerun', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
          debounceDuration: const Duration(milliseconds: 500),
        );

        // Start first run
        coordinator.onStartup();
        async.flushMicrotasks();

        // Multiple mutations during run
        async.elapse(const Duration(milliseconds: 50));
        coordinator.onLocalMutation();
        async.elapse(const Duration(milliseconds: 50));
        coordinator.onLocalMutation();
        async.elapse(const Duration(milliseconds: 50));
        coordinator.onLocalMutation();

        // Complete first run
        async.elapse(const Duration(milliseconds: 200));

        // Wait for debounce
        async.elapse(const Duration(milliseconds: 500));

        expect(runCount, 2, reason: 'Multiple mutations should collapse into one rerun');
      });
    });

    test('manual sync during active run waits for completion', () {
      fakeAsync((async) {
        var runCount = 0;

        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            runCount++;
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return SyncRunResult(
              uploaded: runCount,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        // Start automatic run
        coordinator.onStartup();
        async.flushMicrotasks();
        expect(runCount, 1);

        // Manual sync arrives during run
        async.elapse(const Duration(milliseconds: 100));
        final manualResult = coordinator.runManual();

        // Complete first run
        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();

        // Manual should trigger second run
        expect(runCount, 2);

        manualResult.then((result) {
          expect(result.uploaded, 2);
        });
      });
    });

    test('error in sync run propagates to caller', () {
      fakeAsync((async) {
        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
              errorCode: 'network_error',
            );
          },
        );

        final result = coordinator.runManual();
        async.flushMicrotasks();

        result.then((r) {
          expect(r.errorCode, 'network_error');
        });
      });
    });

    test('mode switch from autoSync to manual stops automatic runs', () {
      fakeAsync((async) {
        var runCount = 0;
        var mode = BackupTransportMode.autoSync;

        final coordinator = SyncCoordinator(
          getTransportMode: () => mode,
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
        async.flushMicrotasks();
        expect(runCount, 1);

        // Switch mode
        mode = BackupTransportMode.manual;

        coordinator.onResumed();
        coordinator.onLocalMutation();
        async.elapse(const Duration(seconds: 2));

        expect(runCount, 1, reason: 'No automatic runs after switching to manual');
      });
    });

    test('isRunning reflects active sync state', () {
      fakeAsync((async) {
        final coordinator = SyncCoordinator(
          getTransportMode: () => BackupTransportMode.autoSync,
          runSync: (trigger) async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return const SyncRunResult(
              uploaded: 0,
              downloaded: 0,
              conflicts: 0,
              pending: 0,
            );
          },
        );

        expect(coordinator.isRunning, isFalse);

        coordinator.onStartup();
        async.flushMicrotasks();
        expect(coordinator.isRunning, isTrue);

        async.elapse(const Duration(milliseconds: 300));
        expect(coordinator.isRunning, isFalse);
      });
    });

    test('rapid manual calls share same run', () {
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

        final result1 = coordinator.runManual();
        final result2 = coordinator.runManual();
        final result3 = coordinator.runManual();
        async.flushMicrotasks();

        expect(runCount, 1, reason: 'Rapid manual calls should share one run');

        async.elapse(const Duration(milliseconds: 200));

        expect(identical(result1, result2), isFalse);
        expect(identical(result2, result3), isFalse);
      });
    });
  });
}
