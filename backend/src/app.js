const express = require('express');
const helmet = require('helmet');
const { FieldValue, Timestamp } = require('firebase-admin/firestore');
const {
  createAttendanceToken,
  verifyAttendanceToken,
} = require('./attendance_token');

const ATTENDANCE_WINDOW_MS = 15 * 60 * 1000;

class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function createApp({
  auth,
  db,
  signingSecret,
  allowedOrigins = [],
  allowLocalNetworkOrigins = false,
  now = Date.now,
}) {
  if (!auth || !db) throw new TypeError('Firebase Auth and Firestore are required.');
  if (
    typeof signingSecret !== 'string' ||
    Buffer.byteLength(signingSecret, 'utf8') < 32
  ) {
    throw new TypeError('EDUTRACK_QR_SIGNING_SECRET must contain 32 bytes or more.');
  }

  const app = express();
  app.disable('x-powered-by');
  app.use(helmet());
  app.use(express.json({ limit: '16kb', strict: true }));
  app.use((req, res, next) => {
    const origin = req.get('origin');
    if (
      origin &&
      !allowedOrigins.includes(origin) &&
      !(allowLocalNetworkOrigins && isLocalDevelopmentOrigin(origin))
    ) {
      return next(new ApiError(403, 'origin-denied', 'Cette origine n’est pas autorisée.'));
    }
    if (origin) {
      res.set('Access-Control-Allow-Origin', origin);
      res.set('Vary', 'Origin');
    }
    res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    return next();
  });

  app.get('/health', (_req, res) => res.json({ status: 'ok' }));

  app.use('/api', async (req, _res, next) => {
    const authorization = req.get('authorization') ?? '';
    const match = /^Bearer ([^\s]+)$/.exec(authorization);
    if (!match) {
      return next(new ApiError(401, 'unauthenticated', 'Connexion Firebase requise.'));
    }
    try {
      req.user = await auth.verifyIdToken(match[1], true);
      if (typeof req.user.uid !== 'string' || !req.user.uid) {
        throw new ApiError(401, 'unauthenticated', 'Jeton Firebase invalide.');
      }
      const profile = await db.collection('users').doc(req.user.uid).get();
      if (!profile.exists || profile.data().isActive === false) {
        throw new ApiError(403, 'permission-denied', 'Profil EduTrack absent ou désactivé.');
      }
      if ((profile.data().role === 'admin') !== (req.user.admin === true)) {
        throw new ApiError(403, 'permission-denied', 'Le rôle EduTrack ne correspond pas au jeton Firebase.');
      }
      return next();
    } catch (error) {
      if (error instanceof ApiError) return next(error);
      return next(new ApiError(401, 'unauthenticated', 'Jeton Firebase invalide ou expiré.'));
    }
  });

  app.post('/api/teacher/sessions', asyncRoute(async (req, res) => {
    const session = await createScheduledSession(db, req.user, req.body, now);
    res.status(201).json({ sessionId: session.id });
  }));

  app.post('/api/teacher/sessions/start', asyncRoute(async (req, res) => {
    const result = await createAndStartSession(
      db,
      req.user,
      req.body,
      signingSecret,
      now,
    );
    res.status(201).json(result);
  }));

  app.post('/api/teacher/sessions/:sessionId/start', asyncRoute(async (req, res) => {
    const result = await startExistingSession(
      db,
      req.user,
      req.params.sessionId,
      signingSecret,
      now,
    );
    res.json(result);
  }));

  app.post('/api/teacher/sessions/:sessionId/qr', asyncRoute(async (req, res) => {
    const result = await issueSessionQr(
      db,
      req.user,
      req.params.sessionId,
      signingSecret,
      now,
    );
    res.json(result);
  }));

  app.post('/api/teacher/sessions/:sessionId/close', asyncRoute(async (req, res) => {
    const result = await closeTeacherSession(
      db,
      req.user,
      req.params.sessionId,
      now,
    );
    res.json(result);
  }));

  app.get('/api/teacher/courses/:courseId/students', asyncRoute(async (req, res) => {
    await requireTeacher(db, req.user, req.params.courseId);
    const enrollments = await db.collection('enrollments')
      .where('courseId', '==', req.params.courseId)
      .where('status', '==', 'active')
      .get();
    const students = [];
    for (const enrollment of enrollments.docs) {
      const data = enrollment.data();
      const uid = data.studentUid;
      if (
        typeof uid !== 'string' ||
        enrollment.id !== `${uid}_${req.params.courseId}`
      ) {
        continue;
      }
      const user = await db.collection('users').doc(uid).get();
      if (!user.exists || user.data().role !== 'student' || user.data().isActive === false) {
        continue;
      }
      students.push({
        uid,
        displayName: typeof user.data().displayName === 'string'
          ? user.data().displayName
          : 'Étudiant',
        className: typeof user.data().className === 'string'
          ? user.data().className
          : null,
      });
    }
    res.json({ students });
  }));

  app.post('/api/teacher/sessions/:sessionId/attendance', asyncRoute(async (req, res) => {
    await correctTeacherAttendance(db, req.user, req.params.sessionId, req.body, now);
    res.json({ success: true });
  }));

  app.post('/api/student/attendance/scan', asyncRoute(async (req, res) => {
    const result = await recordStudentAttendance(
      db,
      req.user,
      req.body?.qrPayload,
      signingSecret,
      now,
    );
    res.json({ success: true, message: 'Votre présence a été enregistrée.' });
  }));

  app.post('/api/admin/users/:uid/status', asyncRoute(async (req, res) => {
    await setUserAccountStatus(db, auth, req.user, req.params.uid, req.body?.isActive);
    res.json({ success: true, uid: req.params.uid, isActive: req.body.isActive });
  }));

  app.use((error, _req, res, _next) => {
    if (error instanceof ApiError) {
      return res.status(error.status).json({
        error: { code: error.code, message: error.message },
      });
    }
    if (error instanceof SyntaxError && 'body' in error) {
      return res.status(400).json({
        error: { code: 'invalid-json', message: 'Corps JSON invalide.' },
      });
    }
    console.error('EduTrack API request failed:', error);
    return res.status(500).json({
      error: { code: 'internal', message: 'Le serveur n’a pas pu traiter la demande.' },
    });
  });
  return app;
}

