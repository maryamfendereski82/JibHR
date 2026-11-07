import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/config/app_config.dart';

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnvironment());

/// Null until a publishable key is supplied. The service-role key is never here.
final supabaseClientProvider = Provider<SupabaseClient?>((ref) => null);
