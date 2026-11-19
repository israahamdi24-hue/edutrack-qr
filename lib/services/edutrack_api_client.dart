import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const _configuredApiBaseUrl = String.fromEnvironment(
  'EDUTRACK_API_BASE_URL',
  defaultValue: '',
);
const _fallbackApiBaseUrl = 'http://127.0.0.1:3000';

@visibleForTesting
String resolveEduTrackApiBaseUrl({
  required String configuredBaseUrl,
  required bool isWeb,
  Uri? pageUri,
}) {
  final configured = configuredBaseUrl.trim();
  if (configured.isNotEmpty) {
    return configured.replaceFirst(RegExp(r'/+$'), '');
  }

  if (!isWeb) return _fallbackApiBaseUrl;

  final currentPage = pageUri ?? Uri.base;
  if (currentPage.scheme != 'http' ||
      !_isLocalDevelopmentHost(currentPage.host)) {
    throw StateError(
      'Set EDUTRACK_API_BASE_URL when the web app is not served from a local '
      'HTTP address.',
    );
  }
  return Uri(
    scheme: currentPage.scheme,
    host: currentPage.host,
    port: 3000,
  ).toString();
}

bool _isLocalDevelopmentHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1') return true;
  final octets = host.split('.');
  if (octets.length != 4 ||
      octets.any((part) => !RegExp(r'^\d{1,3}$').hasMatch(part))) {
    return false;
  }
  final address = octets.map(int.parse).toList();
  if (address.any((octet) => octet > 255)) return false;
  return address[0] == 10 ||
      (address[0] == 172 && address[1] >= 16 && address[1] <= 31) ||
      (address[0] == 192 && address[1] == 168);
}

class EduTrackApiClient {
  EduTrackApiClient({FirebaseAuth? auth, http.Client? client, String? baseUrl})
    : _auth = auth ?? FirebaseAuth.instance,
      _client = client ?? http.Client(),
      _baseUrl = resolveEduTrackApiBaseUrl(
        configuredBaseUrl: baseUrl ?? _configuredApiBaseUrl,
        isWeb: kIsWeb,
      );

  final FirebaseAuth _auth;
  final http.Client _client;
  final String _baseUrl;

  Future<Map<String, dynamic>> get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic> body = const {},
  ]) => _send('POST', path, body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const EduTrackApiException(
        statusCode: 401,
        code: 'unauthenticated',
        message: 'Reconnectez-vous pour continuer.',
      );
    }

    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw const EduTrackApiException(
        statusCode: 401,
        code: 'unauthenticated',
        message: 'Firebase n’a pas fourni de jeton de connexion.',
      );
    }

    final uri = Uri.parse('$_baseUrl$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer $idToken',
      if (body != null) 'Content-Type': 'application/json',
    };
    final response = switch (method) {
      'GET' => await _client.get(uri, headers: headers),
      'POST' => await _client.post(
        uri,
        headers: headers,
        body: jsonEncode(body),
      ),
      _ => throw ArgumentError.value(method, 'method'),
    };

    Map<String, dynamic> data = const {};
    if (response.body.isNotEmpty) {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Réponse API EduTrack invalide.');
      }
      data = decoded;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = data['error'];
      final code = error is Map ? error['code'] : null;
      final message = error is Map ? error['message'] : null;
      throw EduTrackApiException(
        statusCode: response.statusCode,
        code: code is String ? code : 'http-${response.statusCode}',
        message: message is String && message.isNotEmpty
            ? message
            : 'Le serveur EduTrack a refusé la demande.',
      );
    }
    return data;
  }
}

class EduTrackApiException implements Exception {
  const EduTrackApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => message;
}