async function createScheduledSession(db, user, body, now) {
  const courseId = requireId(body?.courseId, 'courseId');
  const startsAtMs = parseDate(body?.startsAt, 'startsAt');
  const endsAtMs = body?.endsAt == null ? null : parseDate(body.endsAt, 'endsAt');
  if (endsAtMs != null && endsAtMs <= startsAtMs) {
    throw new ApiError(400, 'invalid-argument', 'La fin doit être postérieure au début.');
  }
  const details = validateSessionDetails(body);
  const ref = db.collection('sessions').doc();
  const start = Timestamp.fromMillis(startsAtMs);
  await db.runTransaction(async (transaction) => {
    await requireTeacherInTransaction(transaction, db, user, courseId);
    transaction.create(ref, {
      courseId,
      teacherUid: user.uid,
      startsAt: start,
      ...(endsAtMs == null ? {} : { endsAt: Timestamp.fromMillis(endsAtMs) }),
      ...details,
      status: 'scheduled',
    });
  });
  return ref;
}

async function createAndStartSession(db, user, body, secret, now) {
  const courseId = requireId(body?.courseId, 'courseId');
  const durationMinutes = body?.durationMinutes;
  if (!Number.isInteger(durationMinutes) || durationMinutes < 1 || durationMinutes > 240) {
    throw new ApiError(400, 'invalid-argument', 'La durée doit être comprise entre 1 et 240 minutes.');
  }
  const details = validateSessionDetails(body);
  const serverNow = now();
  const startedAt = Timestamp.fromMillis(serverNow);
  const expiresAt = serverNow + ATTENDANCE_WINDOW_MS;
  const ref = db.collection('sessions').doc();
  await db.runTransaction(async (transaction) => {
    await requireTeacherInTransaction(transaction, db, user, courseId);
    transaction.create(ref, {
      courseId,
      teacherUid: user.uid,
      startsAt: startedAt,
      endsAt: Timestamp.fromMillis(serverNow + durationMinutes * 60 * 1000),
      ...details,
      status: 'open',
      startedAt,
      qrExpiresAt: Timestamp.fromMillis(expiresAt),
    });
  });
  return {
    sessionId: ref.id,
    qrPayload: createAttendanceToken({
      sessionId: ref.id,
      courseId,
      expiresAt,
      secret,
      now: serverNow,
    }),
    startedAt: serverNow,
    expiresAt,
  };
}

