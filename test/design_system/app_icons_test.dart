import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/design_system/app_icons.dart';

void main() {
  test('every registered icon comes from the iconsax font', () {
    for (final entry in AppIcons.all.entries) {
      for (final glyph in [entry.value.linear, ?entry.value.bold]) {
        expect(glyph.fontPackage, 'iconsax', reason: entry.key);
        expect(glyph.fontFamily, 'iconsax', reason: entry.key);
      }
    }
  });

  test('Iconsax glyphs never mirror, so direction is fixed in the registry', () {
    for (final entry in AppIcons.all.entries) {
      expect(entry.value.linear.matchTextDirection, isFalse, reason: entry.key);
    }
  });

  test('back and open point opposite ways', () {
    expect(AppIcons.back.linear, isNot(AppIcons.open.linear));
    expect(AppIcons.previous.linear, isNot(AppIcons.next.linear));
  });

  test('selected falls back to linear when no bold glyph was verified', () {
    expect(AppIcons.kanban.of(selected: true), AppIcons.kanban.linear);
    expect(AppIcons.home.of(selected: true), AppIcons.home.bold);
  });
}
