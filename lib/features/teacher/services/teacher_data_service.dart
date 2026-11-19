import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../services/edutrack_api_client.dart';

class TeacherCourse {
  const TeacherCourse({
    required this.id,
    required this.name,
    required this.teacherName,
    required this.teacherUid,
    this.description,
  });

  final String id;
  final String name;
  final String teacherName;
  final String teacherUid;
  final String? description;
}

class TeacherSession {
  const TeacherSession({
    required this.id,
    required this.courseId,
    required this.courseName,
    required this.startsAt,
    this.endsAt,
    this.room,
    this.title,
    this.mode = 'inPerson',
    this.meetingUrl,
    this.status = 'scheduled',
    this.startedAt,
    this.qrExpiresAt,
    this.closedAt,
  });

  final String id;
  final String courseId;
  final String courseName;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String? room;
  final String? title;
  final String mode;
  final String? meetingUrl;
  final String status;
  final DateTime? startedAt;
  final DateTime? qrExpiresAt;
  final DateTime? closedAt;
}

class TeacherAttendance {
  const TeacherAttendance({
    required this.id,
    required this.studentUid,
    required this.courseId,
    required this.sessionId,
    required this.status,
    required this.recordedAt,
    this.reason,
  });

  final String id;
  final String studentUid;
  final String courseId;
  final String sessionId;
  final String status;
  final DateTime recordedAt;
  final String? reason;
}

class TeacherNotification {
  const TeacherNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.isRead,
  });
  final String id;
  final String title;
  final String message;
  final DateTime? createdAt;
  final bool isRead;
}

class EnrolledStudent {
  const EnrolledStudent({
    required this.uid,
    required this.displayName,
    this.className,
  });

  final String uid;
  final String displayName;
  final String? className;
}

abstract interface class TeacherWorkspaceRepository {
  Future<List<TeacherCourse>> loadCourses(String teacherUid);
  Future<List<TeacherSession>> loadSessions(String teacherUid);
  Future<List<TeacherAttendance>> loadAttendance(List<TeacherCourse> courses);
  Future<List<EnrolledStudent>> loadEnrolledStudents(String courseId);
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
  });
  Future<void> updateSession({
    required TeacherSession session,
    required String teacherUid,
    required DateTime startsAt,
    DateTime? endsAt,
    String? room,
  });
  Future<void> removeSession(TeacherSession session);
  Stream<List<TeacherAttendance>> watchAttendance(List<TeacherCourse> courses);
  Future<SessionQrTokenData> startSession(String sessionId);
  Future<void> closeSession(String sessionId);
  Future<void> correctAttendance({
    required String sessionId,
    required String studentUid,
    required String status,
    required String reason,
  });
  Stream<List<TeacherNotification>> watchNotifications(String uid);
  Future<void> markNotificationRead(String uid, String notificationId);
}

