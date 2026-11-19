const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const { HttpsError, onCall } = require('firebase-functions/v2/https');

exports.setUserAccountStatus = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Sign in to manage account status.');
  }

  const db = getFirestore();
  const callerSnapshot = await db.collection('users').doc(request.auth.uid).get();
  if (!callerSnapshot.exists ||
      callerSnapshot.data().role !== 'admin' ||
      callerSnapshot.data().isActive === false ||
      request.auth.token.admin !== true) {
    throw new HttpsError('permission-denied', 'Only an authorized administrator can manage account status.');
  }

  const uid = request.data?.uid;
  const isActive = request.data?.isActive;
  if (typeof uid !== 'string' || !uid.trim() || uid.includes('/') || typeof isActive !== 'boolean') {
    throw new HttpsError('invalid-argument', 'A user UID and boolean account status are required.');
  }
  if (uid === request.auth.uid) {
    throw new HttpsError('failed-precondition', 'Administrators cannot disable or enable their own account.');
  }

  const targetRef = db.collection('users').doc(uid);
  const targetSnapshot = await targetRef.get();
  if (!targetSnapshot.exists || !['student', 'teacher'].includes(targetSnapshot.data().role)) {
    throw new HttpsError('failed-precondition', 'Only provisioned student or teacher profiles can be managed here.');
  }

  const auth = getAuth();
  try {
    await auth.getUser(uid);
    if (isActive) {
      await auth.updateUser(uid, { disabled: false });
      await targetRef.update({ isActive: true });
    } else {
      // Disable Firestore access before changing Authentication so an existing
      // ID token cannot continue using the application during the transition.
      await targetRef.update({ isActive: false });
      await auth.updateUser(uid, { disabled: true });
    }
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    throw new HttpsError('internal', 'The account status could not be updated.');
  }

  return { success: true, uid, isActive };
});
