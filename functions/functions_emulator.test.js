const test = require('node:test');
const assert = require('node:assert/strict');
const { initializeApp: initializeClientApp, deleteApp } = require('firebase/app');
const { getAuth, connectAuthEmulator, createUserWithEmailAndPassword } = require('firebase/auth');
const { getFunctions, connectFunctionsEmulator, httpsCallable } = require('firebase/functions');
const { initializeApp: initializeAdminApp, deleteApp: deleteAdminApp } = require('firebase-admin/app');
const { getAuth: getAdminAuth } = require('firebase-admin/auth');
const { FieldValue, Timestamp, getFirestore } = require('firebase-admin/firestore');
const { createAttendanceToken } = require('./attendance_token');

const projectId = 'demo-edutrack';
const fs = require('node:fs');
const path = require('node:path');
const secretLine = fs.readFileSync(path.join(__dirname, '.secret.local'), 'utf8')
  .split(/\r?\n/)
  .find((line) => line.startsWith('EDUTRACK_QR_SIGNING_SECRET='));
if (!secretLine) throw new Error('functions/.secret.local must define EDUTRACK_QR_SIGNING_SECRET for emulator tests.');
const secret = secretLine.slice('EDUTRACK_QR_SIGNING_SECRET='.length).trim();
const apps = [];
let adminApp;
let adminDb;
let teacher;
let student;
let admin;

async function createSignedInClient(name, role) {
  const app = initializeClientApp({ projectId, apiKey: 'fake-api-key' }, `client-${name}`);
  apps.push(app);
  const auth = getAuth(app);
  connectAuthEmulator(auth, 'http://127.0.0.1:9199', { disableWarnings: true });
  const credential = await createUserWithEmailAndPassword(
    auth,
    `${name}@example.test`,
    'eduTrack-test-Password-123',
  );
  const functions = getFunctions(app);
  connectFunctionsEmulator(functions, '127.0.0.1', 5011);
  await adminDb.collection('users').doc(credential.user.uid).set({
    uid: credential.user.uid,
    email: credential.user.email,
    displayName: name,
    role,
    createdAt: FieldValue.serverTimestamp(),
  });
  return { uid: credential.user.uid, functions, auth };
}

async function callable(client, name, data) {
  return httpsCallable(client.functions, name)(data);
}

test.before(async () => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error('Run this suite through firebase emulators:exec; it never connects to production.');
  }
  adminApp = initializeAdminApp({ projectId }, `admin-${Date.now()}`);
  adminDb = getFirestore(adminApp);
  await adminDb.recursiveDelete(adminDb.collection('users'));
  await adminDb.recursiveDelete(adminDb.collection('courses'));
  await adminDb.recursiveDelete(adminDb.collection('sessions'));
  await adminDb.recursiveDelete(adminDb.collection('enrollments'));
  await adminDb.recursiveDelete(adminDb.collection('attendance'));
  await adminDb.recursiveDelete(adminDb.collection('teacherAssignments'));
  teacher = await createSignedInClient('teacher', 'teacher');
  student = await createSignedInClient('student', 'student');
  admin = await createSignedInClient('admin', 'admin');
  await getAdminAuth(adminApp).setCustomUserClaims(admin.uid, { admin: true });
  await admin.auth.currentUser.getIdToken(true);
  await adminDb.collection('courses').doc('course-1').set({
    name: 'Course One',
    teacherName: 'teacher',
    teacherUid: teacher.uid,
  });
  await adminDb.collection('courses').doc('course-2').set({
    name: 'Course Two',
    teacherName: 'Other Teacher',
    teacherUid: 'another-teacher',
  });
  await adminDb.collection('teacherAssignments').doc('course-1').set({
    teacherId: teacher.uid,
    status: 'active',
  });
  await adminDb.collection('enrollments').doc(`${student.uid}_course-1`).set({
    studentUid: student.uid,
    courseId: 'course-1',
    status: 'active',
  });
});

test.after(async () => {
  for (const app of apps) await deleteApp(app);
  if (adminApp) await deleteAdminApp(adminApp);
});

