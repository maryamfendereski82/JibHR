import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/theme/app_theme.dart';
import 'package:jibhr/features/session/workspace_session.dart';
import 'package:jibhr/features/shell/navigation.dart';
import 'package:jibhr/features/shell/shell_scaffold.dart';

final _all = navDestinations(const WorkspaceSession(
  profileId: 'p',
  firstName: 'سارا',
  lastName: 'احمدی‌نژاد',
  status: 'active',
  mustChangePassword: false,
  permissions: {'attendance.view.self', 'leave.request', 'tasks.create.personal'},
  teamName: 'تیم پشتیبانی مشتریان',
));

Widget _app({
  required Brightness brightness,
  required String location,
  required ValueChanged<String> onNavigate,
  bool expanded = true,
  ValueChanged<bool>? onExpanded,
  bool navLoading = false,
}) {
  return MaterialApp(
    theme: buildAppTheme(brightness),
    locale: const Locale('fa', 'IR'),
    supportedLocales: const [Locale('fa', 'IR')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
    home: ShellScaffold(
      destinations: _all,
      active: activeDestination(location, _all),
      onNavigate: onNavigate,
      bell: IconButton(tooltip: Fa.inbox, onPressed: () {}, icon: const SizedBox(width: 20, height: 20)),
      userName: 'سارا احمدی‌نژاد',
      userDetail: 'تیم پشتیبانی مشتریان',
      sidebarExpanded: expanded,
      onSidebarExpanded: onExpanded,
      navLoading: navLoading,
      child: const Center(child: Text('محتوا')),
    ),
  );
}

Future<void> _size(WidgetTester tester, double width, [double height = 900]) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  final widths = {390.0: 'shell-compact', 768.0: 'shell-medium', 1080.0: 'shell-medium', 1440.0: 'shell-large'};

  for (final brightness in Brightness.values) {
    for (final entry in widths.entries) {
      testWidgets('${entry.key.toInt()} ${brightness.name}: right layout, no overflow', (tester) async {
        await _size(tester, entry.key);
        await tester.pumpWidget(_app(brightness: brightness, location: '/attendance', onNavigate: (_) {}));
        await tester.pumpAndSettle();
        expect(find.byKey(Key(entry.value)), findsOneWidget);
        expect(find.text('محتوا'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [390.0, 768.0, 1080.0, 1440.0]) {
    testWidgets('${width.toInt()}: while the session loads, no partial menu, same geometry', (tester) async {
      await _size(tester, width);
      await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (_) {}, navLoading: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('nav-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-home')), findsNothing);
      expect(find.byKey(const ValueKey('nav-settings')), findsNothing);
      expect(find.text('محتوا'), findsOneWidget, reason: 'the page is not held back');
      expect(tester.takeException(), isNull);
      final railOrBar = width < 600 ? null : tester.getSize(find.byKey(const Key('nav-loading')).first);
      // Then the session arrives: real items, nothing else moves.
      await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (_) {}));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-loading')), findsNothing);
      expect(find.byKey(const ValueKey('nav-home')), findsOneWidget);
      if (railOrBar != null) expect(railOrBar.width, greaterThan(0));
    });
  }

  testWidgets('phone: four items plus more; more opens the rest', (tester) async {
    await _size(tester, 390, 844);
    String? went;
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (p) => went = p));
    await tester.pumpAndSettle();
    for (final id in ['home', 'attendance', 'work', 'leave', 'more']) {
      expect(find.byKey(ValueKey('nav-$id')), findsOneWidget, reason: id);
    }
    expect(find.byKey(const ValueKey('nav-reports')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('more-reports')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-settings')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('more-reports')));
    await tester.pumpAndSettle();
    expect(went, '/reports');
  });

  testWidgets('phone: the header names the active section', (tester) async {
    await _size(tester, 390, 844);
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/leave/queue', onNavigate: (_) {}));
    await tester.pumpAndSettle();
    expect(find.text(Fa.leave), findsWidgets);
  });

  testWidgets('selected item is announced as selected; others are not', (tester) async {
    await _size(tester, 1440);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/work/p/1', onNavigate: (_) {}));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.byKey(const ValueKey('nav-work'))), matchesSemantics(
      label: Fa.work, isButton: true, isSelected: true, hasSelectedState: true, hasTapAction: true, isFocusable: true, hasFocusAction: true,
    ));
    expect(tester.getSemantics(find.byKey(const ValueKey('nav-home'))), matchesSemantics(
      label: Fa.dashboard, isButton: true, isSelected: false, hasSelectedState: true, hasTapAction: true, isFocusable: true, hasFocusAction: true,
    ));
    handle.dispose();
  });

  testWidgets('large: tapping an item navigates; toggle asks to collapse', (tester) async {
    await _size(tester, 1440);
    String? went;
    bool? expanded;
    await tester.pumpWidget(_app(
      brightness: Brightness.dark,
      location: '/',
      onNavigate: (p) => went = p,
      onExpanded: (v) => expanded = v,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-leave')));
    expect(went, '/leave');
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    expect(expanded, isFalse);
  });

  testWidgets('large collapsed: rail with tooltips, no overflow', (tester) async {
    await _size(tester, 1440);
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (_) {}, expanded: false));
    await tester.pumpAndSettle();
    expect(find.byType(Tooltip), findsWidgets);
    expect(find.text(Fa.navDaily), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rail tooltip opens beside the item, towards the content, centred', (tester) async {
    await _size(tester, 1440);
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (_) {}, expanded: false));
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('nav-attendance'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(item));
    await tester.pump(const Duration(milliseconds: 500));
    final bubble = find.text(Fa.attendance);
    expect(bubble, findsOneWidget);
    final itemRect = tester.getRect(item);
    final bubbleRect = tester.getRect(bubble);
    // RTL: the rail is on the right, the tooltip to its left, same centre line.
    expect(bubbleRect.right, lessThan(itemRect.left));
    expect((bubbleRect.center.dy - itemRect.center.dy).abs(), lessThan(2));
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(Fa.attendance), findsNothing);
  });

  testWidgets('touch never opens the rail tooltip', (tester) async {
    await _size(tester, 1440);
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (_) {}, expanded: false));
    await tester.pumpAndSettle();
    final touch = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('nav-leave'))));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text(Fa.leave), findsNothing);
    await touch.up();
  });

  testWidgets('medium: rail opens the full sidebar over the page and closes on the scrim', (tester) async {
    await _size(tester, 768);
    await tester.pumpWidget(_app(brightness: Brightness.light, location: '/', onNavigate: (_) {}));
    await tester.pumpAndSettle();
    expect(find.text(Fa.navDaily), findsNothing);
    await tester.tap(find.byKey(const Key('sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.text(Fa.navDaily), findsOneWidget);
    await tester.tapAt(const Offset(40, 450));
    await tester.pumpAndSettle();
    expect(find.text(Fa.navDaily), findsNothing);
  });
}
