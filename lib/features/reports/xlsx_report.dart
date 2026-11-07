import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../core/localization/fa.dart';
import 'report_rules.dart';

Uint8List buildXlsx({
  required String title,
  required String stamp,
  required List<String> filterLines,
  required String kind,
  required List<Map<String, dynamic>> rows,
}) {
  final book = Excel.createExcel();
  final name = sheetNameFor(kind);
  book.rename('Sheet1', name);
  final sheet = book[name];
  void line(List<Object?> cells) {
    sheet.appendRow([
      for (final cell in cells)
        if (cell is int)
          IntCellValue(cell)
        else
          TextCellValue(plainCell(cell?.toString() ?? '')),
    ]);
  }

  line([Fa.companyName]);
  line([title]);
  line(['${Fa.generatedAt}: $stamp']);
  for (final filter in filterLines) {
    line(['${Fa.filters}: $filter']);
  }
  line(exportHeaders(kind));
  for (final row in rows) {
    line(exportCells(kind, row));
  }
  for (var column = 0; column < exportHeaders(kind).length; column++) {
    sheet.setColumnWidth(column, 22);
  }
  final bytes = book.encode();
  if (bytes == null) {
    throw StateError('xlsx');
  }
  return Uint8List.fromList(bytes);
}
