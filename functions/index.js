const { initializeApp } = require('firebase-admin/app');
const { FieldValue, Timestamp, getFirestore } = require('firebase-admin/firestore');
const { defineSecret } = require('firebase-functions/params');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { createAttendanceToken, verifyAttendanceToken } = require('./attendance_token');

initializeApp();
const db = getFirestore();
const qrSigningSecret = defineSecret('EDUTRACK_QR_SIGNING_SECRET');
const attendanceWindowMs = 15 * 60 * 1000;

function getQrSigningSecret() {
  const secret = qrSigningSecret.value();
  if (typeof secret !== 'string' || secret.length < 32) {
    throw new HttpsError(
      'failed-precondition',
      'Le secret QR EDUTRACK_QR_SIGNING_SECRET est absent ou invalide. Configurez-le puis redéployez les fonctions.',
    );
  }
  return secret;
}

async function requireProfile(uid) {
  const snapshot = await db.collection('users').doc(uid).get();
  if (!snapshot.exists) {
    throw new HttpsError('permission-denied', 'EduTrack profile is missing.');
  }
  const profile = snapshot.data();
  if (profile.isActive === false) {
    throw new HttpsError('permission-denied', 'This EduTrack account is disabled.');
  }
  return profile;
}

exports.generateSessionQr = onCall(
  { secrets: [qrSigningSecret] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign in to generate a QR code.');
    }
    const signingSecret = getQrSigningSecret();
    const sessionId = request.data?.sessionId;
    if (
      typeof sessionId !== 'string' ||
      !sessionId.trim() ||
      sessionId.length > 256 ||
      sessionId.includes('/')
    ) {
      throw new HttpsError('invalid-argument', 'A sessionId is required.');
    }
    const profile = await requireProfile(request.auth.uid);
    const hasAdminClaim = request.auth.token.admin === true;
    if ((profile.role === 'admin') !== hasAdminClaim) {
      throw new HttpsError('permission-denied', 'The profile role and admin claim do not match.');
    }
    const isAdmin = profile.role === 'admin';
    if (profile.role !== 'teacher' && !isAdmin) {
      throw new HttpsError('permission-denied', 'Only the session teacher can issue its QR code.');
    }

    const sessionSnapshot = await db.collection('sessions').doc(sessionId).get();
    if (!sessionSnapshot.exists) {
      throw new HttpsError('not-found', 'Session not found.');
    }
    const session = sessionSnapshot.data();
    if (typeof session.courseId !== 'string' || typeof session.teacherUid !== 'string') {
      throw new HttpsError('failed-precondition', 'The session assignment is invalid.');
    }
    const courseSnapshot = await db.collection('courses').doc(session.courseId).get();
    if (!courseSnapshot.exists || courseSnapshot.data().teacherUid !== session.teacherUid) {
      throw new HttpsError('failed-precondition', 'The session and course assignments do not match.');
    }
    if (!isAdmin && session.teacherUid !== request.auth.uid) {
      throw new HttpsError('permission-denied', 'This session belongs to another teacher.');
    }
    if (!(session.startsAt instanceof Timestamp)) {
      throw new HttpsError('failed-precondition', 'The session start time is invalid.');
    }
    if (session.endsAt != null && !(session.endsAt instanceof Timestamp)) {
      throw new HttpsError('failed-precondition', 'The session end time is invalid.');
    }
    if (
      session.endsAt &&
      session.endsAt.toMillis() <= session.startsAt.toMillis()
    ) {
      throw new HttpsError('failed-precondition', 'The session end must be after its start.');
    }
    const serverNow = Date.now();
    const effectiveStart = session.startedAt instanceof Timestamp ? session.startedAt : session.startsAt;
    const expiresAt = session.qrExpiresAt instanceof Timestamp
      ? session.qrExpiresAt.toMillis()
      : effectiveStart.toMillis() + attendanceWindowMs;
    if (session.status !== 'open' || serverNow < effectiveStart.toMillis()) {
      throw new HttpsError('failed-precondition', 'The session has not started yet.');
    }
    if (serverNow >= expiresAt || (session.endsAt && serverNow >= session.endsAt.toMillis())) {
      throw new HttpsError('deadline-exceeded', 'The attendance window has expired.');
    }

    const qrPayload = createAttendanceToken(
      sessionId,
      expiresAt,
      signingSecret,
    );
    return { qrPayload, expiresAt };
  },
);

