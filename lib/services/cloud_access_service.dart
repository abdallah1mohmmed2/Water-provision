import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/cloud_admin_config.dart';

class CloudAccessRequest {
  const CloudAccessRequest({
    required this.uid,
    required this.email,
    required this.displayName,
    this.createdAt,
  });

  final String uid;
  final String email;
  final String displayName;
  final DateTime? createdAt;

  factory CloudAccessRequest.fromSnapshot(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data();
    final timestamp = data['createdAt'];
    return CloudAccessRequest(
      uid: snapshot.id,
      email: data['email'] as String? ?? '',
      displayName: data['displayName'] as String? ?? '',
      createdAt: timestamp is Timestamp ? timestamp.toDate() : null,
    );
  }
}

class CloudStation {
  const CloudStation({
    required this.id,
    required this.name,
    required this.active,
  });

  final String id;
  final String name;
  final bool active;

  factory CloudStation.fromSnapshot(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data();
    return CloudStation(
      id: snapshot.id,
      name: data['name'] as String? ?? snapshot.id,
      active: data['active'] as bool? ?? false,
    );
  }
}

enum SaqiaCloudRole {
  manager,
  accountant,
  operations,
  beneficiary,
  partner,
  worker,
}

extension SaqiaCloudRoleText on SaqiaCloudRole {
  String get firestoreValue => name;

  String get arabicLabel => switch (this) {
    SaqiaCloudRole.manager => 'مدير محطة',
    SaqiaCloudRole.accountant => 'محاسب',
    SaqiaCloudRole.operations => 'تشغيل',
    SaqiaCloudRole.beneficiary => 'مستفيد',
    SaqiaCloudRole.partner => 'شريك',
    SaqiaCloudRole.worker => 'عامل',
  };

  bool get needsSubject => switch (this) {
    SaqiaCloudRole.beneficiary ||
    SaqiaCloudRole.partner ||
    SaqiaCloudRole.worker => true,
    _ => false,
  };
}

class CloudAccessService {
  CloudAccessService({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : auth = auth ?? FirebaseAuth.instance,
      firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;

  User? get currentUser => auth.currentUser;

  bool isRootAdmin(User user) => user.uid == rootAdminUid;

  Future<UserCredential> signIn(String email, String password) async {
    final credential = await auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await credential.user?.reload();
    return credential;
  }

  Future<UserCredential> register({
    required String displayName,
    required String email,
    required String password,
  }) async {
    final credential = await auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = credential.user;
    if (user != null) {
      await user.updateDisplayName(displayName.trim());
      await user.sendEmailVerification();
      await user.reload();
    }
    return credential;
  }

  Future<void> sendVerificationEmail(User user) => user.sendEmailVerification();

  Future<User?> refreshCurrentUser() async {
    final user = auth.currentUser;
    if (user == null) return null;
    await user.reload();
    final refreshed = auth.currentUser;
    if (refreshed != null) await refreshed.getIdToken(true);
    return auth.currentUser;
  }

  Future<void> sendPasswordReset(String email) =>
      auth.sendPasswordResetEmail(email: email.trim());

  Future<DocumentSnapshot<Map<String, dynamic>>> myAccessRequest(String uid) =>
      firestore.collection('accessRequests').doc(uid).get();

  Future<QuerySnapshot<Map<String, dynamic>>> myMemberships(String uid) =>
      firestore
          .collection('users')
          .doc(uid)
          .collection('memberships')
          .where('active', isEqualTo: true)
          .get();

  Future<void> submitAccessRequest(User user) async {
    if (!user.emailVerified || user.email == null) {
      throw StateError('تحقق من بريدك الإلكتروني أولًا.');
    }
    final requestRef = firestore.collection('accessRequests').doc(user.uid);
    final existing = await requestRef.get();
    if (existing.exists) {
      throw StateError('لديك طلب وصول سابق؛ راجع حالته في هذه الشاشة.');
    }
    await requestRef.set({
      'email': user.email,
      'displayName': (user.displayName ?? '').trim(),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchStations() =>
      firestore.collection('stations').orderBy('name').snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchPendingRequests() =>
      firestore
          .collection('accessRequests')
          .where('status', isEqualTo: 'pending')
          .snapshots();

  Future<String> createStation(String name, String createdBy) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 120) {
      throw StateError('اسم المحطة مطلوب، وبحد أقصى 120 حرفًا.');
    }
    final ref = firestore.collection('stations').doc();
    await ref.set({
      'name': normalized,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': createdBy,
    });
    return ref.id;
  }

  Future<void> approveRequest({
    required CloudAccessRequest request,
    required String stationId,
    required SaqiaCloudRole role,
    String? subjectId,
    required String reviewerUid,
  }) async {
    if (role.needsSubject && (subjectId == null || subjectId.trim().isEmpty)) {
      throw StateError('أدخل معرّف السجل الشخصي لهذا الدور.');
    }
    if (!role.needsSubject && (subjectId?.trim().isNotEmpty ?? false)) {
      throw StateError('هذا الدور لا يحتاج معرّف سجل شخصي.');
    }

    final requestRef = firestore.collection('accessRequests').doc(request.uid);
    final userRef = firestore.collection('users').doc(request.uid);
    final membershipRef = userRef.collection('memberships').doc(stationId);
    final stationRef = firestore.collection('stations').doc(stationId);

    await firestore.runTransaction((transaction) async {
      final requestSnapshot = await transaction.get(requestRef);
      if (!requestSnapshot.exists ||
          requestSnapshot.data()?['status'] != 'pending') {
        throw StateError(
          'لم يعد طلب المستخدم في حالة انتظار. حدّث القائمة وحاول مجددًا.',
        );
      }
      final stationSnapshot = await transaction.get(stationRef);
      if (!stationSnapshot.exists ||
          stationSnapshot.data()?['active'] != true) {
        throw StateError('المحطة غير موجودة أو غير نشطة.');
      }
      final userSnapshot = await transaction.get(userRef);
      if (userSnapshot.exists &&
          userSnapshot.data()?['email'] != request.email) {
        throw StateError('بريد الحساب لا يطابق طلب الوصول.');
      }

      if (!userSnapshot.exists) {
        transaction.set(userRef, {
          'email': request.email,
          'displayName': request.displayName,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      final membership = <String, Object>{
        'role': role.firestoreValue,
        'active': true,
        'assignedAt': FieldValue.serverTimestamp(),
        'assignedBy': reviewerUid,
      };
      if (role.needsSubject) membership['subjectId'] = subjectId!.trim();
      transaction.set(membershipRef, membership);
      transaction.update(requestRef, {
        'status': 'approved',
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedBy': reviewerUid,
      });
    });
  }

  Future<void> rejectRequest({
    required String uid,
    required String reviewerUid,
  }) async {
    final requestRef = firestore.collection('accessRequests').doc(uid);
    await firestore.runTransaction((transaction) async {
      final requestSnapshot = await transaction.get(requestRef);
      if (!requestSnapshot.exists ||
          requestSnapshot.data()?['status'] != 'pending') {
        throw StateError('لم يعد الطلب في حالة انتظار.');
      }
      transaction.update(requestRef, {
        'status': 'rejected',
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedBy': reviewerUid,
      });
    });
  }

  Future<void> signOut() => auth.signOut();
}
