import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/offline/offline_crypto.dart';
import 'package:jibhr/core/offline/offline_policy.dart';

void main() {
  test('period status names cover the whole period', () {
    expect(periodStatusLabel('none'), 'بدون گزارش');
    expect(periodStatusLabel('pending'), 'در انتظار بررسی');
    expect(periodStatusLabel('approved'), 'تأییدشده');
    expect(periodStatusLabel('partial'), 'تأیید جزئی');
    expect(periodStatusLabel('has_rejected'), 'دارای موارد ردشده');
    expect(periodStatusLabel('needs_revision'), 'نیازمند اصلاح');
  });

  test('offline mode blocks writes and expires after 72 hours', () {
    expect(offlineBlocksRequest('POST', '/rest/v1/rpc/clock_in'), isTrue);
    expect(offlineBlocksRequest('POST', '/rest/v1/rpc/decide_task'), isTrue);
    expect(offlineBlocksRequest('POST', '/rest/v1/rpc/report_export'), isTrue);
    expect(offlineBlocksRequest('POST', '/rest/v1/rpc/my_session'), isFalse);
    expect(offlineBlocksRequest('POST', '/rest/v1/rpc/dashboard_people'), isFalse);
    expect(offlineBlocksRequest('GET', '/rest/v1/tasks'), isFalse);
    expect(offlineBlocksRequest('POST', '/auth/v1/logout'), isFalse);
    final now = DateTime.utc(2026, 11, 5, 12);
    expect(
      offlineAccessOpen(validatedAt: now.subtract(const Duration(hours: 71)), now: now, online: false),
      isTrue,
    );
    expect(
      offlineAccessOpen(validatedAt: now.subtract(const Duration(hours: 73)), now: now, online: false),
      isFalse,
    );
    expect(offlineAccessOpen(validatedAt: null, now: now, online: false), isFalse);
  });

  test('cached text is not stored in the clear', () async {
    final key = await newCacheKey();
    final stored = await encodeCache({'name': 'سارا'}, key);
    expect(stored.contains('سارا'), isFalse);
    final decoded = await decodeCache(stored, key);
    expect(decoded['name'], 'سارا');
  });
}