exports.recordStudentAttendance = onCall(
  { secrets: [qrSigningSecret] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign in before recording attendance.');
    }
    const signingSecret = getQrSigningSecret();
    const profile = await requireProfile(request.auth.uid);
    if (profile.role !== 'student' || request.auth.token.admin === true) {
      throw new HttpsError('permission-denied', 'Only student accounts can record attendance.');
    }

    const qrPayload = request.data?.qrPayload;
    if (typeof qrPayload !== 'string' || qrPayload.length > 2048) {
      throw new HttpsError('invalid-argument', 'The QR code payload is invalid.');
    }
    const token = verifyAttendanceToken(
      qrPayload,
      signingSecret,
      Date.now(),
      true,
    );
    if (!token) {
      throw new HttpsError('invalid-argument', 'The QR code is invalid.');
    }
    if (token.expiresAt <= Date.now()) {
      throw new HttpsError('deadline-exceeded', 'The QR code has expired.');
    }

    const sessionRef = db.collection('sessions').doc(token.sessionId);
    const attendanceRef = db.collection('attendance').doc(`${request.auth.uid}_${token.sessionId}`);
    try {
      await db.runTransaction(async (transaction) => {
        const sessionSnapshot = await transaction.get(sessionRef);
        if (!sessionSnapshot.exists) {
          throw new HttpsError('not-found', 'The session no longer exists.');
        }
        const session = sessionSnapshot.data();
        if (!(session.startsAt instanceof Timestamp) || typeof session.courseId !== 'string') {
          throw new HttpsError('failed-precondition', 'The session data is invalid.');
        }
        if (session.endsAt != null && !(session.endsAt instanceof Timestamp)) {
          throw new HttpsError('failed-precondition', 'The session end time is invalid.');
        }
        const enrollmentRef = db.collection('enrollments').doc(`${request.auth.uid}_${session.courseId}`);
        const enrollmentSnapshot = await transaction.get(enrollmentRef);
        const existing = await transaction.get(attendanceRef);
        const now = Timestamp.now();
        const effectiveStart = session.startedAt instanceof Timestamp ? session.startedAt : session.startsAt;
        const deadlineMs = session.qrExpiresAt instanceof Timestamp
          ? session.qrExpiresAt.toMillis()
          : effectiveStart.toMillis() + attendanceWindowMs;
        if (session.status !== 'open' || now.toMillis() < effectiveStart.toMillis() || now.toMillis() >= deadlineMs || token.expiresAt !== deadlineMs) {
          throw new HttpsError('deadline-exceeded', 'The attendance window is not open.');
        }
        if (session.endsAt && now.toMillis() >= session.endsAt.toMillis()) {
          throw new HttpsError('deadline-exceeded', 'The session has already ended.');
        }
        if (
          !enrollmentSnapshot.exists ||
          enrollmentSnapshot.data().studentUid !== request.auth.uid ||
          enrollmentSnapshot.data().courseId !== session.courseId ||
          enrollmentSnapshot.data().status !== 'active'
        ) {
          throw new HttpsError('permission-denied', 'You are not actively enrolled in this course.');
        }
        if (existing.exists) {
          throw new HttpsError('already-exists', 'Attendance was already recorded.');
        }
        transaction.create(attendanceRef, {
          studentUid: request.auth.uid,
          sessionId: token.sessionId,
          courseId: session.courseId,
          status: 'present',
          recordedAt: FieldValue.serverTimestamp(),
        });
      });
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      throw new HttpsError('internal', 'Attendance could not be recorded.');
    }

    return { success: true, message: 'Votre présence a été enregistrée.' };
  },
);

exports.getEnrolledStudents = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Sign in to view enrolled students.');
  }
  const profile = await requireProfile(request.auth.uid);
  const hasAdminClaim = request.auth.token.admin === true;
  if ((profile.role === 'admin') !== hasAdminClaim) {
    throw new HttpsError('permission-denied', 'The profile role and admin claim do not match.');
  }
  const isAdmin = profile.role === 'admin';
  if (profile.role !== 'teacher' && !isAdmin) {
    throw new HttpsError('permission-denied', 'This operation is for teachers.');
  }
  const courseId = request.data?.courseId;
  if (typeof courseId !== 'string' || !courseId.trim()) {
    throw new HttpsError('invalid-argument', 'A courseId is required.');
  }
  const courseSnapshot = await db.collection('courses').doc(courseId).get();
  if (!courseSnapshot.exists) {
    throw new HttpsError('not-found', 'Course not found.');
  }
  if (!isAdmin && courseSnapshot.data().teacherUid !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'This course belongs to another teacher.');
  }
  if (!isAdmin) {
    const assignment = await db.collection('teacherAssignments').doc(courseId).get();
    if (!assignment.exists || assignment.data().teacherId !== request.auth.uid || assignment.data().status !== 'active') {
      throw new HttpsError('permission-denied', 'This course assignment is inactive.');
    }
  }
  const enrollments = await db
    .collection('enrollments')
    .where('courseId', '==', courseId)
    .get();
  const students = await Promise.all(enrollments.docs.map(async (enrollment) => {
    if (enrollment.data().status !== 'active') return null;
    const uid = enrollment.data().studentUid;
    if (typeof uid !== 'string' || enrollment.id !== `${uid}_${courseId}`) return null;
    const studentSnapshot = await db.collection('users').doc(uid).get();
    if (!studentSnapshot.exists || studentSnapshot.data().role !== 'student') return null;
    const student = studentSnapshot.data();
    return {
      uid,
      displayName: typeof student.displayName === 'string' ? student.displayName : 'Étudiant',
      className: typeof student.className === 'string' ? student.className : null,
    };
  }));
  return { students: students.filter(Boolean) };
});

