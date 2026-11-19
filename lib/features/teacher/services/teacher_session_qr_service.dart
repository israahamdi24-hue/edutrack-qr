import '../../../services/edutrack_api_client.dart';

abstract interface class TeacherQrRepository {
  Future<SessionQrToken> generate(String sessionId);
  Future<SessionQrToken> start(String sessionId);
  Future<void> close(String sessionId);
}

class TeacherSessionQrService implements TeacherQrRepository {
  TeacherSessionQrService({EduTrackApiClient? apiClient})
    : _api = apiClient ?? EduTrackApiClient();

  final EduTrackApiClient _api;

  @override
  Future<SessionQrToken> generate(String sessionId) async {
    final result = await _api.post(
      '/api/teacher/sessions/${Uri.encodeComponent(sessionId)}/qr',
    );
    return _parse(result);
  }

  @override
  Future<SessionQrToken> start(String sessionId) async {
    final result = await _api.post(
      '/api/teacher/sessions/${Uri.encodeComponent(sessionId)}/start',
    );
    return _parse(result);
  }

  @override
  Future<void> close(String sessionId) async => _api.post(
    '/api/teacher/sessions/${Uri.encodeComponent(sessionId)}/close',
  );

  SessionQrToken _parse(Map<String, dynamic> data) {
    final payload = data['qrPayload'];
    final expiresAt = data['expiresAt'];
    if (payload is! String || expiresAt is! num) {
      throw const FormatException('Réponse QR invalide du serveur.');
    }
    return SessionQrToken(
      payload: payload,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt()),
    );
  }
}

class SessionQrToken {
  const SessionQrToken({required this.payload, required this.expiresAt});

  final String payload;
  final DateTime expiresAt;
}