async function startExistingSession(db, user, sessionId, secret, now) {
  requireId(sessionId, 'sessionId');
  const sessionRef = db.collection('sessions').doc(sessionId);
  let session;
  const serverNow = now();
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    if (!snapshot.exists) throw new ApiError(404, 'not-found', 'Séance introuvable.');
    session = snapshot.data();
    await requireTeacherInTransaction(transaction, db, user, session.courseId);
    if (session.teacherUid !== user.uid) {
      throw new ApiError(403, 'permission-denied', 'Cette séance appartient à un autre enseignant.');
    }
    if (session.status === 'closed') {
      throw new ApiError(409, 'failed-precondition', 'La séance est clôturée.');
    }
    if (
      session.endsAt instanceof Timestamp &&
      serverNow >= session.endsAt.toMillis()
    ) {
      throw new ApiError(410, 'deadline-exceeded', 'L’heure de fin de la séance est passée.');
    }
    if (session.status !== 'open') {
      const startedAt = Timestamp.fromMillis(serverNow);
      transaction.update(sessionRef, {
        status: 'open',
        startedAt,
        qrExpiresAt: Timestamp.fromMillis(serverNow + ATTENDANCE_WINDOW_MS),
      });
      session = {
        ...session,
        status: 'open',
        startedAt,
        qrExpiresAt: Timestamp.fromMillis(serverNow + ATTENDANCE_WINDOW_MS),
      };
    }
  });
  return createQrResponse(sessionId, session, secret, now());
}

async function issueSessionQr(db, user, sessionId, secret, now) {
  requireId(sessionId, 'sessionId');
  const snapshot = await db.collection('sessions').doc(sessionId).get();
  if (!snapshot.exists) throw new ApiError(404, 'not-found', 'Séance introuvable.');
  const session = snapshot.data();
  await requireTeacher(db, user, session.courseId);
  if (session.teacherUid !== user.uid) {
    throw new ApiError(403, 'permission-denied', 'Cette séance appartient à un autre enseignant.');
  }
  return createQrResponse(sessionId, session, secret, now());
}

function createQrResponse(sessionId, session, secret, currentTime) {
  if (session.status !== 'open' || !(session.startedAt instanceof Timestamp)) {
    throw new ApiError(409, 'failed-precondition', 'La séance n’est pas ouverte.');
  }
  const expiresAt = session.qrExpiresAt instanceof Timestamp
    ? session.qrExpiresAt.toMillis()
    : session.startedAt.toMillis() + ATTENDANCE_WINDOW_MS;
  if (
    currentTime < session.startedAt.toMillis() ||
    currentTime >= expiresAt ||
    (session.endsAt instanceof Timestamp && currentTime >= session.endsAt.toMillis())
  ) {
    throw new ApiError(410, 'deadline-exceeded', 'La période QR de 15 minutes est terminée.');
  }
  return {
    sessionId,
    startedAt: session.startedAt.toMillis(),
    qrPayload: createAttendanceToken({
      sessionId,
      courseId: session.courseId,
      expiresAt,
      secret,
      now: currentTime,
    }),
    expiresAt,
  };
}

