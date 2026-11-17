import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/util/remote_update_report.dart';

void main() {
  test('toJson emits status names and a plain-language error for failures', () {
    const failed = RemoteUpdateItemResult(
      item: 'deadexample/dead',
      status: RemoteUpdateStatus.failed,
      error: SocketException('offline'),
    );

    expect(failed.isFailure, isTrue);
    expect(failed.toJson(), {
      'item': 'deadexample/dead',
      'status': 'failed',
      'error': 'Check your internet connection and try again.',
    });
  });

  test('non-failure results omit the error field', () {
    const updated = RemoteUpdateItemResult(
      item: 'a/b',
      status: RemoteUpdateStatus.updated,
    );
    const current = RemoteUpdateItemResult(
      item: 'c/d',
      status: RemoteUpdateStatus.alreadyCurrent,
    );
    const pending = RemoteUpdateItemResult(
      item: 'e/f',
      status: RemoteUpdateStatus.pendingApproval,
    );

    expect(updated.toJson(), {'item': 'a/b', 'status': 'updated'});
    expect(current.toJson(), {'item': 'c/d', 'status': 'alreadyCurrent'});
    expect(pending.toJson(), {'item': 'e/f', 'status': 'pendingApproval'});
  });

  test('report exposes failures and serializes the results list', () {
    const report = RemoteUpdateReport([
      RemoteUpdateItemResult(item: 'a/b', status: RemoteUpdateStatus.updated),
      RemoteUpdateItemResult(
        item: 'c/d',
        status: RemoteUpdateStatus.failed,
        error: SocketException('offline'),
      ),
    ]);

    expect(report.hasFailures, isTrue);
    expect(report.failures, hasLength(1));
    expect(report.failures.single.item, 'c/d');
    expect(report.failures.single.error, isA<SocketException>());
    expect(report.toJson()['results'], hasLength(2));
  });
}
