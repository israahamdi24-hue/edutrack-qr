import 'package:flutter_test/flutter_test.dart';
import 'package:edutrack/services/edutrack_api_client.dart';

void main() {
  group('resolveEduTrackApiBaseUrl', () {
    test('uses the web page host for local network development', () {
      expect(
        resolveEduTrackApiBaseUrl(
          configuredBaseUrl: '',
          isWeb: true,
          pageUri: Uri.parse('http://10.22.212.212:8081/'),
        ),
        'http://10.22.212.212:3000',
      );
    });

    test('preserves an explicitly configured API URL', () {
      expect(
        resolveEduTrackApiBaseUrl(
          configuredBaseUrl: 'https://api.example.test/',
          isWeb: true,
          pageUri: Uri.parse('http://10.22.212.212:8081/'),
        ),
        'https://api.example.test',
      );
    });

    test('requires an explicit URL for non-local web deployments', () {
      expect(
        () => resolveEduTrackApiBaseUrl(
          configuredBaseUrl: '',
          isWeb: true,
          pageUri: Uri.parse('https://edutrack.example/'),
        ),
        throwsStateError,
      );
    });
  });
}
