import 'package:edutrack/features/teacher/screens/teacher_workspace_screen.dart';
import 'package:edutrack/features/teacher/services/teacher_data_service.dart';
import 'package:edutrack/features/teacher/services/teacher_session_qr_service.dart';
import 'package:edutrack/models/app_user.dart';
import 'package:edutrack/services/edutrack_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  const teacher = AppUser(
    uid: 'teacher-uid',
    email: 'enseignante@example.fr',
    displayName: 'Nadia Ben Salem',
    role: AppRole.teacher,
  );

  testWidgets('affiche les cours affectés et les étudiants inscrits', (
    tester,
  ) async {
    final repository = _FakeTeacherRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherWorkspaceScreen(
            user: teacher,
            sectionIndex: 1,
            service: repository,
            qrService: _FakeQrRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mes cours et étudiants inscrits'), findsOneWidget);
    expect(find.text('Développement mobile'), findsOneWidget);
    await tester.tap(find.byTooltip('Étudiants inscrits'));
    await tester.pumpAndSettle();
    expect(find.text('Étudiants • Développement mobile'), findsOneWidget);
    expect(find.text('Amine Trabelsi'), findsOneWidget);
  });

  testWidgets('présente un état français vide pour les séances', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherWorkspaceScreen(
            user: teacher,
            sectionIndex: 2,
            service: _FakeTeacherRepository(sessions: const []),
            qrService: _FakeQrRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Aucune séance enregistrée pour vos cours.'),
      findsOneWidget,
    );
  });

  testWidgets('alerte dès deux absences répétées', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TeacherWorkspaceScreen(
              user: teacher,
              sectionIndex: 3,
              service: _FakeTeacherRepository(
                attendance: [
                  _absence('student-1', 'session-1'),
                  _absence('student-1', 'session-2'),
                ],
              ),
              qrService: _FakeQrRepository(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Alerte : 1 étudiant(s) comptent au moins deux absences.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'affiche l’erreur renvoyée par le backend lors du chargement QR',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TeacherWorkspaceScreen(
              user: teacher,
              sectionIndex: 2,
              service: _FakeTeacherRepository(),
              qrService: _FakeQrRepository(
                error: const EduTrackApiException(
                  statusCode: 500,
                  code: 'internal',
                  message: 'API indisponible.',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Gérer la séance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir / afficher le QR de présence'));
      await tester.pumpAndSettle();

      expect(find.textContaining('API indisponible.'), findsOneWidget);
    },
  );

  testWidgets('affiche automatiquement le QR après création et démarrage', (
    tester,
  ) async {
    final repository = _FakeTeacherRepository(sessions: const []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherWorkspaceScreen(
            user: teacher,
            sectionIndex: 2,
            service: repository,
            qrService: _FakeQrRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Créer une séance'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Cours test');
    await tester.tap(find.text('Créer et démarrer + QR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repository.lastStartImmediately, isTrue);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('Expiration dans'), findsOneWidget);
  });
}

class _FakeTeacherRepository implements TeacherWorkspaceRepository {
  _FakeTeacherRepository({
    List<TeacherSession>? sessions,
    this.attendance = const [],
  }) : sessions =
           sessions ??
           [
             TeacherSession(
               id: 'session-1',
               courseId: 'course-1',
               courseName: 'Développement mobile',
               startsAt: DateTime(2026, 11, 5, 10),
               endsAt: DateTime(2026, 11, 5, 12),
               room: 'Salle B12',
             ),
           ];

  final List<TeacherSession> sessions;
  final List<TeacherAttendance> attendance;
  bool? lastStartImmediately;
  final course = const TeacherCourse(
    id: 'course-1',
    name: 'Développement mobile',
    teacherName: 'Nadia Ben Salem',
    teacherUid: 'teacher-uid',
  );

  @override
  Future<List<TeacherCourse>> loadCourses(String teacherUid) async => [course];

  @override
  Future<List<TeacherSession>> loadSessions(String teacherUid) async =>
      sessions;

  @override
  Future<List<TeacherAttendance>> loadAttendance(
    List<TeacherCourse> courses,
  ) async => attendance;

  @override
  Future<List<EnrolledStudent>> loadEnrolledStudents(String courseId) async =>
      const [
        EnrolledStudent(
          uid: 'student-1',
          displayName: 'Amine Trabelsi',
          className: 'DSI L3',
        ),
      ];

  @override
  Future<SessionQrTokenData?> createSession({
    required String courseId,
    required String teacherUid,
    required DateTime startsAt,
    DateTime? endsAt,
    String? room,
    String? title,
    String mode = 'inPerson',
    String? meetingUrl,
    bool startImmediately = false,
  }) async {
    lastStartImmediately = startImmediately;
    if (!startImmediately) return null;
    return SessionQrTokenData(
      payload: 'signed-token',
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      sessionId: 'created-session',
      startedAt: DateTime.now(),
    );
  }

  @override
  Future<void> updateSession({
    required TeacherSession session,
    required String teacherUid,
    required DateTime startsAt,
    DateTime? endsAt,
    String? room,
  }) async {}

  @override
  Future<void> removeSession(TeacherSession session) async {}

  @override
  Stream<List<TeacherAttendance>> watchAttendance(
    List<TeacherCourse> courses,
  ) => Stream.value([]);

  @override
  Future<SessionQrTokenData> startSession(String sessionId) async =>
      SessionQrTokenData(
        payload: 'signed-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 15)),
        sessionId: sessionId,
        startedAt: DateTime.now(),
      );

  @override
  Future<void> closeSession(String sessionId) async {}

  @override
  Future<void> correctAttendance({
    required String sessionId,
    required String studentUid,
    required String status,
    required String reason,
  }) async {}

  @override
  Stream<List<TeacherNotification>> watchNotifications(String uid) =>
      Stream.value(const []);

  @override
  Future<void> markNotificationRead(String uid, String notificationId) async {}
}

TeacherAttendance _absence(String studentUid, String sessionId) =>
    TeacherAttendance(
      id: '${studentUid}_$sessionId',
      studentUid: studentUid,
      courseId: 'course-1',
      sessionId: sessionId,
      status: 'absent',
      recordedAt: DateTime(2026, 11, 1),
    );

class _FakeQrRepository implements TeacherQrRepository {
  _FakeQrRepository({this.error});

  final Object? error;

  @override
  Future<SessionQrToken> generate(String sessionId) async {
    if (error != null) throw error!;
    return SessionQrToken(
      payload: 'signed-token',
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    );
  }

  @override
  Future<SessionQrToken> start(String sessionId) => generate(sessionId);

  @override
  Future<void> close(String sessionId) async {}
}
