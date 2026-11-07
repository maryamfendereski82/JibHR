import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_controls.dart';
import '../../core/design_system/brand_mark.dart';
import '../../core/design_system/glass_card.dart';
import '../../core/localization/fa.dart';
import '../../core/networking/supabase_provider.dart';
import '../../core/theme/app_theme.dart';
import '../session/workspace_session.dart';
import 'auth_repository.dart';

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              blur: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandMark(),
                  const SizedBox(height: 16),
                  Text(Fa.setupTitle, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(Fa.setupBody, style: TextStyle(color: palette.muted, height: 1.6)),
                  const SizedBox(height: 16),
                  Text(Fa.signature, style: TextStyle(color: palette.muted, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final identifier = _identifier.text.trim();
    if (identifier.isEmpty || _password.text.isEmpty) {
      setState(() => _error = Fa.required);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      if (client == null) throw StateError('offline');
      await AuthRepository(client).signIn(identifier: identifier, password: _password.text);
    } catch (error) {
      if (mounted) setState(() => _error = failureText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              blur: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandMark(),
                  const SizedBox(height: 16),
                  Text(Fa.loginTitle, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(Fa.tagline, style: TextStyle(color: paletteOf(context).muted)),
                  const SizedBox(height: 20),
                  AppTextField(
                    label: Fa.identifier,
                    controller: _identifier,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    label: Fa.password,
                    controller: _password,
                    obscure: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: paletteOf(context).danger)),
                  ],
                  const SizedBox(height: 16),
                  AppButton(label: Fa.signIn, busy: _busy, onPressed: _submit),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => context.go('/forgot-password'),
                      child: const Text(Fa.forgotPassword),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _email = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_email.text.contains('@')) {
      setState(() => _error = Fa.required);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      if (client == null) throw StateError('offline');
      await AuthRepository(client).sendRecovery(_email.text);
      if (mounted) setState(() => _sent = true);
    } catch (error) {
      if (mounted) setState(() => _error = failureText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(Fa.forgotPassword, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(_sent ? Fa.recoverySent : Fa.forgotHint),
                  if (!_sent) ...[
                    const SizedBox(height: 16),
                    AppTextField(label: Fa.identifier, controller: _email, keyboardType: TextInputType.emailAddress),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: TextStyle(color: paletteOf(context).danger)),
                    ],
                    const SizedBox(height: 16),
                    AppButton(label: Fa.sendLink, busy: _busy, onPressed: _submit),
                  ],
                  TextButton(onPressed: () => context.go('/login'), child: const Text(Fa.backToLogin)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.length < 8) {
      setState(() => _error = Fa.shortPassword);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      if (client == null) throw StateError('offline');
      await AuthRepository(client).changePassword(_password.text);
      ref.invalidate(workspaceSessionProvider);
    } catch (error) {
      if (mounted) setState(() => _error = failureText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(Fa.changePassword, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  AppTextField(label: Fa.newPassword, controller: _password, obscure: true),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: paletteOf(context).danger)),
                  ],
                  const SizedBox(height: 16),
                  AppButton(label: Fa.savePassword, busy: _busy, onPressed: _submit),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