class TeacherDataService implements TeacherWorkspaceRepository {
  TeacherDataService({
    FirebaseFirestore? firestore,
    EduTrackApiClient? apiClient,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _api = apiClient ?? EduTrackApiClient();

  final FirebaseFirestore _firestore;
  final EduTrackApiClient _api;

  Future<List<TeacherCourse>> loadCourses(String teacherUid) async {
    final assignments = await _firestore
        .collection('teacherAssignments')
        .where('teacherId', isEqualTo: teacherUid)
        .get();
    final allowedIds = assignments.docs
        .where((d) => d.data()['status'] == 'active')
        .map((d) => d.id)
        .toSet();
    final snapshot = await _firestore
        .collection('courses')
        .where('teacherUid', isEqualTo: teacherUid)
        .get();
    final result = <TeacherCourse>[];
    for (final document in snapshot.docs) {
      final data = document.data();
      if (data['name'] is! String ||
          data['teacherName'] is! String ||
          data['teacherUid'] != teacherUid) {
        throw FormatException('Le cours ${document.id} est incomplet.');
      }
      if (!allowedIds.contains(document.id)) continue;
      result.add(
        TeacherCourse(
          id: document.id,
          name: data['name'] as String,
          teacherName: data['teacherName'] as String,
          teacherUid: teacherUid,
          description: data['description'] as String?,
        ),
      );
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<List<TeacherSession>> loadSessions(String teacherUid) async {
    final snapshot = await _firestore
        .collection('sessions')
        .where('teacherUid', isEqualTo: teacherUid)
        .get();
    final courseSnapshots = await loadCourses(teacherUid);
    final courses = {for (final course in courseSnapshots) course.id: course};
    final result = <TeacherSession>[];
    for (final document in snapshot.docs) {
      final data = document.data();
      final courseId = data['courseId'];
      final startsAt = data['startsAt'];
      if (courseId is! String ||
          startsAt is! Timestamp ||
          courses[courseId] == null) {
        throw FormatException('La séance ${document.id} est incomplète.');
      }
      final endsAt = data['endsAt'];
      final room = data['room'];
      if ((endsAt != null && endsAt is! Timestamp) ||
          (room != null && room is! String)) {
        throw FormatException(
          'La séance ${document.id} contient des champs invalides.',
        );
      }
      result.add(
        TeacherSession(
          id: document.id,
          courseId: courseId,
          courseName: courses[courseId]!.name,
          startsAt: startsAt.toDate(),
          endsAt: (endsAt as Timestamp?)?.toDate(),
          room: room as String?,
          title: data['title'] as String?,
          mode: data['mode'] as String? ?? 'inPerson',
          meetingUrl: data['meetingUrl'] as String?,
          status: data['status'] as String? ?? 'scheduled',
          startedAt: (data['startedAt'] as Timestamp?)?.toDate(),
          qrExpiresAt: (data['qrExpiresAt'] as Timestamp?)?.toDate(),
          closedAt: (data['closedAt'] as Timestamp?)?.toDate(),
        ),
      );
    }
    result.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return result;
  }

  Future<List<TeacherAttendance>> loadAttendance(
    List<TeacherCourse> courses,
  ) async {
    final records = <TeacherAttendance>[];
    final ids = courses.map((course) => course.id).toList();
    for (var start = 0; start < ids.length; start += 30) {
      final courseIds = ids.skip(start).take(30).toList();
      final snapshot = await _firestore
          .collection('attendance')
          .where('courseId', whereIn: courseIds)
          .get();
      for (final document in snapshot.docs) {
        final data = document.data();
        final studentUid = data['studentUid'];
        final sessionId = data['sessionId'];
        final courseId = data['courseId'];
        final status = data['status'];
        final recordedAt = data['recordedAt'];
        if (studentUid is! String ||
            sessionId is! String ||
            courseId is! String ||
            !ids.contains(courseId) ||
            document.id != '${studentUid}_$sessionId' ||
            status is! String ||
            !const {'present', 'late', 'absent'}.contains(status) ||
            recordedAt is! Timestamp) {
          throw FormatException('Le pointage ${document.id} est invalide.');
        }
        records.add(
          TeacherAttendance(
            id: document.id,
            studentUid: studentUid,
            courseId: courseId,
            sessionId: sessionId,
            status: status,
            recordedAt: recordedAt.toDate(),
            reason: data['reason'] as String?,
          ),
        );
      }
    }
    records.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    return records;
  }

  Future<List<EnrolledStudent>> loadEnrolledStudents(String courseId) async {
    final result = await _api.get(
      '/api/teacher/courses/${Uri.encodeComponent(courseId)}/students',
    );
    final rawStudents = result['students'];
    if (rawStudents is! List) {
      throw const FormatException('La réponse étudiant est invalide.');
    }
    return rawStudents.map((raw) {
      if (raw is! Map ||
          raw['uid'] is! String ||
          raw['displayName'] is! String) {
        throw const FormatException(
          'Le profil étudiant retourné est invalide.',
        );
      }
      return EnrolledStudent(
        uid: raw['uid'] as String,
        displayName: raw['displayName'] as String,
        className: raw['className'] as String?,
      );
    }).toList();
  }

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
    final body = <String, dynamic>{
      'courseId': courseId,
      'title': title?.trim(),
      'mode': mode,
      'room': room?.trim(),
      'meetingUrl': meetingUrl?.trim(),
    };
    if (startImmediately) {
      final duration = endsAt == null
          ? const Duration(hours: 2)
          : endsAt.difference(startsAt);
      final result = await _api.post('/api/teacher/sessions/start', {
        ...body,
        'durationMinutes': duration.inMinutes,
      });
      return _parseSessionQrToken(result);
    }

    await _api.post('/api/teacher/sessions', {
      ...body,
      'startsAt': startsAt.toUtc().toIso8601String(),
      if (endsAt != null) 'endsAt': endsAt.toUtc().toIso8601String(),
    });
    return null;
  }

  Stream<List<TeacherAttendance>> watchAttendance(List<TeacherCourse> courses) {
    final ids = courses.map((course) => course.id).toList();
    if (ids.isEmpty) return Stream.value(const []);
    // Separate listeners keep each Firestore whereIn query within its 30 item limit.
    final chunks = <List<String>>[];
    for (var start = 0; start < ids.length; start += 30)
      chunks.add(ids.skip(start).take(30).toList());
    return Stream<List<TeacherAttendance>>.multi((controller) {
      final latest = List<List<TeacherAttendance>>.generate(
        chunks.length,
        (_) => const [],
      );
      final subscriptions =
          <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
      for (var i = 0; i < chunks.length; i++) {
        final index = i;
        subscriptions.add(
          _firestore
              .collection('attendance')
              .where('courseId', whereIn: chunks[index])
              .snapshots()
              .listen((snapshot) {
                latest[index] = snapshot.docs
                    .map((doc) {
                      final data = doc.data();
                      if (data['studentUid'] is! String ||
                          data['sessionId'] is! String ||
                          data['courseId'] is! String ||
                          data['status'] is! String ||
                          data['recordedAt'] is! Timestamp)
                        return null;
                      return TeacherAttendance(
                        id: doc.id,
                        studentUid: data['studentUid'],
                        courseId: data['courseId'],
                        sessionId: data['sessionId'],
                        status: data['status'],
                        recordedAt: (data['recordedAt'] as Timestamp).toDate(),
                        reason: data['reason'] as String?,
                      );
                    })
                    .whereType<TeacherAttendance>()
                    .toList();
                controller.add(
                  latest.expand((items) => items).toList()
                    ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt)),
                );
              }, onError: controller.addError),
        );
      }
      controller.onCancel = () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      };
    });
  }