async function requireTeacherSession(request, sessionId) {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Connectez-vous pour gérer la séance.');
  const profile = await requireProfile(request.auth.uid);
  if (profile.role !== 'teacher' || request.auth.token.admin === true) {
    throw new HttpsError('permission-denied', 'Cette action est réservée à l’enseignant de la séance.');
  }
  const ref = db.collection('sessions').doc(sessionId);
  const snapshot = await ref.get();
  if (!snapshot.exists) throw new HttpsError('not-found', 'Séance introuvable.');
  const session = snapshot.data();
  const course = await db.collection('courses').doc(session.courseId).get();
  if (session.teacherUid !== request.auth.uid || !course.exists || course.data().teacherUid !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'Cette séance ne fait pas partie de vos affectations.');
  }
  const assignment = await db.collection('teacherAssignments').doc(session.courseId).get();
  if (!assignment.exists || assignment.data().teacherId !== request.auth.uid || assignment.data().status !== 'active') {
    throw new HttpsError('permission-denied', 'Cette affectation est inactive.');
  }
  return { ref, session, sessionId };
}

exports.startTeacherSession = onCall({ secrets: [qrSigningSecret] }, async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Connectez-vous pour ouvrir la séance.');
  }
  const sessionId = request.data?.sessionId;
  if (typeof sessionId !== 'string' || !sessionId.trim() || sessionId.includes('/')) {
    throw new HttpsError('invalid-argument', 'Identifiant de séance invalide.');
  }
  const { ref, session } = await requireTeacherSession(request, sessionId);
  const signingSecret = getQrSigningSecret();
  const now = Timestamp.now();
  if (session.status === 'closed') throw new HttpsError('failed-precondition', 'La séance est clôturée.');
  if (session.endsAt instanceof Timestamp && now.toMillis() >= session.endsAt.toMillis()) {
    throw new HttpsError('deadline-exceeded', 'L’heure de fin prévue est déjà passée.');
  }
  if (session.status !== 'open') {
    await ref.update({ status: 'open', startedAt: now, qrExpiresAt: Timestamp.fromMillis(now.toMillis() + attendanceWindowMs) });
  }
  const fresh = (await ref.get()).data();
  const startedAt = fresh.startedAt instanceof Timestamp ? fresh.startedAt : now;
  const expiresAt = fresh.qrExpiresAt instanceof Timestamp ? fresh.qrExpiresAt.toMillis() : startedAt.toMillis() + attendanceWindowMs;
  if (Date.now() >= expiresAt) throw new HttpsError('deadline-exceeded', 'La période de pointage de 15 minutes est terminée.');
  return { qrPayload: createAttendanceToken(sessionId, expiresAt, signingSecret), expiresAt };
});

