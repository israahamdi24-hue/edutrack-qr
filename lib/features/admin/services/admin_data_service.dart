import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../models/app_user.dart';
import '../../../services/edutrack_api_client.dart';

class AdminCourse {
  const AdminCourse({
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

class AdminEnrollment {
  const AdminEnrollment({
    required this.id,
    required this.studentUid,
    required this.courseId,
    required this.status,
    this.classId,
  });
  final String id;
  final String studentUid;
  final String courseId;
  final String status;
  final String? classId;
}

class AdminSession {
  const AdminSession({
    required this.id,
    required this.courseId,
    required this.teacherUid,
    required this.startsAt,
    this.endsAt,
    this.room,
  });
  final String id;
  final String courseId;
  final String teacherUid;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String? room;
}

class AdminAttendance {
  const AdminAttendance({
    required this.studentUid,
    required this.courseId,
    required this.sessionId,
    required this.status,
    required this.recordedAt,
  });
  final String studentUid;
  final String courseId;
  final String sessionId;
  final String status;
  final DateTime recordedAt;
}

class AdminClass {
  const AdminClass({
    required this.id,
    required this.name,
    required this.group,
    required this.level,
    required this.academicYear,
  });
  final String id;
  final String name;
  final String group;
  final String level;
  final String academicYear;
}

class AdminSubject {
  const AdminSubject({
    required this.id,
    required this.name,
    required this.classIds,
    this.description,
  });
  final String id;
  final String name;
  final String? description;
  final List<String> classIds;
}

class AdminTeacherAssignment {
  const AdminTeacherAssignment({
    required this.id,
    required this.teacherId,
    required this.classId,
    required this.subject,
    required this.status,
  });
  final String id;
  final String teacherId;
  final String classId;
  final String subject;
  final String status;
}

class AdminWorkspaceData {
  const AdminWorkspaceData({
    required this.users,
    required this.courses,
    required this.enrollments,
    required this.sessions,
    required this.attendance,
    required this.classes,
    required this.subjects,
    required this.teacherAssignments,
  });
  final List<AppUser> users;
  final List<AdminCourse> courses;
  final List<AdminEnrollment> enrollments;
  final List<AdminSession> sessions;
  final List<AdminAttendance> attendance;
  final List<AdminClass> classes;
  final List<AdminSubject> subjects;
  final List<AdminTeacherAssignment> teacherAssignments;
}

class AdminDataService {
  AdminDataService({FirebaseFirestore? firestore, EduTrackApiClient? apiClient})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _api = apiClient ?? EduTrackApiClient();
  final FirebaseFirestore _firestore;
  final EduTrackApiClient _api;

  Future<AdminWorkspaceData> load() async {
    final results = await Future.wait([
      _firestore.collection('users').orderBy('displayName').get(),
      _firestore.collection('courses').get(),
      _firestore.collection('enrollments').get(),
      _firestore.collection('sessions').get(),
      _firestore.collection('attendance').get(),
      _firestore.collection('classes').orderBy('name').get(),
      _firestore.collection('subjects').orderBy('name').get(),
      _firestore.collection('teacherAssignments').get(),
    ]);
    final users = <AppUser>[];
    for (final document in results[0].docs) {
      final data = document.data();
      final isActive = data['isActive'];
      if (data['uid'] != document.id ||
          data['email'] is! String ||
          data['displayName'] is! String ||
          (isActive != null && isActive is! bool)) {
        throw FormatException('Profil utilisateur invalide : ${document.id}.');
      }
      users.add(
        AppUser(
          uid: document.id,
          email: data['email'] as String,
          displayName: data['displayName'] as String,
          role: AppRole.fromValue(data['role']),
          className: data['className'] as String?,
          isActive: isActive as bool? ?? true,
        ),
      );
    }
    final courses = <AdminCourse>[];
    for (final document in results[1].docs) {
      final data = document.data();
      if (data['name'] is! String ||
          data['teacherName'] is! String ||
          data['teacherUid'] is! String) {
        throw FormatException('Cours invalide : ${document.id}.');
      }
      courses.add(
        AdminCourse(
          id: document.id,
          name: data['name'] as String,
          teacherName: data['teacherName'] as String,
          teacherUid: data['teacherUid'] as String,
          description: data['description'] as String?,
        ),
      );
    }
    final enrollments = <AdminEnrollment>[];
    for (final document in results[2].docs) {
      final data = document.data();
      final studentUid = data['studentUid'];
      final courseId = data['courseId'];
      final status = data['status'];
      final classId = data['classId'];
      if (studentUid is! String ||
          courseId is! String ||
          status is! String ||
          (classId != null && classId is! String) ||
          !const {'active', 'inactive'}.contains(status) ||
          document.id != '${studentUid}_$courseId') {
        throw FormatException('Inscription invalide : ${document.id}.');
      }
      enrollments.add(
        AdminEnrollment(
          id: document.id,
          studentUid: studentUid,
          courseId: courseId,
          status: status,
          classId: classId as String?,
        ),
      );
    }
    final sessions = <AdminSession>[];
    for (final document in results[3].docs) {
      final data = document.data();
      final startsAt = data['startsAt'];
      if (data['courseId'] is! String ||
          data['teacherUid'] is! String ||
          startsAt is! Timestamp) {
        throw FormatException('Séance invalide : ${document.id}.');
      }
      final endsAt = data['endsAt'];
      if ((endsAt != null && endsAt is! Timestamp) ||
          (data['room'] != null && data['room'] is! String)) {
        throw FormatException(
          'Champs invalides dans la séance ${document.id}.',
        );
      }
      sessions.add(
        AdminSession(
          id: document.id,
          courseId: data['courseId'] as String,
          teacherUid: data['teacherUid'] as String,
          startsAt: startsAt.toDate(),
          endsAt: (endsAt as Timestamp?)?.toDate(),
          room: data['room'] as String?,
        ),
      );
    }
    final attendance = <AdminAttendance>[];
    for (final document in results[4].docs) {
      final data = document.data();
      final uid = data['studentUid'];
      final sessionId = data['sessionId'];
      final courseId = data['courseId'];
      final status = data['status'];
      final recordedAt = data['recordedAt'];
      if (uid is! String ||
          sessionId is! String ||
          courseId is! String ||
          status is! String ||
          !const {'present', 'late', 'absent'}.contains(status) ||
          recordedAt is! Timestamp ||
          document.id != '${uid}_$sessionId') {
        throw FormatException('Pointage invalide : ${document.id}.');
      }
      attendance.add(
        AdminAttendance(
          studentUid: uid,
          courseId: courseId,
          sessionId: sessionId,
          status: status,
          recordedAt: recordedAt.toDate(),
        ),
      );
    }
    final classes = <AdminClass>[];
    for (final document in results[5].docs) {
      final data = document.data();
      if (data['name'] is! String ||
          data['group'] is! String ||
          data['level'] is! String ||
          data['academicYear'] is! String) {
        throw FormatException('Classe invalide : ${document.id}.');
      }
      classes.add(
        AdminClass(
          id: document.id,
          name: data['name'] as String,
          group: data['group'] as String,
          level: data['level'] as String,
          academicYear: data['academicYear'] as String,
        ),
      );
    }
    final subjects = <AdminSubject>[];
    for (final document in results[6].docs) {
      final data = document.data();
      final classIds = data['classIds'];
      if (data['name'] is! String ||
          classIds is! List ||
          classIds.any((id) => id is! String) ||
          (data['description'] != null && data['description'] is! String)) {
        throw FormatException('Matière invalide : ${document.id}.');
      }
      subjects.add(
        AdminSubject(
          id: document.id,
          name: data['name'] as String,
          description: data['description'] as String?,
          classIds: classIds.cast<String>(),
        ),
      );
    }
    final teacherAssignments = <AdminTeacherAssignment>[];
    for (final document in results[7].docs) {
      final data = document.data();
      if (data['teacherId'] is! String ||
          data['classId'] is! String ||
          data['subject'] is! String ||
          !const {'active', 'inactive'}.contains(data['status'])) {
        throw FormatException(
          'Affectation enseignant invalide : ${document.id}.',
        );
      }
      teacherAssignments.add(
        AdminTeacherAssignment(
          id: document.id,
          teacherId: data['teacherId'] as String,
          classId: data['classId'] as String,
          subject: data['subject'] as String,
          status: data['status'] as String,
        ),
      );
    }
    return AdminWorkspaceData(
      users: users,
      courses: courses,
      enrollments: enrollments,
      sessions: sessions,
      attendance: attendance,
      classes: classes,
      subjects: subjects,
      teacherAssignments: teacherAssignments,
    );
  }

  Future<void> updateStudentClass(String uid, String? className) async {
    final value = className?.trim();
    await _firestore.collection('users').doc(uid).update({
      if (value == null || value.isEmpty)
        'className': FieldValue.delete()
      else
        'className': value,
    });
  }

  Future<void> setAccountActive(String uid, bool isActive) async {
    await _api.post('/api/admin/users/${Uri.encodeComponent(uid)}/status', {
      'isActive': isActive,
    });
  }

  Future<void> createCourse({
    required String name,
    required AppUser teacher,
    String? description,
  }) async {
    final courseName = name.trim();
    if (courseName.isEmpty)
      throw ArgumentError('Le nom du cours est obligatoire.');
    await _firestore.collection('courses').add({
      'name': courseName,
      'teacherName': teacher.displayName,
      'teacherUid': teacher.uid,
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    });
  }

  Future<void> updateCourse({
    required String courseId,
    required String name,
    required AppUser teacher,
    String? description,
  }) async {
    final courseName = name.trim();
    if (courseName.isEmpty)
      throw ArgumentError('Le nom du cours est obligatoire.');
    await _firestore.collection('courses').doc(courseId).update({
      'name': courseName,
      'teacherName': teacher.displayName,
      'teacherUid': teacher.uid,
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim()
      else
        'description': FieldValue.delete(),
    });
  }

  Future<void> createEnrollment({
    required AppUser student,
    required AdminCourse course,
    String? classId,
  }) async {
    final reference = _firestore
        .collection('enrollments')
        .doc('${student.uid}_${course.id}');
    await _firestore.runTransaction((transaction) async {
      final existing = await transaction.get(reference);
      if (existing.exists && existing.data()?['status'] == 'active') {
        throw StateError('Cet étudiant est déjà inscrit à ce cours.');
      }
      transaction.set(reference, {
        'studentUid': student.uid,
        'courseId': course.id,
        'status': 'active',
        if (classId != null) 'classId': classId,
      });
    });
  }

  Future<void> updateEnrollmentStatus(String id, String status) async {
    if (!const {'active', 'inactive'}.contains(status)) {
      throw ArgumentError.value(
        status,
        'status',
        'unsupported enrollment status',
      );
    }
    await _firestore.collection('enrollments').doc(id).update({
      'status': status,
    });
  }

  Future<void> createClass({
    required String name,
    required String group,
    required String level,
    required String academicYear,
  }) async {
    final values = {
      'name': name.trim(),
      'group': group.trim(),
      'level': level.trim(),
      'academicYear': academicYear.trim(),
    };
    if (values.values.any((value) => value.isEmpty))
      throw ArgumentError('Tous les champs de la classe sont obligatoires.');
    await _firestore.collection('classes').add(values);
  }

  Future<void> updateClass({
    required String classId,
    required String name,
    required String group,
    required String level,
    required String academicYear,
  }) async {
    final values = {
      'name': name.trim(),
      'group': group.trim(),
      'level': level.trim(),
      'academicYear': academicYear.trim(),
    };
    if (values.values.any((value) => value.isEmpty))
      throw ArgumentError('Tous les champs de la classe sont obligatoires.');
    await _firestore.collection('classes').doc(classId).update(values);
  }

  Future<void> removeClass(AdminClass item) async {
    final references = await Future.wait([
      _firestore
          .collection('users')
          .where('className', isEqualTo: item.name)
          .limit(1)
          .get(),
      _firestore
          .collection('subjects')
          .where('classIds', arrayContains: item.id)
          .limit(1)
          .get(),
      _firestore
          .collection('teacherAssignments')
          .where('classId', isEqualTo: item.id)
          .limit(1)
          .get(),
      _firestore
          .collection('enrollments')
          .where('classId', isEqualTo: item.id)
          .limit(1)
          .get(),
    ]);
    if (references.any((snapshot) => snapshot.docs.isNotEmpty)) {
      throw StateError(
        'Cette classe est encore liée à des utilisateurs, matières, affectations ou inscriptions.',
      );
    }
    await _firestore.collection('classes').doc(item.id).delete();
  }

  Future<void> createSubject({
    required String name,
    required String description,
    required List<String> classIds,
  }) async {
    final subjectName = name.trim();
    if (subjectName.isEmpty || classIds.isEmpty)
      throw ArgumentError('Le nom et au moins une classe sont obligatoires.');
    await _firestore.collection('subjects').add({
      'name': subjectName,
      'classIds': classIds.toSet().toList(),
      if (description.trim().isNotEmpty) 'description': description.trim(),
    });
  }

  Future<void> updateSubject({
    required String subjectId,
    required String name,
    required String description,
    required List<String> classIds,
  }) async {
    final subjectName = name.trim();
    if (subjectName.isEmpty || classIds.isEmpty)
      throw ArgumentError('Le nom et au moins une classe sont obligatoires.');
    final assignments = await _firestore
        .collection('teacherAssignments')
        .where('subject', isEqualTo: subjectId)
        .get();
    final retainedIds = classIds.toSet();
    if (assignments.docs.any(
      (document) => !retainedIds.contains(document.data()['classId']),
    )) {
      throw StateError(
        'Une classe ne peut pas être retirée tant qu’une affectation enseignant la référence.',
      );
    }
    await _firestore.collection('subjects').doc(subjectId).update({
      'name': subjectName,
      'classIds': retainedIds.toList(),
      'description': description.trim().isEmpty
          ? FieldValue.delete()
          : description.trim(),
    });
  }

  Future<void> removeSubject(AdminSubject subject) async {
    final assignment = await _firestore
        .collection('teacherAssignments')
        .where('subject', isEqualTo: subject.id)
        .limit(1)
        .get();
    if (assignment.docs.isNotEmpty)
      throw StateError(
        'Cette matière est encore utilisée par une affectation enseignant.',
      );
    await _firestore.collection('subjects').doc(subject.id).delete();
  }

  Future<void> createTeacherAssignment({
    required AppUser teacher,
    required AdminClass schoolClass,
    required AdminSubject subject,
  }) async {
    if (!subject.classIds.contains(schoolClass.id)) {
      throw ArgumentError(
        'Cette matière n’est pas associée à la classe sélectionnée.',
      );
    }
    final assignments = await _firestore
        .collection('teacherAssignments')
        .where('teacherId', isEqualTo: teacher.uid)
        .get();
    final matching = assignments.docs
        .where(
          (document) =>
              document.data()['classId'] == schoolClass.id &&
              document.data()['subject'] == subject.id,
        )
        .toList();
    if (matching.any((document) => document.data()['status'] == 'active')) {
      throw StateError('Cette affectation active existe déjà.');
    }
    if (matching.length > 1)
      throw StateError(
        'Plusieurs affectations identiques existent déjà. Corrigez-les avant de continuer.',
      );
    final assignment = matching.isEmpty
        ? _firestore.collection('teacherAssignments').doc()
        : matching.first.reference;
    final courseName =
        '${subject.name} • ${schoolClass.name} (${schoolClass.group})';
    final batch = _firestore.batch();
    batch.set(assignment, {
      'teacherId': teacher.uid,
      'classId': schoolClass.id,
      'subject': subject.id,
      'status': 'active',
    });
    // `courses` remains the operational contract consumed by the existing
    // Teacher and Student modules. The assignment document ID is its courseId.
    batch.set(_firestore.collection('courses').doc(assignment.id), {
      'name': courseName.length > 120
          ? courseName.substring(0, 120)
          : courseName,
      'teacherName': teacher.displayName,
      'teacherUid': teacher.uid,
      if (subject.description?.isNotEmpty == true)
        'description': subject.description,
    });
    await batch.commit();
  }

  Future<void> updateTeacherAssignmentStatus({
    required AdminTeacherAssignment assignment,
    required String status,
    required AppUser teacher,
    required AdminClass schoolClass,
    required AdminSubject subject,
  }) async {
    if (!const {'active', 'inactive'}.contains(status))
      throw ArgumentError.value(
        status,
        'status',
        'unsupported assignment status',
      );
    final batch = _firestore.batch();
    batch.update(
      _firestore.collection('teacherAssignments').doc(assignment.id),
      {'status': status},
    );
    if (status == 'inactive') {
      final references = await Future.wait([
        _firestore
            .collection('sessions')
            .where('courseId', isEqualTo: assignment.id)
            .limit(1)
            .get(),
        _firestore
            .collection('enrollments')
            .where('courseId', isEqualTo: assignment.id)
            .limit(1)
            .get(),
        _firestore
            .collection('attendance')
            .where('courseId', isEqualTo: assignment.id)
            .limit(1)
            .get(),
      ]);
      if (references.any((snapshot) => snapshot.docs.isNotEmpty)) {
        throw StateError(
          'Cette affectation a des séances, inscriptions ou présences liées. Coordonnez sa désactivation avec l’équipe Teacher.',
        );
      }
      batch.delete(_firestore.collection('courses').doc(assignment.id));
      await batch.commit();
      return;
    }
    if (!subject.classIds.contains(schoolClass.id)) {
      throw ArgumentError('La matière n’est plus associée à cette classe.');
    }
    final courseName =
        '${subject.name} • ${schoolClass.name} (${schoolClass.group})';
    batch.set(_firestore.collection('courses').doc(assignment.id), {
      'name': courseName.length > 120
          ? courseName.substring(0, 120)
          : courseName,
      'teacherName': teacher.displayName,
      'teacherUid': teacher.uid,
      if (subject.description?.isNotEmpty == true)
        'description': subject.description,
    });
    await batch.commit();
  }

  Future<void> removeTeacherAssignment(
    AdminTeacherAssignment assignment,
  ) async {
    final references = await Future.wait([
      _firestore
          .collection('sessions')
          .where('courseId', isEqualTo: assignment.id)
          .limit(1)
          .get(),
      _firestore
          .collection('enrollments')
          .where('courseId', isEqualTo: assignment.id)
          .limit(1)
          .get(),
      _firestore
          .collection('attendance')
          .where('courseId', isEqualTo: assignment.id)
          .limit(1)
          .get(),
    ]);
    if (references.any((snapshot) => snapshot.docs.isNotEmpty)) {
      throw StateError(
        'Cette affectation conserve des séances, inscriptions ou présences. Désactivez-la pour préserver l’historique.',
      );
    }
    final batch = _firestore.batch();
    batch.delete(
      _firestore.collection('teacherAssignments').doc(assignment.id),
    );
    batch.delete(_firestore.collection('courses').doc(assignment.id));
    await batch.commit();
  }

  Future<void> updateTeacherAssignment({
    required AdminTeacherAssignment assignment,
    required AppUser teacher,
    required AdminClass schoolClass,
    required AdminSubject subject,
  }) async {
    if (!subject.classIds.contains(schoolClass.id)) {
      throw ArgumentError(
        'La matière n’est pas associée à la classe sélectionnée.',
      );
    }
    final references = await Future.wait([
      _firestore
          .collection('sessions')
          .where('courseId', isEqualTo: assignment.id)
          .limit(1)
          .get(),
      _firestore
          .collection('enrollments')
          .where('courseId', isEqualTo: assignment.id)
          .limit(1)
          .get(),
      _firestore
          .collection('attendance')
          .where('courseId', isEqualTo: assignment.id)
          .limit(1)
          .get(),
    ]);
    if (references.any((snapshot) => snapshot.docs.isNotEmpty)) {
      throw StateError(
        'Cette affectation est déjà utilisée. Créez une nouvelle affectation pour préserver son historique.',
      );
    }
    final matchingAssignments = await _firestore
        .collection('teacherAssignments')
        .where('teacherId', isEqualTo: teacher.uid)
        .get();
    if (matchingAssignments.docs.any(
      (document) =>
          document.id != assignment.id &&
          document.data()['classId'] == schoolClass.id &&
          document.data()['subject'] == subject.id &&
          document.data()['status'] == 'active',
    )) {
      throw StateError(
        'Une affectation active existe déjà pour cet enseignant, cette classe et cette matière.',
      );
    }
    final courseName =
        '${subject.name} • ${schoolClass.name} (${schoolClass.group})';
    final batch = _firestore.batch();
    batch.update(
      _firestore.collection('teacherAssignments').doc(assignment.id),
      {
        'teacherId': teacher.uid,
        'classId': schoolClass.id,
        'subject': subject.id,
      },
    );
    if (assignment.status == 'active') {
      batch.set(_firestore.collection('courses').doc(assignment.id), {
        'name': courseName.length > 120
            ? courseName.substring(0, 120)
            : courseName,
        'teacherName': teacher.displayName,
        'teacherUid': teacher.uid,
        if (subject.description?.isNotEmpty == true)
          'description': subject.description,
      });
    }
    await batch.commit();
  }

  Future<void> removeEnrollment(String id) =>
      _firestore.collection('enrollments').doc(id).delete();

  Future<int> sendNotification({
    required Iterable<String> recipientUids,
    required String title,
    required String message,
  }) async {
    final uids = recipientUids.toSet().toList();
    final normalizedTitle = title.trim();
    final normalizedMessage = message.trim();
    if (uids.isEmpty) throw ArgumentError('Aucun destinataire sélectionné.');
    if (normalizedTitle.isEmpty || normalizedTitle.length > 120) {
      throw ArgumentError('Le titre doit contenir entre 1 et 120 caractères.');
    }
    if (normalizedMessage.isEmpty || normalizedMessage.length > 2000) {
      throw ArgumentError(
        'Le message doit contenir entre 1 et 2 000 caractères.',
      );
    }

    final notificationId = _firestore.collection('users').doc().id;
    for (var start = 0; start < uids.length; start += 450) {
      final batch = _firestore.batch();
      for (final uid in uids.skip(start).take(450)) {
        final reference = _firestore
            .collection('users')
            .doc(uid)
            .collection('notifications')
            .doc(notificationId);
        batch.set(reference, {
          'title': normalizedTitle,
          'message': normalizedMessage,
          'createdAt': FieldValue.serverTimestamp(),
          'isRead': false,
        });
      }
      await batch.commit();
    }
    return uids.length;
  }

  Future<void> createSession({
    required AdminCourse course,
    required DateTime startsAt,
    DateTime? endsAt,
    String? room,
  }) async {
    final data = <String, dynamic>{
      'courseId': course.id,
      'teacherUid': course.teacherUid,
      'startsAt': Timestamp.fromDate(startsAt),
    };
    if (endsAt != null) data['endsAt'] = Timestamp.fromDate(endsAt);
    if (room != null && room.trim().isNotEmpty) data['room'] = room.trim();
    await _firestore.collection('sessions').add(data);
  }

  Future<void> removeSession(AdminSession session) async {
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

  Future<void> updateSession({
    required String sessionId,
    required AdminCourse course,
    required DateTime startsAt,
    DateTime? endsAt,
    String? room,
  }) async {
    final data = <String, dynamic>{
      'courseId': course.id,
      'teacherUid': course.teacherUid,
      'startsAt': Timestamp.fromDate(startsAt),
    };
    data['endsAt'] = endsAt == null
        ? FieldValue.delete()
        : Timestamp.fromDate(endsAt);
    data['room'] = room == null || room.trim().isEmpty
        ? FieldValue.delete()
        : room.trim();
    await _firestore.collection('sessions').doc(sessionId).update(data);
  }
}
