import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _aes = AesGcm.with256bits();

Future<Uint8List> encryptBytes(List<int> clear, List<int> keyBytes) async {
  final secret = SecretKey(keyBytes);
  final box = await _aes.encrypt(clear, secretKey: secret);
  return Uint8List.fromList([...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

Future<List<int>> decryptBytes(List<int> payload, List<int> keyBytes) async {
  if (payload.length < 12 + 16) {
    throw StateError('cache');
  }
  final nonce = payload.sublist(0, 12);
  final mac = payload.sublist(12, 28);
  final cipher = payload.sublist(28);
  final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
  return _aes.decrypt(box, secretKey: SecretKey(keyBytes));
}

Future<List<int>> newCacheKey() async {
  final secret = await _aes.newSecretKey();
  return secret.extractBytes();
}

Future<String> encodeCache(Map<String, Object?> envelope, List<int> key) async {
  return base64Encode(await encryptBytes(utf8.encode(jsonEncode(envelope)), key));
}

Future<Map<String, Object?>> decodeCache(String stored, List<int> key) async {
  final clear = await decryptBytes(base64Decode(stored), key);
  final decoded = jsonDecode(utf8.decode(clear));
  if (decoded is! Map) throw StateError('cache');
  return Map<String, Object?>.from(decoded);
}
