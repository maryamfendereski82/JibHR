import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_crypto.dart';
import 'offline_policy.dart';

final connectionHubProvider = Provider<ConnectionHub>((ref) => ConnectionHub());

final offlineCacheProvider = Provider<OfflineCache>((ref) => OfflineCache(ref.watch(connectionHubProvider)));

final connectionTickProvider = NotifierProvider<ConnectionTick, int>(ConnectionTick.new);

class ConnectionTick extends Notifier<int> {
  @override
  int build() {
    final hub = ref.watch(connectionHubProvider);
    void listener() => state++;
    hub.addListener(listener);
    ref.onDispose(() => hub.removeListener(listener));
    return 0;
  }
}

class ConnectionHub extends ChangeNotifier {
  bool offline = false;
  bool locked = false;
  DateTime? validatedAt;
  String? userId;
  String? workspaceId;

  void noteSession({required String? userId, required String? workspaceId}) {
    this.userId = userId;
    this.workspaceId = workspaceId;
  }

  void markOnline() {
    final changed = offline || locked;
    offline = false;
    locked = false;
    validatedAt = DateTime.now().toUtc();
    if (changed) notifyListeners();
  }

  void markOffline() {
    final open = offlineAccessOpen(validatedAt: validatedAt, now: DateTime.now().toUtc(), online: false);
    final nextLocked = !open;
    final changed = !offline || locked != nextLocked;
    offline = true;
    locked = nextLocked;
    if (changed) notifyListeners();
  }
}

/// Encrypted page cache. The key lives in platform secure storage.
/// shortcut: the ciphertext is one preference value per user; split it if a cache passes a few megabytes.
class OfflineCache {
  OfflineCache(this.hub);

  final ConnectionHub hub;
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final Map<String, List<int>> _memory = {};

  Future<void> save(String userId, String requestKey, List<int> body) async {
    if (hub.locked) return;
    _memory['$userId|$requestKey'] = body;
    final envelope = await _readEnvelope(userId);
    final entries = Map<String, Object?>.from(envelope['entries'] as Map? ?? {});
    entries[requestKey] = base64Encode(body);
    envelope['entries'] = entries;
    envelope['validatedAt'] = (hub.validatedAt ?? DateTime.now().toUtc()).toIso8601String();
    envelope['workspaceId'] = hub.workspaceId;
    envelope['userId'] = userId;
    await _writeEnvelope(userId, envelope);
  }

  Future<List<int>?> read(String userId, String requestKey) async {
    if (!offlineAccessOpen(validatedAt: hub.validatedAt, now: DateTime.now().toUtc(), online: !hub.offline)) {
      return null;
    }
    final memory = _memory['$userId|$requestKey'];
    if (memory != null) return memory;
    final envelope = await _readEnvelope(userId);
    if (envelope['userId'] != userId) return null;
    final storedWorkspace = envelope['workspaceId']?.toString();
    if (hub.workspaceId != null && storedWorkspace != null && storedWorkspace != hub.workspaceId) return null;
    final entries = envelope['entries'];
    if (entries is! Map || entries[requestKey] is! String) return null;
    return base64Decode(entries[requestKey] as String);
  }

  Future<void> clearUser(String userId) async {
    _memory.removeWhere((key, _) => key.startsWith('$userId|'));
    await _storage.delete(key: _keyName(userId));
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_blobName(userId));
  }

  Future<Map<String, Object?>> _readEnvelope(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_blobName(userId));
    if (stored == null || stored.isEmpty) return {'userId': userId, 'entries': {}};
    final decoded = await decodeCache(stored, await _key(userId));
    final validated = DateTime.tryParse(decoded['validatedAt']?.toString() ?? '');
    if (validated != null && (hub.validatedAt == null || validated.isAfter(hub.validatedAt!))) {
      hub.validatedAt = validated;
    }
    return decoded;
  }

  Future<void> _writeEnvelope(String userId, Map<String, Object?> envelope) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_blobName(userId), await encodeCache(envelope, await _key(userId)));
  }

  Future<List<int>> _key(String userId) async {
    final existing = await _storage.read(key: _keyName(userId));
    if (existing != null && existing.isNotEmpty) return base64Decode(existing);
    final created = await newCacheKey();
    await _storage.write(key: _keyName(userId), value: base64Encode(created));
    return created;
  }

  String _keyName(String userId) => 'jibhr-cache-$userId';

  String _blobName(String userId) => 'jibhr-cache-blob-$userId';
}

String requestKeyOf(String method, Uri url, List<int> body) {
  return '${method.toUpperCase()} $url ${base64Encode(body)}';
}

String? userIdFromAuthorization(String? header) {
  if (header == null || !header.startsWith('Bearer ')) return null;
  final parts = header.substring(7).split('.');
  if (parts.length < 2) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (payload is Map && payload['sub'] is String) return payload['sub'] as String;
  } catch (_) {
    return null;
  }
  return null;
}
