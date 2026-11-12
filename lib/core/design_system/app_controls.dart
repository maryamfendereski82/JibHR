import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/offline_cache.dart';
import '../theme/app_theme.dart';

class AppButton extends ConsumerWidget {
  const AppButton({super.key, required this.label, required this.onPressed, this.busy = false, this.allowOffline = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool allowOffline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(connectionTickProvider);
    final hub = ref.watch(connectionHubProvider);
    final palette = paletteOf(context);
    final enabled = onPressed != null && !busy && (allowOffline || (!hub.offline && !hub.locked));
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton(
        onPressed: enabled ? onPressed : null,
        child: busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: palette.onJade)) : Text(label),
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({super.key, required this.label, required this.controller, this.obscure = false, this.keyboardType, this.textInputAction, this.onSubmitted});

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(labelText: label),
    );
  }
}
