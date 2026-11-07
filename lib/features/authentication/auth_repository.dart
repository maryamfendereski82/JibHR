import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_failure.dart';

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  Future<void> signIn({required String identifier, required String password}) async {
    try {
      final response = await _client.functions.invoke('login', body: {
        'identifier': identifier.trim(),
        'password': password,
      });
      final data = response.data;
      if (data is! Map || data['refresh_token'] is! String) {
        throw const AppFailure('invalid_credentials');
      }
      await _client.auth.setSession(
        data['refresh_token'] as String,
        accessToken: data['access_token'] as String?,
      );
    } on FunctionException catch (error) {
      throw AppFailure(_errorCode(error));
    }
  }

  Future<void> sendRecovery(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email.trim());
    } on AuthException {
      // The screen shows one message whether or not the address exists.
    }
  }

  Future<void> changePassword(String password) async {
    try {
      await _client.functions.invoke('change-password', body: {'password': password});
    } on FunctionException catch (error) {
      throw AppFailure(_errorCode(error));
    }
  }

  Future<void> signOut() => _client.auth.signOut();

  String _errorCode(FunctionException error) {
    final details = error.details;
    if (details is Map && details['error'] is String) return details['error'] as String;
    if (error.status == 429) return 'rate_limited';
    return 'invalid_credentials';
  }
}

String failureText(Object error) {
  final code = error is AppFailure ? error.code : '';
  return switch (code) {
    'rate_limited' => 'تعداد تلاش‌ها زیاد است. کمی بعد دوباره امتحان کنید.',
    'invalid_credentials' => 'اطلاعات ورود درست نیست.',
    'weak_password' => 'رمز باید حداقل ۸ نویسه باشد.',
    _ => 'ارتباط با سرور برقرار نشد.',
  };
}