exports.closeTeacherSession = onCall(async (request) => {
  const sessionId = request.data?.sessionId;
  if (typeof sessionId !== 'string' || !sessionId.trim() || sessionId.includes('/')) throw new HttpsError('invalid-argument', 'Identifiant de séance invalide.');
  const { ref, session } = await requireTeacherSession(request, sessionId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError('not-found', 'Séance introuvable.');
    const current = snapshot.data();
    if (current.status === 'closed') return;
    if (current.status !== 'open') {
      throw new HttpsError('failed-precondition', 'Ouvrez la séance avant de la clôturer.');
    }
    // Close first so an in-flight QR scan is retried and rejected before absences are reconciled.
    transaction.update(ref, { status: 'closed', closedAt: FieldValue.serverTimestamp() });
  });

  const enrollments = await db.collection('enrollments')
    .where('courseId', '==', session.courseId)
    .where('status', '==', 'active')
    .get();
  const students = enrollments.docs
    .map((document) => document.data())
    .filter((item) => typeof item.studentUid === 'string');
  let absentCount = 0;
  for (let offset = 0; offset < students.length; offset += 20) {
    await Promise.all(students.slice(offset, offset + 20).map(async (item) => {
      const attendanceRef = db.collection('attendance').doc(`${item.studentUid}_${sessionId}`);
      const notificationRef = db.collection('users').doc(item.studentUid)
        .collection('notifications').doc(`absence_${sessionId}`);
      const isAbsent = await db.runTransaction(async (transaction) => {
        const attendanceSnapshot = await transaction.get(attendanceRef);
        const notificationSnapshot = await transaction.get(notificationRef);
        if (!attendanceSnapshot.exists) {
          transaction.create(attendanceRef, {
            studentUid: item.studentUid,
            sessionId,
            courseId: session.courseId,
            status: 'absent',
            recordedAt: FieldValue.serverTimestamp(),
            source: 'session-close',
          });
        } else if (attendanceSnapshot.data().status !== 'absent') {
          return false;
        }
        if (!notificationSnapshot.exists) {
          transaction.create(notificationRef, {
            title: 'Absence enregistrée',
            message: 'Votre absence à la séance a été enregistrée.',
            createdAt: FieldValue.serverTimestamp(),
            isRead: false,
          });
        }
        return true;
      });
      if (isAbsent) absentCount++;
    }));
  }

  if (absentCount > 0) {
    const sessionAbsences = await db.collection('attendance')
      .where('sessionId', '==', sessionId)
      .where('status', '==', 'absent')
      .get();
    const courseAbsences = await db.collection('attendance')
      .where('courseId', '==', session.courseId)
      .where('status', '==', 'absent')
      .get();
    const absenceCounts = new Map();
    for (const document of courseAbsences.docs) {
      const uid = document.data().studentUid;
      if (typeof uid === 'string') absenceCounts.set(uid, (absenceCounts.get(uid) || 0) + 1);
    }
    for (const document of sessionAbsences.docs) {
      const studentUid = document.data().studentUid;
      if (typeof studentUid !== 'string' || (absenceCounts.get(studentUid) || 0) < 2) continue;
      const notificationRef = db.collection('users').doc(session.teacherUid)
        .collection('notifications').doc(`repeated_absence_${studentUid}_${sessionId}`);
      await db.runTransaction(async (transaction) => {
        const notification = await transaction.get(notificationRef);
        if (!notification.exists) {
          transaction.create(notificationRef, {
            title: 'Absences répétées',
            message: 'Un étudiant inscrit à votre cours cumule au moins deux absences.',
            createdAt: FieldValue.serverTimestamp(),
            isRead: false,
          });
        }
      });
    }
  }
  return { success: true, absences: absentCount };
});

exports.correctTeacherAttendance = onCall(async (request) => {
  const { sessionId, studentUid, status, reason } = request.data || {};
  if (typeof sessionId !== 'string' || typeof studentUid !== 'string' || !['present', 'late', 'absent'].includes(status) || typeof reason !== 'string' || !reason.trim() || reason.trim().length > 500) {
    throw new HttpsError('invalid-argument', 'Un statut et un motif de correction sont obligatoires.');
  }
  const { session } = await requireTeacherSession(request, sessionId);
  if (session.status !== 'open' && session.status !== 'closed') {
    throw new HttpsError('failed-precondition', 'Ouvrez la séance avant de corriger une présence.');
  }
  if (status === 'late' && session.qrExpiresAt instanceof Timestamp && Date.now() < session.qrExpiresAt.toMillis()) {
    throw new HttpsError('failed-precondition', 'Un retard manuel peut être saisi après l’expiration de la période QR.');
  }
  const enrollment = await db.collection('enrollments').doc(`${studentUid}_${session.courseId}`).get();
  if (!enrollment.exists || enrollment.data().status !== 'active') throw new HttpsError('permission-denied', 'Cet étudiant n’est pas inscrit activement à votre cours.');
  const attendanceRef = db.collection('attendance').doc(`${studentUid}_${sessionId}`);
  const old = await attendanceRef.get();
  const before = old.exists ? old.data().status : null;
  const auditEntry = { changedBy: request.auth.uid, reason: reason.trim(), previousStatus: before, newStatus: status, changedAt: Timestamp.now() };
  await attendanceRef.set({ studentUid, sessionId, courseId: session.courseId, status, recordedAt: old.exists ? old.data().recordedAt : FieldValue.serverTimestamp(), source: 'teacher-correction', audit: FieldValue.arrayUnion(auditEntry) }, { merge: true });
  return { success: true };
});

exports.setUserAccountStatus = require('./admin_user_functions').setUserAccountStatus;
