import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jibhr/app/app.dart';
import 'package:jibhr/app/config/app_config.dart';
import 'package:jibhr/core/localization/fa.dart';
import 'package:jibhr/core/networking/supabase_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('unconfigured app explains how to connect', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(const AppConfig(url: '', publishableKey: '')),
          supabaseClientProvider.overrideWithValue(null),
        ],
        child: const JibHrApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(Fa.setupTitle), findsOneWidget);
    expect(find.text(Fa.signature), findsOneWidget);
  });
}
