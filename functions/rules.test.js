const fs = require('node:fs');
const path = require('node:path');
const { after, before, beforeEach, test } = require('node:test');
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  collection,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

let environment;
const projectId = 'demo-edutrack-rules';

before(async () => {
  environment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
    },
  });
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await Promise.all([
      setDoc(doc(db, 'users/student-1'), {
        uid: 'student-1', email: 'one@example.edu', displayName: 'Student One', role: 'student',
      }),
      setDoc(doc(db, 'users/student-2'), {
        uid: 'student-2', email: 'two@example.edu', displayName: 'Student Two', role: 'student',
      }),
      setDoc(doc(db, 'users/teacher-1'), {
        uid: 'teacher-1', email: 'teacher@example.edu', displayName: 'Teacher One', role: 'teacher',
      }),
      setDoc(doc(db, 'users/admin-1'), {
        uid: 'admin-1', email: 'admin@example.edu', displayName: 'Admin One', role: 'admin',
      }),
      setDoc(doc(db, 'courses/course-1'), {
        name: 'Course One', teacherName: 'Teacher One', teacherUid: 'teacher-1',
      }),
      setDoc(doc(db, 'teacherAssignments/course-1'), {
        teacherId: 'teacher-1', classId: 'class-1', subject: 'subject-1', status: 'active',
      }),
      setDoc(doc(db, 'courses/course-2'), {
        name: 'Course Two', teacherName: 'Other Teacher', teacherUid: 'teacher-2',
      }),
      setDoc(doc(db, 'enrollments/student-1_course-1'), {
        studentUid: 'student-1', courseId: 'course-1', status: 'active',
      }),
      setDoc(doc(db, 'sessions/session-1'), {
        courseId: 'course-1', teacherUid: 'teacher-1', startsAt: new Date(),
      }),
      setDoc(doc(db, 'sessions/session-2'), {
        courseId: 'course-2', teacherUid: 'teacher-2', startsAt: new Date(),
      }),
      setDoc(doc(db, 'attendance/student-1_session-1'), {
        studentUid: 'student-1', sessionId: 'session-1', courseId: 'course-1', status: 'present', recordedAt: new Date(),
      }),
      setDoc(doc(db, 'users/student-1/notifications/n1'), {
        title: 'Notice', message: 'Hello', createdAt: new Date(), isRead: false,
      }),
      setDoc(doc(db, 'users/student-2/notifications/n2'), {
        title: 'Notice', message: 'Hello', createdAt: new Date(), isRead: false,
      }),
    ]);
  });
});

after(async () => {
  await environment?.cleanup();
});

test('students can read only their private profile and enrolled course/session data', async () => {
  const db = environment.authenticatedContext('student-1').firestore();
  await assertSucceeds(getDoc(doc(db, 'users/student-1')));
  await assertFails(getDoc(doc(db, 'users/student-2')));
  await assertSucceeds(getDoc(doc(db, 'courses/course-1')));
  await assertFails(getDoc(doc(db, 'courses/course-2')));
  await assertSucceeds(getDoc(doc(db, 'sessions/session-1')));
  await assertFails(getDoc(doc(db, 'sessions/session-2')));
});

test('students cannot promote themselves, edit protected profile fields, or write attendance', async () => {
  const db = environment.authenticatedContext('student-1').firestore();
  await assertSucceeds(updateDoc(doc(db, 'users/student-1'), { displayName: 'Updated Name' }));
  await assertFails(updateDoc(doc(db, 'users/student-1'), { role: 'admin' }));
  await assertFails(updateDoc(doc(db, 'users/student-1'), { className: 'DSI L3' }));
  await assertFails(setDoc(doc(db, 'attendance/student-1_session-1'), {
    studentUid: 'student-1', sessionId: 'session-1', courseId: 'course-1', status: 'present', recordedAt: new Date(),
  }));
});

test('students can only mark their own notification as read', async () => {
  const db = environment.authenticatedContext('student-1').firestore();
  await assertSucceeds(updateDoc(doc(db, 'users/student-1/notifications/n1'), { isRead: true }));
  await assertFails(updateDoc(doc(db, 'users/student-1/notifications/n1'), { message: 'changed' }));
  await assertFails(updateDoc(doc(db, 'users/student-2/notifications/n2'), { isRead: true }));
});

test('only admins can create valid unread notifications', async () => {
  const adminDb = environment.authenticatedContext('admin-1', { admin: true }).firestore();
  const teacherDb = environment.authenticatedContext('teacher-1').firestore();
  await assertSucceeds(setDoc(doc(adminDb, 'users/student-1/notifications/admin-notice'), {
    title: 'Administrative notice',
    message: 'A session was updated.',
    createdAt: serverTimestamp(),
    isRead: false,
  }));
  await assertFails(setDoc(doc(teacherDb, 'users/student-1/notifications/teacher-notice'), {
    title: 'Unauthorized notice',
    message: 'This write must be denied.',
    createdAt: serverTimestamp(),
    isRead: false,
  }));
});

