import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/notifications/notification_pages.dart';
import 'package:jibhr/features/notifications/notification_rules.dart';

NotificationRow _row(String id, {DateTime? readAt}) {
  return NotificationRow(
    id: id,
    category: 'task',
    title: 'تسک تازه',
    body: 'یک تسک به شما سپرده شد.',
    createdAt: DateTime.utc(2026, 11, 5, 8),
    readAt: readAt,
    entityType: 'task',
    entityId: 'task-1',
  );
}

void main() {
  test('a hidden or missing record has no path', () {
    expect(
      notificationPath(entityType: 'task', entityId: 'task-1', visible: false, ownRecord: true),
      isNull,
    );
    expect(
      notificationPath(entityType: 'sprint', entityId: 'sprint-1', visible: true, ownRecord: false),
      isNull,
    );
    expect(
      notificationPath(
        entityType: 'sprint',
        entityId: 'sprint-1',
        visible: true,
        projectId: 'project-1',
        ownRecord: false,
      ),
      '/work/p/project-1/sprint/sprint-1',
    );
    expect(
      notificationPath(entityType: 'attendance_report', entityId: 'report-1', visible: true, ownRecord: true),
      '/attendance',
    );
    expect(
      notificationPath(entityType: 'leave_request', entityId: 'leave-1', visible: true, ownRecord: false),
      '/leave/queue',
    );
    expect(
      notificationPath(entityType: 'absence_dispute', entityId: 'dispute-1', visible: true, ownRecord: true),
      '/leave/my-absence',
    );
  });

  test('a push is kept once, and reconnect keeps the server page', () {
    final first = _row('a');
    final second = _row('b');
    final merged = applyInbox([first], second, reconnect: false);
    expect(merged.map((row) => row.id), ['b', 'a']);
    expect(applyInbox(merged, second, reconnect: false), merged);
    final server = [first];
    expect(applyInbox(server, second, reconnect: true), server);
    expect(appendPage([first], [first, second]).map((row) => row.id), ['a', 'b']);
  });

  test('recent notices use a short persian label', () {
    final now = DateTime.utc(2026, 11, 5, 12);
    expect(relativeNoticeTime(now.subtract(const Duration(seconds: 20)), now), Fa.justNow);
    expect(relativeNoticeTime(now.subtract(const Duration(minutes: 5)), now), '۵ ${Fa.minutesAgo}');
    expect(relativeNoticeTime(now.subtract(const Duration(days: 8)), now), isNot(Fa.justNow));
  });

  testWidgets('an unread card shows its title and category', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: NotificationCard(
          row: _row('a'),
          now: DateTime.utc(2026, 11, 5, 12),
          accent: AppPalette.light.jade,
        ),
      ),
    ));
    expect(find.text('تسک تازه'), findsOneWidget);
    expect(find.textContaining('تسک ·'), findsOneWidget);
    expect(find.textContaining(Fa.notificationUnavailable), findsNothing);
  });
}
