import '../../../services/edutrack_api_client.dart';

abstract interface class StudentAttendanceQrService {
  Future<String> recordPresence(String qrPayload);
}

class HttpStudentAttendanceQrService implements StudentAttendanceQrService {
  HttpStudentAttendanceQrService({EduTrackApiClient? apiClient})
    : _api = apiClient ?? EduTrackApiClient();

  final EduTrackApiClient _api;

  @override
  Future<String> recordPresence(String qrPayload) async {
    final trimmedPayload = qrPayload.trim();
    if (trimmedPayload.isEmpty) {
      throw ArgumentError.value(qrPayload, 'qrPayload', 'cannot be empty');
    }

    final result = await _api.post('/api/student/attendance/scan', {
      'qrPayload': trimmedPayload,
    });
    if (result['success'] != true) {
      final message = result['message'];
      throw StudentAttendanceValidationException(
        message is String && message.isNotEmpty
            ? message
            : 'Le serveur n’a pas confirmé la présence.',
      );
    }
    final message = result['message'];
    return message is String && message.isNotEmpty
        ? message
        : 'Votre demande de présence a été traitée.';
  }
}

class StudentAttendanceValidationException implements Exception {
  const StudentAttendanceValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}