test('teachers can access their assigned course but cannot create sessions directly', async () => {
  const db = environment.authenticatedContext('teacher-1').firestore();
  await assertSucceeds(getDoc(doc(db, 'courses/course-1')));
  await assertFails(getDoc(doc(db, 'courses/course-2')));
  await assertFails(setDoc(doc(db, 'sessions/session-new'), {
    courseId: 'course-1', teacherUid: 'teacher-1', startsAt: new Date(),
  }));
  await assertFails(setDoc(doc(db, 'sessions/session-other'), {
    courseId: 'course-2', teacherUid: 'teacher-1', startsAt: new Date(),
  }));
  await assertFails(setDoc(doc(db, 'attendance/teacher-1_session-1'), {
    studentUid: 'teacher-1', sessionId: 'session-1', courseId: 'course-1', status: 'present', recordedAt: new Date(),
  }));
  await assertFails(updateDoc(doc(db, 'sessions/session-1'), {
    status: 'closed', closedAt: new Date(),
  }));
  await assertFails(setDoc(doc(db, 'courses/teacher-created'), {
    name: 'Unauthorized course', teacherName: 'Teacher One', teacherUid: 'teacher-1',
  }));
});

test('admin access depends on the custom claim', async () => {
  const claimedAdmin = environment.authenticatedContext('admin-1', { admin: true }).firestore();
  const roleOnlyAdmin = environment.authenticatedContext('admin-1').firestore();
  await assertSucceeds(getDoc(doc(claimedAdmin, 'users/student-2')));
  await assertSucceeds(getDoc(doc(claimedAdmin, 'courses/course-2')));
  await assertFails(getDoc(doc(roleOnlyAdmin, 'users/student-2')));
});

test('admin access requires the claim and matching admin profile role', async () => {
  const mismatchedAdmin = environment.authenticatedContext('teacher-1', { admin: true }).firestore();
  await assertFails(getDoc(doc(mismatchedAdmin, 'users/student-2')));
  await assertFails(getDoc(doc(mismatchedAdmin, 'courses/course-2')));
});

test('an admin cannot change their own role even with the admin claim', async () => {
  const db = environment.authenticatedContext('admin-1', { admin: true }).firestore();
  await assertFails(updateDoc(doc(db, 'users/admin-1'), { role: 'student' }));
  await assertFails(updateDoc(doc(db, 'users/admin-1'), { isActive: false }));
  await assertFails(updateDoc(doc(db, 'users/admin-1'), {
    role: 'student',
    className: 'DSI L3',
  }));
});

test('admins manage classes, subjects and assignments; teachers read only their assignments', async () => {
  const adminDb = environment.authenticatedContext('admin-1', { admin: true }).firestore();
  const teacherDb = environment.authenticatedContext('teacher-1').firestore();
  const otherTeacherDb = environment.authenticatedContext('teacher-2').firestore();
  await assertSucceeds(setDoc(doc(adminDb, 'classes/class-1'), {
    name: 'DSI', group: 'A', level: 'L3', academicYear: '2026-2027',
  }));
  await assertSucceeds(setDoc(doc(adminDb, 'subjects/subject-1'), {
    name: 'Programmation', classIds: ['class-1'],
  }));
  await assertSucceeds(setDoc(doc(adminDb, 'teacherAssignments/assignment-1'), {
    teacherId: 'teacher-1', classId: 'class-1', subject: 'subject-1', status: 'active',
  }));
  await assertSucceeds(getDoc(doc(teacherDb, 'teacherAssignments/assignment-1')));
  await assertFails(getDoc(doc(otherTeacherDb, 'teacherAssignments/assignment-1')));
  await assertFails(getDoc(doc(teacherDb, 'classes/class-1')));
  await assertFails(setDoc(doc(teacherDb, 'subjects/subject-2'), {
    name: 'Unauthorized', classIds: ['class-1'],
  }));
});

test('admin class enrollments preserve courseId and support optional classId', async () => {
  const adminDb = environment.authenticatedContext('admin-1', { admin: true }).firestore();
  await assertSucceeds(setDoc(doc(adminDb, 'classes/class-1'), {
    name: 'DSI', group: 'A', level: 'L3', academicYear: '2026-2027',
  }));
  await assertSucceeds(setDoc(doc(adminDb, 'subjects/subject-1'), {
    name: 'Programmation', classIds: ['class-1'],
  }));
  await assertSucceeds(setDoc(doc(adminDb, 'teacherAssignments/course-1'), {
    teacherId: 'teacher-1', classId: 'class-1', subject: 'subject-1', status: 'active',
  }));
  await assertSucceeds(setDoc(doc(adminDb, 'enrollments/student-1_course-1'), {
    studentUid: 'student-1', courseId: 'course-1', classId: 'class-1', status: 'active',
  }));
  await assertSucceeds(updateDoc(doc(adminDb, 'enrollments/student-1_course-1'), { status: 'inactive' }));
  await assertFails(setDoc(doc(adminDb, 'enrollments/student-2_course-1'), {
    studentUid: 'student-2', courseId: 'course-1', classId: 'missing-class', status: 'active',
  }));
});

test('disabled accounts cannot access their profile, courses, sessions or attendance', async () => {
  await environment.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users/student-1'), { isActive: false });
  });
  const db = environment.authenticatedContext('student-1').firestore();
  await assertFails(getDoc(doc(db, 'users/student-1')));
  await assertFails(getDoc(doc(db, 'courses/course-1')));
  await assertFails(getDoc(doc(db, 'sessions/session-1')));
  await assertFails(getDoc(doc(db, 'attendance/student-1_session-1')));
});
