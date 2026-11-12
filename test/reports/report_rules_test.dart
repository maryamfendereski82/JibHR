import 'dart:ui' as ui;

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/features/reports/pdf_report.dart';
import 'package:jibhr/features/reports/report_rules.dart';
import 'package:jibhr/features/reports/xlsx_report.dart';

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

}