test('teacher issues a signed QR and the student records attendance once', async () => {
  const startsAt = Timestamp.fromMillis(Date.now() - 1000);
  await adminDb.collection('sessions').doc('session-1').set({
    courseId: 'course-1',
    teacherUid: teacher.uid,
    startsAt,
  });
  const qr = await callable(teacher, 'generateSessionQr', { sessionId: 'session-1' });
  assert.equal(typeof qr.data.qrPayload, 'string');
  const response = await callable(student, 'recordStudentAttendance', { qrPayload: qr.data.qrPayload });
  assert.equal(response.data.success, true);
  const attendance = await adminDb.collection('attendance').doc(`${student.uid}_session-1`).get();
  assert.equal(attendance.data().studentUid, student.uid);
  assert.equal(attendance.data().status, 'present');
  assert.equal(attendance.data().courseId, 'course-1');
  await assert.rejects(
    callable(student, 'recordStudentAttendance', { qrPayload: qr.data.qrPayload }),
    (error) => error.code === 'functions/already-exists',
  );
});

test('invalid, expired, missing-session, and un-enrolled scans are rejected', async () => {
  await assert.rejects(
    callable(student, 'recordStudentAttendance', { qrPayload: 'not-a-qr' }),
    (error) => error.code === 'functions/invalid-argument',
  );

  const missingSessionToken = createAttendanceToken('missing-session', Date.now() + 60_000, secret);
  await assert.rejects(
    callable(student, 'recordStudentAttendance', { qrPayload: missingSessionToken }),
    (error) => error.code === 'functions/not-found',
  );

  const expiredStart = Date.now() - 16 * 60 * 1000;
  await adminDb.collection('sessions').doc('session-expired').set({
    courseId: 'course-1',
    teacherUid: teacher.uid,
    startsAt: Timestamp.fromMillis(expiredStart),
  });
  const expiredToken = createAttendanceToken('session-expired', expiredStart + 15 * 60 * 1000, secret);
  await assert.rejects(
    callable(student, 'recordStudentAttendance', { qrPayload: expiredToken }),
    (error) => error.code === 'functions/deadline-exceeded',
  );

  await adminDb.collection('courses').doc('course-2').set({
    name: 'Course Two',
    teacherName: 'teacher',
    teacherUid: teacher.uid,
  });
  const unEnrolledStart = Date.now() - 1000;
  await adminDb.collection('sessions').doc('session-un-enrolled').set({
    courseId: 'course-2',
    teacherUid: teacher.uid,
    startsAt: Timestamp.fromMillis(unEnrolledStart),
  });
  const unEnrolledToken = createAttendanceToken(
    'session-un-enrolled',
    unEnrolledStart + 15 * 60 * 1000,
    secret,
  );
  await assert.rejects(
    callable(student, 'recordStudentAttendance', { qrPayload: unEnrolledToken }),
    (error) => error.code === 'functions/permission-denied',
  );

  await assert.rejects(
    callable(teacher, 'recordStudentAttendance', { qrPayload: unEnrolledToken }),
    (error) => error.code === 'functions/permission-denied',
  );
});

test('teacher cannot issue a QR for a course assigned to a different teacher', async () => {
  await adminDb.collection('courses').doc('course-2').set({
    name: 'Course Two',
    teacherName: 'Other Teacher',
    teacherUid: 'another-teacher',
  });
  await adminDb.collection('sessions').doc('session-other').set({
    courseId: 'course-2',
    teacherUid: 'another-teacher',
    startsAt: Timestamp.fromMillis(Date.now() + 60_000),
  });
  await assert.rejects(
    callable(teacher, 'generateSessionQr', { sessionId: 'session-other' }),
    (error) => error.code === 'functions/permission-denied',
  );
  await adminDb.collection('sessions').doc('session-inconsistent').set({
    courseId: 'course-2',
    teacherUid: teacher.uid,
    startsAt: Timestamp.fromMillis(Date.now() + 60_000),
  });
  await assert.rejects(
    callable(teacher, 'generateSessionQr', { sessionId: 'session-inconsistent' }),
    (error) => error.code === 'functions/failed-precondition',
  );
});

