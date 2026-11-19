const test = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { Timestamp } = require('firebase-admin/firestore');
const { createApp } = require('../src/app');
const { verifyAttendanceToken } = require('../src/attendance_token');

const secret = 'local-test-key-do-not-use-in-production-123456';

function createFixture({ allowLocalNetworkOrigins = false } = {}) {
  let serverNow = 1_800_000_000_000;
  const db = new MemoryFirestore();
  const tokens = new Map([
    ['teacher-token', { uid: 'teacher-1', admin: false }],
    ['other-teacher-token', { uid: 'teacher-2', admin: false }],
    ['student-token', { uid: 'student-1', admin: false }],
    ['other-student-token', { uid: 'student-2', admin: false }],
  ]);
  const auth = {
    async verifyIdToken(token) {
      const user = tokens.get(token);
      if (!user) throw new Error('invalid token');
      return user;
    },
  };
  db.seed('users/teacher-1', { role: 'teacher' });
  db.seed('users/teacher-2', { role: 'teacher' });
  db.seed('users/student-1', { role: 'student' });
  db.seed('users/student-2', { role: 'student' });
  db.seed('courses/course-1', { teacherUid: 'teacher-1' });
  db.seed('teacherAssignments/course-1', {
    teacherId: 'teacher-1',
    status: 'active',
  });
  db.seed('enrollments/student-1_course-1', {
    studentUid: 'student-1',
    courseId: 'course-1',
    status: 'active',
  });
  const app = createApp({
    auth,
    db,
    signingSecret: secret,
    allowLocalNetworkOrigins,
    now: () => serverNow,
  });
  return {
    app,
    db,
    setNow(value) {
      serverNow = value;
    },
  };
}

async function createStartedSession(app, authorization = 'teacher-token') {
  const response = await request(app)
    .post('/api/teacher/sessions/start')
    .set('Authorization', `Bearer ${authorization}`)
    .send({
      courseId: 'course-1',
      title: 'Cours QR',
      mode: 'inPerson',
      durationMinutes: 60,
    });
  return response;
}

test('un enseignant affecté démarre une séance et reçoit un QR non persisté', async () => {
  const { app, db } = createFixture();
  const response = await createStartedSession(app);

  assert.equal(response.status, 201);
  assert.equal(typeof response.body.sessionId, 'string');
  assert.equal(typeof response.body.qrPayload, 'string');
  assert.equal(response.body.expiresAt - response.body.startedAt, 15 * 60 * 1000);
  assert.equal(
    verifyAttendanceToken(response.body.qrPayload, secret, response.body.startedAt)
      .sessionId,
    response.body.sessionId,
  );
  const session = await db.collection('sessions').doc(response.body.sessionId).get();
  assert.equal(session.data().status, 'open');
  assert.equal('qrPayload' in session.data(), false);
  assert.equal('token' in session.data(), false);
});

test('refuse la création pour un enseignant non affecté', async () => {
  const { app } = createFixture();
  const response = await createStartedSession(app, 'other-teacher-token');
  assert.equal(response.status, 403);
  assert.equal(response.body.error.code, 'permission-denied');
});

test('enregistre une présence valide seulement pour un étudiant inscrit', async () => {
  const { app, db } = createFixture();
  const created = await createStartedSession(app);
  const response = await request(app)
    .post('/api/student/attendance/scan')
    .set('Authorization', 'Bearer student-token')
    .send({ qrPayload: created.body.qrPayload });

  assert.equal(response.status, 200);
  assert.equal(response.body.success, true);
  const attendance = await db
    .collection('attendance')
    .doc(`student-1_${created.body.sessionId}`)
    .get();
  assert.equal(attendance.data().status, 'present');
});

test('refuse un étudiant non inscrit', async () => {
  const { app } = createFixture();
  const created = await createStartedSession(app);
  const response = await request(app)
    .post('/api/student/attendance/scan')
    .set('Authorization', 'Bearer other-student-token')
    .send({ qrPayload: created.body.qrPayload });

  assert.equal(response.status, 403);
  assert.equal(response.body.error.code, 'permission-denied');
});

test('refuse le QR après sa fenêtre de 15 minutes', async () => {
  const { app, setNow } = createFixture();
  const created = await createStartedSession(app);
  setNow(created.body.expiresAt);
  const response = await request(app)
    .post('/api/student/attendance/scan')
    .set('Authorization', 'Bearer student-token')
    .send({ qrPayload: created.body.qrPayload });

  assert.equal(response.status, 410);
  assert.match(response.body.error.message, /expiré/i);
});

test('refuse un QR dont la signature a été modifiée', async () => {
  const { app } = createFixture();
  const created = await createStartedSession(app);
  const altered = `${created.body.qrPayload.slice(0, -1)}x`;
  const response = await request(app)
    .post('/api/student/attendance/scan')
    .set('Authorization', 'Bearer student-token')
    .send({ qrPayload: altered });

  assert.equal(response.status, 400);
  assert.equal(response.body.error.code, 'invalid-argument');
});

test('refuse le second pointage du même étudiant pour la séance', async () => {
  const { app } = createFixture();
  const created = await createStartedSession(app);
  const scan = () => request(app)
    .post('/api/student/attendance/scan')
    .set('Authorization', 'Bearer student-token')
    .send({ qrPayload: created.body.qrPayload });

  assert.equal((await scan()).status, 200);
  const duplicate = await scan();
  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.body.error.code, 'already-exists');
});

