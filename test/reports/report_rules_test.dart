import 'dart:ui' as ui;

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/features/dashboard/dashboard_page.dart';
import 'package:jibhr/features/reports/pdf_report.dart';
import 'package:jibhr/features/reports/report_rules.dart';
import 'package:jibhr/features/reports/xlsx_report.dart';

Map<String, dynamic> _personal() {
  return {
    'open': false,
    'incomplete': 1,
    'approved_seconds': 3600,
    'pending_seconds': 0,
    'recorded_seconds': 3600,
    'rejected_seconds': 0,
    'week_approved_seconds': 7200,
    'month_approved_seconds': 10800,
    'personal_tasks': 2,
    'project_tasks': 1,
    'awaiting_review': 0,
    'needs_revision': 0,
    'leave_pending': 0,
    'unread': 3,
    'statuses': [
      {'name': 'انجام کار', 'category': 'in_progress', 'total': 2},
    ],
  };
}

void main() {
  test('formula text stays a plain cell', () {
    expect(plainCell('=1+1'), "'=1+1");
    expect(plainCell('+SUM(A1)'), "'+SUM(A1)");
    expect(plainCell('-2'), "'-2");
    expect(plainCell('@cmd'), "'@cmd");
    expect(plainCell('\tname'), "'\tname");
    expect(plainCell('جیبکارت'), 'جیبکارت');
  });

  test('dashboard sections follow the payload', () {
    expect(showTeam(null), isFalse);
    expect(showProjects(null), isFalse);
    expect(showQueues({'attendance': 0, 'leave': 0}), isFalse);
    expect(showTeam({'employees': 4}), isTrue);
    expect(showQueues({'attendance': 2}), isTrue);
    expect(canExportReports({'tasks.manage.project'}), isFalse);
    expect(canExportReports({'reports.view.self'}), isTrue);
    expect(canExportReports({'reports.export.team'}), isTrue);
  });

  test('people sort does not invent a rank', () {
    final people = [
      {'name': 'ب', 'approved_seconds': 10},
      {'name': 'الف', 'approved_seconds': 99},
    ];
    final sorted = sortPeople(people, 'name', true);
    expect(sorted.first['name'], 'الف');
    expect(sortPeople(people, 'approved_seconds', false).first['approved_seconds'], 99);
  });

  test('a jalali display day keeps the gregorian value separate', () {
    expect(persianDay('2026-03-21'), contains('فروردین'));
    expect(persianDay('2026-03-21'), contains('۱۴۰۵'));
    final cells = exportCells('attendance_days', {
      'name': '=hidden',
      'period_start': '2026-03-21',
      'period_end': '2026-03-21',
      'recorded_seconds': 1800,
      'approved_seconds': 1800,
      'pending_seconds': 0,
      'rejected_seconds': 0,
      'interval_count': 1,
      'report_status': 'approved',
    });
    expect(cells[1], '2026-03-21');
    expect(cells[4], 1800);
  });

  test('pdf pages repeat past the first screenful', () {
    final rows = [for (var index = 0; index < 30; index++) {'name': 'ردیف'}];
    expect(pageSlices(rows).length, 2);
    expect(pageSlices(rows).first.length, pdfTableRows);
    expect(pageSlices(const []).single, isEmpty);
  });

  test('xlsx is a workbook with every exported row', () {
    final rows = [
      for (var index = 0; index < 40; index++)
        {
          'name': index == 0 ? '=1+1' : 'کارمند',
          'period_start': '2026-03-21',
          'period_end': '2026-03-21',
          'recorded_seconds': 5400,
          'approved_seconds': 3600,
          'pending_seconds': 1800,
          'rejected_seconds': 0,
          'interval_count': 1,
          'report_status': 'pending',
        },
    ];
    final bytes = buildXlsx(
      title: 'حضور روزانه',
      stamp: '۱۴۰۵',
      filterLines: const ['همه'],
      kind: 'attendance_days',
      rows: rows,
    );
    expect(String.fromCharCodes(bytes.take(2)), 'PK');
    final book = Excel.decodeBytes(bytes);
    expect(book.sheets.keys, contains('حضور روزانه'));
    final sheet = book['حضور روزانه'];
    expect(sheet.rows.length, greaterThan(40));
    final stored = sheet.rows.map((row) => row.map((cell) => cell?.value).join(' ')).join('\n');
    expect(stored, contains("'=1+1"));
    expect(stored, contains('5400'));
  });

  testWidgets('lam and alef join and the pdf has a page per slice', (tester) async {
    await ensureVazir();
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(fontFamily: 'Vazirmatn', fontSize: 32, textDirection: ui.TextDirection.rtl),
    )..addText('لا');
    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 240));
    expect(paragraph.getBoxesForRange(0, 2), hasLength(1));

    final bytes = await tester.runAsync(() => buildReportPdf(
      title: 'گزارش حضور',
      stamp: '۱۴۰۵',
      filterLines: const ['جیبکارت'],
      kind: 'tasks',
      rows: [
        for (var index = 0; index < 30; index++)
          {'title': 'لا $index', 'project_name': 'محصول', 'status_name': 'انجام', 'category': 'in_progress', 'priority': 'medium', 'assignee': 'سارا', 'due_at': '', 'approval_state': 'pending', 'complete': false},
      ],
    ));
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
    final latin = String.fromCharCodes(bytes);
    final pages = RegExp(r'/Count\s+(\d+)').firstMatch(latin)?.group(1);
    expect(pages, '2', reason: latin.substring(0, latin.length.clamp(0, 800)));
  });

  testWidgets('an employee dashboard hides team and empty queues', (tester) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DashboardBody(
          firstName: 'سارا',
          summary: {
            'personal': _personal(),
            'team': null,
            'projects': null,
            'queues': {'attendance': 0, 'corrections': 0, 'leave': 0, 'disputes': 0, 'task_reviews': 0},
          },
          stale: true,
          canOpenPerson: false,
          canExport: true,
        ),
      ),
    ));
    expect(find.textContaining('سارا'), findsOneWidget);
    expect(find.text(Fa.staleDashboard), findsOneWidget);
    expect(find.text(Fa.teamSummary), findsNothing);
    expect(find.text(Fa.projectSummary), findsNothing);
    expect(find.text(Fa.pendingApprovals), findsNothing);
    expect(find.text('انجام کار: ۲'), findsOneWidget);
    expect(find.text('عملکرد بالا'), findsNothing);
  });

  testWidgets('a manager dashboard lists the team without a score', (tester) async {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DashboardBody(
          firstName: 'مدیر',
          summary: {
            'personal': _personal(),
            'team': {
              'employees': 2,
              'open_intervals': 0,
              'pending_reports': 1,
              'pending_corrections': 0,
              'pending_leave': 0,
              'pending_disputes': 0,
              'active_tasks': 3,
              'review_tasks': 1,
              'overdue_tasks': 0,
              'complete_tasks': 4,
              'people': [
                {
                  'id': 'p1',
                  'name': 'سارا',
                  'position': 'توسعه‌دهنده',
                  'approved_seconds': 3600,
                  'pending_seconds': 0,
                  'active_tasks': 1,
                  'complete_tasks': 2,
                  'review_tasks': 0,
                  'open_corrections': 0,
                },
              ],
            },
            'projects': {'active': 1, 'archived': 0, 'tasks': 3, 'awaiting_review': 0, 'overdue': 0, 'complete': 1, 'active_sprints': 1, 'upcoming_milestones': 0, 'reached_milestones': 0},
            'queues': {'attendance': 1, 'corrections': 0, 'leave': 0, 'disputes': 0, 'task_reviews': 0},
          },
          stale: false,
          canOpenPerson: true,
          canExport: false,
        ),
      ),
    ));
    expect(find.text(Fa.teamSummary), findsOneWidget);
    expect(find.text(Fa.projectSummary), findsOneWidget);
    expect(find.text('سارا'), findsWidgets);
    expect(find.text(Fa.noRanking), findsOneWidget);
    expect(find.text(Fa.exportReport), findsNothing);
    expect(find.text(Fa.pendingApprovals), findsOneWidget);
  });
}