test('closing a session creates absences once and alerts the teacher on repeats', async () => {
  const recordedAt = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
  await adminDb.collection('attendance').doc(`${student.uid}_older-session`).set({
    studentUid: student.uid,
    sessionId: 'older-session',
    courseId: 'course-1',
    status: 'absent',
    recordedAt,
  });
  await adminDb.collection('sessions').doc('session-to-close').set({
    courseId: 'course-1',
    teacherUid: teacher.uid,
    startsAt: Timestamp.fromMillis(Date.now() - 60 * 60 * 1000),
    status: 'open',
    startedAt: Timestamp.fromMillis(Date.now() - 60 * 60 * 1000),
  });

  const close = () => callable(teacher, 'closeTeacherSession', { sessionId: 'session-to-close' });
  const first = await close();
  assert.equal(first.data.absences, 1);
  await close();

  const absence = await adminDb.collection('attendance')
    .doc(`${student.uid}_session-to-close`).get();
  assert.equal(absence.data().status, 'absent');
  const studentNotice = await adminDb.collection('users').doc(student.uid)
    .collection('notifications').doc('absence_session-to-close').get();
  assert.equal(studentNotice.exists, true);
  const teacherNotice = await adminDb.collection('users').doc(teacher.uid)
    .collection('notifications').doc(`repeated_absence_${student.uid}_session-to-close`).get();
  assert.equal(teacherNotice.data().title, 'Absences répétées');

  await adminDb.collection('sessions').doc('session-with-presence').set({
    courseId: 'course-1',
    teacherUid: teacher.uid,
    startsAt: Timestamp.fromMillis(Date.now() - 60 * 60 * 1000),
    status: 'open',
  });
  const presentRef = adminDb.collection('attendance')
    .doc(`${student.uid}_session-with-presence`);
  await presentRef.set({
    studentUid: student.uid,
    sessionId: 'session-with-presence',
    courseId: 'course-1',
    status: 'present',
    recordedAt: Timestamp.now(),
  });
  const closedPresence = await callable(teacher, 'closeTeacherSession', {
    sessionId: 'session-with-presence',
  });
  assert.equal(closedPresence.data.absences, 0);
  assert.equal((await presentRef.get()).data().status, 'present');
});

test('teacher student lists are scoped to assigned courses and admin requires a custom claim', async () => {
  const teacherList = await callable(teacher, 'getEnrolledStudents', { courseId: 'course-1' });
  assert.deepEqual(teacherList.data.students.map((item) => item.uid), [student.uid]);
  await adminDb.collection('courses').doc('course-2').set({
    name: 'Course Two',
    teacherName: 'Other Teacher',
    teacherUid: 'another-teacher',
  });
  await assert.rejects(
    callable(teacher, 'getEnrolledStudents', { courseId: 'course-2' }),
    (error) => error.code === 'functions/permission-denied',
  );
  const adminList = await callable(admin, 'getEnrolledStudents', { courseId: 'course-1' });
  assert.equal(adminList.data.students.length, 1);
});

test('admin can disable and re-enable student accounts without creating accounts', async () => {
  await assert.rejects(
    callable(student, 'setUserAccountStatus', { uid: teacher.uid, isActive: false }),
    (error) => error.code === 'functions/permission-denied',
  );
  await assert.rejects(
    callable(admin, 'setUserAccountStatus', { uid: admin.uid, isActive: false }),
    (error) => error.code === 'functions/failed-precondition',
  );
  await callable(admin, 'setUserAccountStatus', { uid: student.uid, isActive: false });
  const disabledProfile = await adminDb.collection('users').doc(student.uid).get();
  const disabledAuthUser = await getAdminAuth(adminApp).getUser(student.uid);
  assert.equal(disabledProfile.data().isActive, false);
  assert.equal(disabledAuthUser.disabled, true);
  await assert.rejects(
    callable(student, 'recordStudentAttendance', { qrPayload: 'invalid' }),
    (error) => error.code === 'functions/permission-denied',
  );

  await callable(admin, 'setUserAccountStatus', { uid: student.uid, isActive: true });
  const activeProfile = await adminDb.collection('users').doc(student.uid).get();
  const activeAuthUser = await getAdminAuth(adminApp).getUser(student.uid);
  assert.equal(activeProfile.data().isActive, true);
  assert.equal(activeAuthUser.disabled, false);
});