async function recordStudentAttendance(db, user, qrPayload, secret, now) {
  const serverNow = now();
  const token = verifyAttendanceToken(qrPayload, secret, serverNow, true);
  if (!token) {
    throw new ApiError(400, 'invalid-argument', 'La signature ou le contenu du QR est invalide.');
  }
  if (token.expiresAt <= serverNow) {
    throw new ApiError(410, 'deadline-exceeded', 'Le QR a expiré après 15 minutes.');
  }
  const profileRef = db.collection('users').doc(user.uid);
  const sessionRef = db.collection('sessions').doc(token.sessionId);
  const enrollmentRef = db.collection('enrollments').doc(`${user.uid}_${token.courseId}`);
  const attendanceRef = db.collection('attendance').doc(`${user.uid}_${token.sessionId}`);
  await db.runTransaction(async (transaction) => {
    const [profile, sessionSnapshot, enrollment, attendance] = await Promise.all([
      transaction.get(profileRef),
      transaction.get(sessionRef),
      transaction.get(enrollmentRef),
      transaction.get(attendanceRef),
    ]);
    requireActiveRole(profile, 'student');
    if (!sessionSnapshot.exists) {
      throw new ApiError(404, 'not-found', 'Cette séance n’existe plus.');
    }
    const session = sessionSnapshot.data();
    if (
      session.courseId !== token.courseId ||
      !(session.startedAt instanceof Timestamp) ||
      !(session.qrExpiresAt instanceof Timestamp) ||
      token.issuedAt < session.startedAt.toMillis() ||
      session.qrExpiresAt.toMillis() !== token.expiresAt
    ) {
      throw new ApiError(400, 'invalid-argument', 'Le QR ne correspond pas à cette séance.');
    }
    if (session.status !== 'open') {
      throw new ApiError(409, 'failed-precondition', 'La séance est clôturée ou n’est pas ouverte.');
    }
    const transactionNow = Timestamp.fromMillis(now());
    if (
      transactionNow.toMillis() < session.startedAt.toMillis() ||
      transactionNow.toMillis() >= session.qrExpiresAt.toMillis() ||
      (session.endsAt instanceof Timestamp && transactionNow.toMillis() >= session.endsAt.toMillis())
    ) {
      throw new ApiError(410, 'deadline-exceeded', 'La période de pointage de 15 minutes est terminée.');
    }
    if (
      !enrollment.exists ||
      enrollment.data().studentUid !== user.uid ||
      enrollment.data().courseId !== session.courseId ||
      enrollment.data().status !== 'active'
    ) {
      throw new ApiError(403, 'permission-denied', 'Vous n’êtes pas inscrit activement à ce cours.');
    }
    if (attendance.exists) {
      throw new ApiError(409, 'already-exists', 'Votre présence à cette séance a déjà été enregistrée.');
    }
    transaction.create(attendanceRef, {
      studentUid: user.uid,
      sessionId: token.sessionId,
      courseId: session.courseId,
      status: 'present',
      recordedAt: FieldValue.serverTimestamp(),
    });
  });
}

async function closeTeacherSession(db, user, sessionId, now) {
  requireId(sessionId, 'sessionId');
  const sessionRef = db.collection('sessions').doc(sessionId);
  let session;
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    if (!snapshot.exists) throw new ApiError(404, 'not-found', 'Séance introuvable.');
    session = snapshot.data();
    await requireTeacherInTransaction(transaction, db, user, session.courseId);
    if (session.teacherUid !== user.uid) {
      throw new ApiError(403, 'permission-denied', 'Cette séance appartient à un autre enseignant.');
    }
    if (session.status === 'closed') return;
    if (session.status !== 'open') {
      throw new ApiError(409, 'failed-precondition', 'Ouvrez la séance avant de la clôturer.');
    }
    transaction.update(sessionRef, {
      status: 'closed',
      closedAt: Timestamp.fromMillis(now()),
    });
  });
  if (session.status === 'closed') return { success: true, absences: 0 };

  const enrollments = await db.collection('enrollments')
    .where('courseId', '==', session.courseId)
    .where('status', '==', 'active')
    .get();
  let absences = 0;
  for (const enrollment of enrollments.docs) {
    const studentUid = enrollment.data().studentUid;
    if (typeof studentUid !== 'string') continue;
    const attendanceRef = db.collection('attendance').doc(`${studentUid}_${sessionId}`);
    const notificationRef = db.collection('users').doc(studentUid)
      .collection('notifications').doc(`absence_${sessionId}`);
    const absent = await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(attendanceRef);
      const notification = await transaction.get(notificationRef);
      if (!existing.exists) {
        transaction.create(attendanceRef, {
          studentUid,
          sessionId,
          courseId: session.courseId,
          status: 'absent',
          recordedAt: FieldValue.serverTimestamp(),
          source: 'session-close',
        });
      } else if (existing.data().status !== 'absent') {
        return false;
      }
      if (!notification.exists) {
        transaction.create(notificationRef, {
          title: 'Absence enregistrée',
          message: 'Votre absence à la séance a été enregistrée.',
          createdAt: FieldValue.serverTimestamp(),
          isRead: false,
        });
      }
      return true;
    });
    if (absent) absences++;
  }
  await notifyRepeatedAbsences(db, session, sessionId);
  return { success: true, absences };
}