test('refuse le scan après clôture de la séance', async () => {
  const { app } = createFixture();
  const created = await createStartedSession(app);
  const closed = await request(app)
    .post(`/api/teacher/sessions/${created.body.sessionId}/close`)
    .set('Authorization', 'Bearer teacher-token');
  assert.equal(closed.status, 200);
  assert.equal(closed.body.absences, 1);

  const scan = await request(app)
    .post('/api/student/attendance/scan')
    .set('Authorization', 'Bearer student-token')
    .send({ qrPayload: created.body.qrPayload });
  assert.equal(scan.status, 409);
  assert.equal(scan.body.error.code, 'failed-precondition');
});

test('refuse toute requête non authentifiée', async () => {
  const { app } = createFixture();
  const response = await request(app)
    .post('/api/teacher/sessions/start')
    .send({ courseId: 'course-1', durationMinutes: 60 });

  assert.equal(response.status, 401);
  assert.equal(response.body.error.code, 'unauthenticated');
});

test('autorise les origines privées de développement mais refuse les origines publiques', async () => {
  const { app } = createFixture({ allowLocalNetworkOrigins: true });
  const preflight = (origin) =>
    request(app)
      .options('/api/teacher/sessions/start')
      .set('Origin', origin)
      .set('Access-Control-Request-Method', 'POST')
      .set('Access-Control-Request-Headers', 'authorization,content-type');

  const local = await preflight('http://10.22.212.212:8081');
  assert.equal(local.status, 204);
  assert.equal(local.headers['access-control-allow-origin'], 'http://10.22.212.212:8081');

  const publicOrigin = await preflight('http://example.com:8081');
  assert.equal(publicOrigin.status, 403);

  const wrongPort = await preflight('http://192.168.1.25:3000');
  assert.equal(wrongPort.status, 403);
});

class MemoryFirestore {
  constructor() {
    this.documents = new Map();
    this.nextId = 0;
    this.lock = Promise.resolve();
  }

  seed(path, data) {
    this.documents.set(path, data);
  }

  collection(name) {
    return new MemoryCollection(this, name);
  }

  runTransaction(callback) {
    const operation = this.lock.then(async () => {
      const transaction = new MemoryTransaction(this);
      const result = await callback(transaction);
      transaction.commit();
      return result;
    });
    this.lock = operation.catch(() => {});
    return operation;
  }
}

class MemoryCollection {
  constructor(db, path) {
    this.db = db;
    this.path = path;
    this.filters = [];
  }

  doc(id) {
    const documentId = id ?? `generated-${++this.db.nextId}`;
    return new MemoryDocument(this.db, `${this.path}/${documentId}`);
  }

  where(field, operator, value) {
    assert.equal(operator, '==');
    const query = new MemoryCollection(this.db, this.path);
    query.filters = [...this.filters, [field, value]];
    return query;
  }

  async get() {
    const prefix = `${this.path}/`;
    const docs = [...this.db.documents.entries()]
      .filter(([path]) => path.startsWith(prefix) && !path.slice(prefix.length).includes('/'))
      .filter(([, data]) => this.filters.every(([field, value]) => data[field] === value))
      .map(([path, data]) => new MemorySnapshot(path.slice(prefix.length), data));
    return { docs };
  }
}

class MemoryDocument {
  constructor(db, path) {
    this.db = db;
    this.path = path;
    this.id = path.split('/').at(-1);
  }

  collection(name) {
    return new MemoryCollection(this.db, `${this.path}/${name}`);
  }

  async get() {
    return new MemorySnapshot(this.id, this.db.documents.get(this.path));
  }

  async update(data) {
    if (!this.db.documents.has(this.path)) throw new Error('document missing');
    this.db.documents.set(this.path, {
      ...this.db.documents.get(this.path),
      ...data,
    });
  }
}

class MemorySnapshot {
  constructor(id, data) {
    this.id = id;
    this._data = data;
    this.exists = data !== undefined;
  }

  data() {
    return this._data;
  }
}

class MemoryTransaction {
  constructor(db) {
    this.db = db;
    this.writes = [];
  }

  async get(document) {
    return new MemorySnapshot(document.id, this.db.documents.get(document.path));
  }

  create(document, data) {
    this.writes.push(['create', document.path, data]);
  }

  update(document, data) {
    this.writes.push(['update', document.path, data]);
  }

  set(document, data, options) {
    this.writes.push(['set', document.path, data, options]);
  }

  commit() {
    for (const [operation, path, data, options] of this.writes) {
      if (operation === 'create' && this.db.documents.has(path)) {
        const error = new Error('document already exists');
        error.code = 6;
        throw error;
      }
      if (operation === 'update' && !this.db.documents.has(path)) {
        throw new Error('document missing');
      }
    }
    for (const [operation, path, data, options] of this.writes) {
      if (operation === 'set' && options?.merge) {
        this.db.documents.set(path, { ...this.db.documents.get(path), ...data });
      } else if (operation === 'update') {
        this.db.documents.set(path, { ...this.db.documents.get(path), ...data });
      } else {
        this.db.documents.set(path, data);
      }
    }
  }
}
