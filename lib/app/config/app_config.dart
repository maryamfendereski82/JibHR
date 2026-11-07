class AppConfig {
  const AppConfig({required this.url, required this.publishableKey, this.environment = 'local'});

  final String url;
  final String publishableKey;

  /// local, staging, or production. Non-production builds show the name.
  final String environment;

  bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  bool get showEnvironment => environment != 'production';

  factory AppConfig.fromEnvironment() {
    return AppConfig(
      url: const String.fromEnvironment('SUPABASE_URL'),
      publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
      environment: const String.fromEnvironment('SUPABASE_ENV', defaultValue: 'local'),
    );
  }
}