async function notifyRepeatedAbsences(db, session, sessionId) {
  const records = await db.collection('attendance')
    .where('courseId', '==', session.courseId)
    .where('status', '==', 'absent')
    .get();
  const counts = new Map();
  for (const document of records.docs) {
    const uid = document.data().studentUid;
    if (typeof uid === 'string') counts.set(uid, (counts.get(uid) ?? 0) + 1);
  }
  for (const [studentUid, count] of counts) {
    if (count < 2) continue;
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

async function correctTeacherAttendance(db, user, sessionId, body, now) {
  requireId(sessionId, 'sessionId');
  const studentUid = requireId(body?.studentUid, 'studentUid');
  if (!['present', 'late', 'absent'].includes(body?.status)) {
    throw new ApiError(400, 'invalid-argument', 'Statut de présence invalide.');
  }
  if (typeof body?.reason !== 'string' || !body.reason.trim() || body.reason.trim().length > 500) {
    throw new ApiError(400, 'invalid-argument', 'Un motif de correction est obligatoire.');
  }
  const sessionRef = db.collection('sessions').doc(sessionId);
  const profileRef = db.collection('users').doc(user.uid);
  await db.runTransaction(async (transaction) => {
    const sessionSnapshot = await transaction.get(sessionRef);
    const profile = await transaction.get(profileRef);
    if (!sessionSnapshot.exists) throw new ApiError(404, 'not-found', 'Séance introuvable.');
    const session = sessionSnapshot.data();
    requireActiveRole(profile, 'teacher');
    await requireTeacherInTransaction(transaction, db, user, session.courseId);
    if (session.teacherUid !== user.uid) {
      throw new ApiError(403, 'permission-denied', 'Cette séance appartient à un autre enseignant.');
    }
    if (!['open', 'closed'].includes(session.status)) {
      throw new ApiError(409, 'failed-precondition', 'Ouvrez la séance avant de corriger une présence.');
    }
    if (
      body.status === 'late' &&
      session.qrExpiresAt instanceof Timestamp &&
      now() < session.qrExpiresAt.toMillis()
    ) {
      throw new ApiError(409, 'failed-precondition', 'Le retard manuel est possible après la fenêtre QR.');
    }
    const enrollmentRef = db.collection('enrollments').doc(`${studentUid}_${session.courseId}`);
    const attendanceRef = db.collection('attendance').doc(`${studentUid}_${sessionId}`);
    const enrollment = await transaction.get(enrollmentRef);
    const existing = await transaction.get(attendanceRef);
    if (!enrollment.exists || enrollment.data().status !== 'active') {
      throw new ApiError(403, 'permission-denied', 'Cet étudiant n’est pas inscrit activement au cours.');
    }
    const old = existing.exists ? existing.data() : null;
    const audit = {
      changedBy: user.uid,
      reason: body.reason.trim(),
      previousStatus: old?.status ?? null,
      newStatus: body.status,
      changedAt: Timestamp.fromMillis(now()),
    };
    transaction.set(attendanceRef, {
      studentUid,
      sessionId,
      courseId: session.courseId,
      status: body.status,
      recordedAt: old?.recordedAt ?? FieldValue.serverTimestamp(),
      source: 'teacher-correction',
      audit: FieldValue.arrayUnion(audit),
    }, { merge: true });
  });
}

async function setUserAccountStatus(db, auth, user, uid, isActive) {
  requireId(uid, 'uid');
  if (typeof isActive !== 'boolean') {
    throw new ApiError(400, 'invalid-argument', 'Un UID et un statut booléen sont requis.');
  }
  const caller = await db.collection('users').doc(user.uid).get();
  if (!caller.exists || caller.data().role !== 'admin' || caller.data().isActive === false || user.admin !== true) {
    throw new ApiError(403, 'permission-denied', 'Seul un administrateur autorisé peut gérer les comptes.');
  }
  if (uid === user.uid) {
    throw new ApiError(409, 'failed-precondition', 'Un administrateur ne peut pas modifier son propre compte.');
  }
  const targetRef = db.collection('users').doc(uid);
  const target = await targetRef.get();
  if (!target.exists || !['student', 'teacher'].includes(target.data().role)) {
    throw new ApiError(409, 'failed-precondition', 'Seuls les profils étudiant ou enseignant existants sont gérables.');
  }
  try {
    await auth.getUser(uid);
    if (!isActive) await targetRef.update({ isActive: false });
    await auth.updateUser(uid, { disabled: !isActive });
    if (isActive) await targetRef.update({ isActive: true });
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(500, 'account-update-failed', 'Le statut du compte n’a pas pu être modifié.');
  }
}

async function requireTeacher(db, user, courseId) {
  requireId(courseId, 'courseId');
  const [profile, course, assignment] = await Promise.all([
    db.collection('users').doc(user.uid).get(),
    db.collection('courses').doc(courseId).get(),
    db.collection('teacherAssignments').doc(courseId).get(),
  ]);
  requireActiveRole(profile, 'teacher');
  if (
    !course.exists ||
    course.data().teacherUid !== user.uid ||
    !assignment.exists ||
    assignment.data().teacherId !== user.uid ||
    assignment.data().status !== 'active'
  ) {
    throw new ApiError(403, 'permission-denied', 'Ce cours ne fait pas partie de vos affectations actives.');
  }
}

async function requireTeacherInTransaction(transaction, db, user, courseId) {
  requireId(courseId, 'courseId');
  const [profile, course, assignment] = await Promise.all([
    transaction.get(db.collection('users').doc(user.uid)),
    transaction.get(db.collection('courses').doc(courseId)),
    transaction.get(db.collection('teacherAssignments').doc(courseId)),
  ]);
  requireActiveRole(profile, 'teacher');
  if (
    !course.exists ||
    course.data().teacherUid !== user.uid ||
    !assignment.exists ||
    assignment.data().teacherId !== user.uid ||
    assignment.data().status !== 'active'
  ) {
    throw new ApiError(403, 'permission-denied', 'Ce cours ne fait pas partie de vos affectations actives.');
  }
}

function requireActiveRole(snapshot, role) {
  if (!snapshot.exists || snapshot.data().isActive === false) {
    throw new ApiError(403, 'permission-denied', 'Le profil EduTrack est absent ou désactivé.');
  }
  if (snapshot.data().role !== role) {
    throw new ApiError(403, 'permission-denied', `Cette action est réservée au rôle ${role}.`);
  }
}

function validateSessionDetails(body) {
  const details = {};
  if (body.title != null) {
    if (typeof body.title !== 'string' || !body.title.trim() || body.title.trim().length > 120) {
      throw new ApiError(400, 'invalid-argument', 'Titre de séance invalide.');
    }
    details.title = body.title.trim();
  }
  if (body.mode != null) {
    if (!['inPerson', 'online'].includes(body.mode)) {
      throw new ApiError(400, 'invalid-argument', 'Mode de séance invalide.');
    }
    details.mode = body.mode;
  }
  if (body.room != null && body.room !== '') {
    if (typeof body.room !== 'string' || body.room.trim().length > 80) {
      throw new ApiError(400, 'invalid-argument', 'Salle invalide.');
    }
    details.room = body.room.trim();
  }
  if (body.meetingUrl != null && body.meetingUrl !== '') {
    if (
      typeof body.meetingUrl !== 'string' ||
      body.meetingUrl.length > 500 ||
      !/^https?:\/\/\S+$/i.test(body.meetingUrl.trim())
    ) {
      throw new ApiError(400, 'invalid-argument', 'Lien de visioconférence invalide.');
    }
    details.meetingUrl = body.meetingUrl.trim();
  }
  return details;
}

function parseDate(value, field) {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    throw new ApiError(400, 'invalid-argument', `${field} doit être une date ISO valide.`);
  }
  return Date.parse(value);
}

function requireId(value, field) {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.length > 256 ||
    value.includes('/')
  ) {
    throw new ApiError(400, 'invalid-argument', `${field} est requis.`);
  }
  return value;
}

function asyncRoute(handler) {
  return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

function isLocalDevelopmentOrigin(origin) {
  let url;
  try {
    url = new URL(origin);
  } catch {
    return false;
  }
  if (
    url.protocol !== 'http:' ||
    !['8080', '8081'].includes(url.port) ||
    url.origin !== origin
  ) {
    return false;
  }
  if (url.hostname === 'localhost' || url.hostname === '127.0.0.1') {
    return true;
  }
  const octets = url.hostname.split('.').map(Number);
  if (
    octets.length !== 4 ||
    octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)
  ) {
    return false;
  }
  return octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168);
}

module.exports = { ApiError, createApp };
