import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/features/attendance/approval_queue_page.dart';
import 'package:jibhr/features/attendance/attendance_review.dart';

ReviewItem _item(String id, String decision, int seconds) {
  final start = DateTime.utc(2026, 11, 5, 6);
  return ReviewItem(
    id: id,
    intervalId: 'interval-$id',
    decision: decision,
    startedAt: start,
    endedAt: start.add(Duration(seconds: seconds)),
  );
}

void main() {
  test('bulk approval skips revision and rejected intervals', () {
    final items = [
      _item('a', 'pending', 3600),
      _item('b', 'needs_revision', 1800),
      _item('c', 'rejected', 900),
      _item('d', 'approved', 600),
    ];
    expect(pendingDecisionIds(items), ['a']);
    expect(approvedSeconds(items), 600);
    expect(recordedSeconds(items), 3600 + 1800 + 900 + 600);
  });

  test('correction form matches the server rules', () {
    final start = DateTime.utc(2026, 11, 5, 6);
    final end = start.add(const Duration(hours: 1));
    expect(
      correctionProblem(
        kind: 'missing_in',
        reason: 'فراموش شد',
        intervalId: null,
        start: start,
        end: end,
        intervalStart: null,
        intervalEnd: null,
      ),
      isNull,
    );
    expect(
      correctionProblem(
        kind: 'missing_out',
        reason: ' ',
        intervalId: 'i',
        start: null,
        end: end,
        intervalStart: start,
        intervalEnd: null,
      ),
      'reason_required',
    );
    expect(
      correctionProblem(
        kind: 'edit_in',
        reason: 'اشتباه',
        intervalId: null,
        start: start,
        end: null,
        intervalStart: start,
        intervalEnd: end,
      ),
      'invalid_range',
    );
    expect(
      correctionProblem(
        kind: 'delete_interval',
        reason: 'بازه اشتباه است',
        intervalId: 'i',
        start: null,
        end: null,
        intervalStart: null,
        intervalEnd: null,
      ),
      isNull,
    );
  });

  testWidgets('approve-all asks once and only sends pending intervals', (tester) async {
    var approvedAll = false;
    final calls = <String>[];
    final report = ReviewReport(
      id: 'r',
      profileId: 'p',
      teamId: 't',
      employeeName: 'کارمند یک',
      teamName: 'فلاتر',
      tehranDate: DateTime.utc(2026, 11, 5),
      sequence: 2,
      kind: 'supplemental',
      status: 'partially_approved',
      items: [
        _item('pending-1', 'pending', 1200),
        _item('revision-1', 'needs_revision', 600),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: Scaffold(
          body: ReportDetail(
            report: report,
            onDecide: (id, decision, reason) async => calls.add('$id:$decision'),
            onApprovePending: () async => approvedAll = true,
          ),
        ),
      ),
    );
    expect(find.textContaining(Fa.supplementalReport), findsOneWidget);
    expect(find.textContaining(Fa.needsRevision), findsOneWidget);
    expect(find.text(Fa.requestRevision), findsOneWidget);
    await tester.tap(find.text(Fa.approvePending));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fa.confirm));
    await tester.pumpAndSettle();
    expect(approvedAll, isTrue);
    expect(calls, isEmpty);
    expect(find.text(Fa.requestRevision), findsOneWidget);
  });
}