  Stream<List<TeacherSession>> watchSessions(String teacherUid) => _firestore
      .collection('sessions')
      .where('teacherUid', isEqualTo: teacherUid)
      .snapshots()
      .asyncMap((_) => loadSessions(teacherUid));

  @override
  Stream<List<TeacherNotification>> watchNotifications(String uid) => _firestore
      .collection('users')
      .doc(uid)
      .collection('notifications')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map(
        (snapshot) => snapshot.docs.map((doc) {
          final data = doc.data();
          return TeacherNotification(
            id: doc.id,
            title: data['title'] as String? ?? 'Notification',
            message: data['message'] as String? ?? '',
            createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
            isRead: data['isRead'] as bool? ?? false,
          );
        }).toList(),
      );

  @override
  Future<void> markNotificationRead(String uid, String id) => _firestore
      .collection('users')
      .doc(uid)
      .collection('notifications')
      .doc(id)
      .update({'isRead': true});

  Future<SessionQrTokenData> startSession(String sessionId) async {
    final result = await _api.post(
      '/api/teacher/sessions/${Uri.encodeComponent(sessionId)}/start',
    );
    return _parseSessionQrToken(result);
  }

  Future<void> closeSession(String sessionId) async {
    await _api.post(
      '/api/teacher/sessions/${Uri.encodeComponent(sessionId)}/close',
    );
  }

  Future<void> correctAttendance({
    required String sessionId,
    required String studentUid,
    required String status,
    required String reason,
  }) async {
    await _api.post(
      '/api/teacher/sessions/${Uri.encodeComponent(sessionId)}/attendance',
      {'studentUid': studentUid, 'status': status, 'reason': reason},
    );
  }

  Future<void> updateSession({
    required TeacherSession session,
    required String teacherUid,
    required DateTime startsAt,
    DateTime? endsAt,
    String? room,
  }) async {
    await _firestore.collection('sessions').doc(session.id).update({
      'startsAt': Timestamp.fromDate(startsAt),
      'endsAt': endsAt == null
          ? FieldValue.delete()
          : Timestamp.fromDate(endsAt),
      'room': room == null || room.trim().isEmpty
          ? FieldValue.delete()
          : room.trim(),
      'teacherUid': teacherUid,
      'courseId': session.courseId,
    });
  }

  Future<void> removeSession(TeacherSession session) async {
    final attendance = await _firestore
        .collection('attendance')
        .where('courseId', isEqualTo: session.courseId)
        .get();
    if (attendance.docs.any(
      (document) => document.data()['sessionId'] == session.id,
    )) {
      throw StateError(
        'Cette séance possède des pointages et ne peut pas être supprimée.',
      );
    }
    await _firestore.collection('sessions').doc(session.id).delete();
  }
}

class SessionQrTokenData {
  const SessionQrTokenData({
    required this.payload,
    required this.expiresAt,
    required this.sessionId,
    required this.startedAt,
  });
  final String payload;
  final DateTime expiresAt;
  final String sessionId;
  final DateTime startedAt;
}

SessionQrTokenData _parseSessionQrToken(Map<String, dynamic> data) {
  final payload = data['qrPayload'];
  final expiresAt = data['expiresAt'];
  final sessionId = data['sessionId'];
  final startedAt = data['startedAt'];
  if (payload is! String ||
      expiresAt is! num ||
      sessionId is! String ||
      startedAt is! num) {
    throw const FormatException('Réponse QR invalide du serveur.');
  }
  return SessionQrTokenData(
    payload: payload,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt()),
    sessionId: sessionId,
    startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt.toInt()),
  );
}
