import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_controls.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/offline/offline_cache.dart';
import '../../core/theme/app_theme.dart';
import '../authentication/auth_repository.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(Fa.settings, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Fa.theme, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text(Fa.themeSystem)),
                  ButtonSegment(value: ThemeMode.light, label: Text(Fa.themeLight)),
                  ButtonSegment(value: ThemeMode.dark, label: Text(Fa.themeDark)),
                ],
                selected: {mode},
                onSelectionChanged: (value) => ref.read(themeModeProvider.notifier).setMode(value.first),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppButton(
          label: Fa.signOut,
          allowOffline: true,
          onPressed: () async {
            final client = ref.read(supabaseClientProvider);
            final userId = ref.read(connectionHubProvider).userId;
            if (userId != null) await ref.read(offlineCacheProvider).clearUser(userId);
            if (client == null) return;
            await AuthRepository(client).signOut();
          },
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: Fa.appName,
              applicationLegalese: Fa.iconNotice,
            ),
            child: const Text(Fa.licenses),
          ),
        ),
        const SizedBox(height: 8),
        Text(Fa.signature, style: TextStyle(color: paletteOf(context).muted)),
      ],
    );
  }
}
