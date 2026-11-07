import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/calendar/tehran_time.dart';
import '../../core/localization/fa.dart';
import 'report_rules.dart';

bool _fontReady = false;

/// Loads Vazirmatn into Flutter's shaper. The vector PDF package does not join Persian letters.
Future<void> ensureVazir() async {
  if (_fontReady) return;
  final regular = await rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf');
  final loader = FontLoader('Vazirmatn')..addFont(Future.value(regular));
  await loader.load();
  _fontReady = true;
}

Future<Uint8List> buildReportPdf({
  required String title,
  required String stamp,
  required List<String> filterLines,
  required String kind,
  required List<Map<String, dynamic>> rows,
}) async {
  await ensureVazir();
  final headers = exportHeaders(kind);
  final table = [
    for (final row in rows) [for (final cell in exportCells(kind, row)) cell?.toString() ?? ''],
  ];
  final slices = pageSlices([
    for (final row in table) {'cells': row},
  ]);
  final images = <ui.Image>[];
  try {
    for (var index = 0; index < slices.length; index++) {
      images.add(await paintReportPage(
        title: title,
        stamp: stamp,
        filterLines: index == 0 ? filterLines : const [],
        headers: headers,
        rows: [
          for (final row in slices[index]) [for (final cell in (row['cells']! as List)) cell.toString()],
        ],
        page: index + 1,
        pages: slices.length,
      ));
    }
    return await embedPages(images);
  } finally {
    for (final image in images) {
      image.dispose();
    }
  }
}

/// Raster page. Persian is shaped here, then the PNG is placed in the PDF.
Future<ui.Image> paintReportPage({
  required String title,
  required String stamp,
  required List<String> filterLines,
  required List<String> headers,
  required List<List<String>> rows,
  required int page,
  required int pages,
}) async {
  const width = 1190.0;
  const height = 1684.0;
  const margin = 56.0;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, width, height), ui.Paint()..color = const ui.Color(0xFFF7FBF8));
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, width, 18),
    ui.Paint()..color = const ui.Color(0xFF0C7A5C),
  );
  var y = 48.0;
  y = _text(canvas, Fa.companyName, y, width, margin, size: 18, color: const ui.Color(0xFF0C7A5C));
  y = _text(canvas, title, y + 8, width, margin, size: 28);
  y = _text(canvas, '${Fa.generatedAt}: $stamp', y + 4, width, margin, size: 14, color: const ui.Color(0xFF5C6B64));
  for (final line in filterLines) {
    y = _text(canvas, line, y, width, margin, size: 14, color: const ui.Color(0xFF5C6B64));
  }
  y += 16;
  y = _tableRow(canvas, headers, y, width, margin, header: true);
  for (final row in rows) {
    y = _tableRow(canvas, row, y, width, margin);
  }
  _text(
    canvas,
    '${Fa.rows} ${persianDigits(page)} / ${persianDigits(pages)}',
    height - 48,
    width,
    margin,
    size: 14,
    color: const ui.Color(0xFF5C6B64),
  );
  final picture = recorder.endRecording();
  return picture.toImage(width.toInt(), height.toInt());
}

Future<Uint8List> embedPages(List<ui.Image> images) async {
  final document = pw.Document();
  for (final image in images) {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final memory = pw.MemoryImage(data!.buffer.asUint8List());
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Image(memory, fit: pw.BoxFit.fill),
      ),
    );
  }
  return document.save();
}

double _text(
  ui.Canvas canvas,
  String value,
  double y,
  double width,
  double margin, {
  double size = 16,
  ui.Color color = const ui.Color(0xFF14211C),
}) {
  final paragraph = _paragraph(value, width - margin * 2, size: size, color: color);
  canvas.drawParagraph(paragraph, ui.Offset(margin, y));
  return y + paragraph.height + 6;
}

double _tableRow(ui.Canvas canvas, List<String> cells, double y, double width, double margin, {bool header = false}) {
  if (cells.isEmpty) return y;
  final inner = width - margin * 2;
  final column = inner / cells.length;
  final paint = ui.Paint()..color = header ? const ui.Color(0xFFE6EEE9) : const ui.Color(0xFFFFFFFF);
  canvas.drawRect(ui.Rect.fromLTWH(margin, y, inner, 36), paint);
  canvas.drawRect(
    ui.Rect.fromLTWH(margin, y, inner, 36),
    ui.Paint()
      ..color = const ui.Color(0xFFD5E2DB)
      ..style = ui.PaintingStyle.stroke,
  );
  for (var index = 0; index < cells.length; index++) {
    final paragraph = _paragraph(cells[index], column - 12, size: header ? 13 : 12);
    final x = width - margin - column * (index + 1);
    canvas.drawParagraph(paragraph, ui.Offset(x + 6, y + 8));
  }
  return y + 36;
}

ui.Paragraph _paragraph(String value, double width, {double size = 16, ui.Color color = const ui.Color(0xFF14211C)}) {
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      fontFamily: 'Vazirmatn',
      fontSize: size,
      textDirection: ui.TextDirection.rtl,
      textAlign: ui.TextAlign.right,
      maxLines: 1,
      ellipsis: '…',
    ),
  )
    ..pushStyle(ui.TextStyle(color: color, fontFamily: 'Vazirmatn', fontSize: size))
    ..addText(value);
  final paragraph = builder.build();
  paragraph.layout(ui.ParagraphConstraints(width: width));
  return paragraph;
}
