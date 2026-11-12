import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app/app.dart';
import 'app/config/app_config.dart';
import 'core/networking/supabase_provider.dart';
import 'core/offline/offline_cache.dart';
import 'core/offline/offline_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final hub = ConnectionHub();
  final cache = OfflineCache(hub);
  SupabaseClient? client;
  if (config.isConfigured) {
    await Supabase.initialize(
      url: config.url,
      publishableKey: config.publishableKey,
      httpClient: OfflineHttpClient(http.Client(), hub, cache),
    );
    client = Supabase.instance.client;
  }

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        supabaseClientProvider.overrideWithValue(client),
        connectionHubProvider.overrideWithValue(hub),
        offlineCacheProvider.overrideWithValue(cache),
      ],
      child: const JibHrApp(),
    ),
  );
}
