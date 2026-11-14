import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/features/auth/firebase_access_gate.dart';
import 'package:saqia_station/services/firebase_activation_store.dart';

class TestStore extends FirebaseActivationStore {
  final disabled = <String>{};
  @override
  Future<Set<String>> readDisabled() async => {...disabled};
  @override
  Future<void> writeDisabled(Set<String> uids) async {
    disabled
      ..clear()
      ..addAll(uids);
  }
}

class TestUser extends Fake implements User {
  TestUser([this.uid = 'activation-user']);
  String? failure;
  Completer<void>? reloadPending;
  @override
  final String uid;
  @override
  Future<void> reload() async {
    if (reloadPending != null) await reloadPending!.future;
    if (failure != null) throw FirebaseAuthException(code: failure!);
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'test-token';
}

class TestCredential extends Fake implements UserCredential {
  TestCredential(this.user);
  @override
  final User user;
}

class TestAuth extends Fake implements FirebaseAuth {
  TestAuth(this.user);
  TestUser? user;
  TestUser? loginUser;
  String? loginFailure;
  final events = StreamController<User?>.broadcast();
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() async* {
    yield user;
    yield* events.stream;
  }

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    if (loginFailure != null) throw FirebaseAuthException(code: loginFailure!);
    user = loginUser ?? TestUser();
    events.add(user);
    return TestCredential(user!);
  }

  @override
  Future<void> signOut() async {
    user = null;
    events.add(null);
  }
}

void main() {
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  Future<void> open(WidgetTester tester, TestAuth auth, TestStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => FirebaseAccessGate(
          auth: auth,
          activationStore: store,
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Text('private pushed page')),
                ),
              ),
              child: const Text('private home'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester, TestAuth auth) async {
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  }

  testWidgets(
    'saved Firebase login opens offline and remains open after periodic network failure',
    (tester) async {
      final user = TestUser()..failure = 'network-request-failed';
      final auth = TestAuth(user);
      final store = TestStore();
      await open(tester, auth, store);
      expect(find.text('private home'), findsOneWidget);
      await tester.tap(find.text('private home'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('private pushed page'), findsOneWidget);
      expect(find.textContaining('تعذر'), findsNothing);
      expect(store.disabled, isEmpty);
      await close(tester, auth);
    },
    variant: android,
  );

  testWidgets('timeout and offline resume do not hide an established session', (
    tester,
  ) async {
    final pending = Completer<void>();
    final user = TestUser()..reloadPending = pending;
    final auth = TestAuth(user);
    await open(tester, auth, TestStore());
    expect(find.text('private home'), findsOneWidget);
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsOneWidget);
    user.failure = 'network-request-failed';
    pending.complete();
    user.reloadPending = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsOneWidget);
    expect(find.text('إعادة التحقق'), findsNothing);
    await close(tester, auth);
  }, variant: android);

  testWidgets(
    'administrator disable hides pushed pages and remains blocked after offline restart',
    (tester) async {
      final user = TestUser();
      final auth = TestAuth(user);
      final store = TestStore();
      await open(tester, auth, store);
      await tester.tap(find.text('private home'));
      await tester.pumpAndSettle();
      user.failure = 'user-disabled';
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('private pushed page'), findsNothing);
      expect(
        find.text('تم إيقاف حسابك. تواصل مع مسؤول المنظومة.'),
        findsOneWidget,
      );
      expect(store.disabled, contains(user.uid));
      await tester.pumpWidget(const SizedBox());
      user.failure = 'network-request-failed';
      await open(tester, auth, store);
      expect(find.text('private home'), findsNothing);
      expect(
        find.text('تم إيقاف حسابك. تواصل مع مسؤول المنظومة.'),
        findsOneWidget,
      );
      await close(tester, auth);
    },
    variant: android,
  );

  testWidgets(
    'server re-enable clears persistent block and restores offline access',
    (tester) async {
      final user = TestUser()..failure = 'network-request-failed';
      final auth = TestAuth(user);
      final store = TestStore()..disabled.add(user.uid);
      await open(tester, auth, store);
      expect(find.text('private home'), findsNothing);
      user.failure = null;
      await tester.tap(find.text('إعادة التحقق'));
      await tester.pumpAndSettle();
      expect(find.text('private home'), findsOneWidget);
      expect(store.disabled, isEmpty);
      await tester.pumpWidget(const SizedBox());
      user.failure = 'network-request-failed';
      await open(tester, auth, store);
      expect(find.text('private home'), findsOneWidget);
      await close(tester, auth);
    },
    variant: android,
  );

  testWidgets('first-time user cannot activate without a successful sign-in', (
    tester,
  ) async {
    final auth = TestAuth(null)..loginFailure = 'network-request-failed';
    final store = TestStore();
    await open(tester, auth, store);
    expect(find.text('private home'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'user@example.com');
    await tester.enterText(find.byType(TextField).last, 'test-password');
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsNothing);
    auth.loginFailure = null;
    auth.loginUser = TestUser()..failure = 'network-request-failed';
    await tester.tap(find.text('تسجيل الدخول'));
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsOneWidget);
    await close(tester, auth);
  }, variant: android);

  testWidgets(
    'deleted account is blocked but temporary service and token errors do not revoke access',
    (tester) async {
      final user = TestUser()..failure = 'invalid-user-token';
      final auth = TestAuth(user);
      final store = TestStore();
      await open(tester, auth, store);
      expect(find.text('private home'), findsOneWidget);
      user.failure = 'internal-error';
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('private home'), findsOneWidget);
      user.failure = 'user-not-found';
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('private home'), findsNothing);
      expect(store.disabled, contains(user.uid));
      await close(tester, auth);
    },
    variant: android,
  );

  testWidgets(
    'an unrelated blocked UID does not lock a different signed-in user',
    (tester) async {
      final auth = TestAuth(
        TestUser('another-user')..failure = 'network-request-failed',
      );
      final store = TestStore()..disabled.add('blocked-user');
      await open(tester, auth, store);
      expect(find.text('private home'), findsOneWidget);
      expect(store.disabled, contains('blocked-user'));
      await close(tester, auth);
    },
    variant: android,
  );

  testWidgets(
    'disable response received in background cannot be bypassed by resuming offline',
    (tester) async {
      final pending = Completer<void>();
      final user = TestUser()..reloadPending = pending;
      final auth = TestAuth(user);
      final store = TestStore();
      await open(tester, auth, store);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      user.failure = 'user-disabled';
      pending.complete();
      // Drain the request while no rendering frames are scheduled.
      await tester.pump();
      await tester.pump();
      expect(store.disabled, contains(user.uid));
      user.reloadPending = null;
      user.failure = 'network-request-failed';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('private home'), findsNothing);
      await close(tester, auth);
    },
    variant: android,
  );
}
