import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'offline_cache.dart';
import 'offline_policy.dart';

class OfflineHttpClient extends http.BaseClient {
  OfflineHttpClient(this._inner, this.hub, this.cache);

  final http.Client _inner;
  final ConnectionHub hub;
  final OfflineCache cache;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.bodyBytes : Uint8List(0);
    final user = userIdFromAuthorization(request.headers['Authorization'] ?? request.headers['authorization']);
    final key = requestKeyOf(request.method, request.url, body);
    if (hub.offline && (offlineBlocksRequest(request.method, request.url.path) || hub.locked)) {
      return _message(request, 503, 'offline');
    }
    if (hub.offline) {
      if (user == null) return _message(request, 503, 'offline');
      final hit = await cache.read(user, key);
      if (hit == null) return _message(request, 503, 'offline');
      return _bytes(request, 200, hit);
    }
    try {
      final response = await _inner.send(request);
      final responseBytes = await response.stream.toBytes();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        hub.markOnline();
        if (user != null && !offlineBlocksRequest(request.method, request.url.path)) {
          await cache.save(user, key, responseBytes);
        }
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(responseBytes),
        response.statusCode,
        contentLength: responseBytes.length,
        request: request,
        headers: response.headers,
      );
    } catch (error) {
      hub.markOffline();
      if (user != null && !hub.locked && !offlineBlocksRequest(request.method, request.url.path)) {
        final hit = await cache.read(user, key);
        if (hit != null) return _bytes(request, 200, hit);
      }
      rethrow;
    }
  }

  http.StreamedResponse _message(http.BaseRequest request, int status, String code) {
    return _bytes(request, status, utf8.encode('{"message":"$code","code":"$code"}'));
  }

  http.StreamedResponse _bytes(http.BaseRequest request, int status, List<int> bytes) {
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      status,
      contentLength: bytes.length,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}
