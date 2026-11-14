import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/features/auth/firebase_access_gate.dart';

class TestUser extends Fake implements User {
  String? failure;
  Completer<void>? reloadPending;
  @override
  String get uid => 'activation-user';
  @override
  Future<void> reload() async {
    if (reloadPending != null) await reloadPending!.future;
    if (failure != null) throw FirebaseAuthException(code: failure!);
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'test-token';
}

class TestAuth extends Fake implements FirebaseAuth {
  TestAuth(this.user);
  TestUser? user;
  final events = StreamController<User?>.broadcast();
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() async* {
    yield user;
    yield* events.stream;
  }

  @override
  Future<void> signOut() async {
    user = null;
    events.add(null);
  }
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> open(WidgetTester tester, TestAuth auth) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => FirebaseAccessGate(auth: auth, child: child!),
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

  testWidgets(
    'persisted account is checked and disabled account hides pushed routes',
    (tester) async {
      final user = TestUser();
      final auth = TestAuth(user);
      await open(tester, auth);
      expect(find.text('private home'), findsOneWidget);
      await tester.tap(find.text('private home'));
      await tester.pumpAndSettle();
      expect(find.text('private pushed page'), findsOneWidget);
      user.failure = 'user-disabled';
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('private pushed page'), findsNothing);
      expect(
        find.text('تم إيقاف حسابك. تواصل مع مسؤول المنظومة.'),
        findsOneWidget,
      );
      expect(auth.currentUser, isNull);
      await tester.pumpWidget(const SizedBox());
      await auth.events.close();
    },
  );

  testWidgets('network failure blocks access and retry restores same page', (
    tester,
  ) async {
    final user = TestUser()..failure = 'network-request-failed';
    final auth = TestAuth(user);
    await open(tester, auth);
    expect(find.text('private home'), findsNothing);
    expect(find.text('إعادة التحقق'), findsOneWidget);
    user.failure = null;
    await tester.tap(find.text('إعادة التحقق'));
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('private home'), findsNothing);
    user.failure = 'user-disabled';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets('cached account cannot open app before online verification', (
    tester,
  ) async {
    final pending = Completer<void>();
    final user = TestUser()..reloadPending = pending;
    final auth = TestAuth(user);
    await open(tester, auth);
    expect(find.text('private home'), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('private home'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets('signed-out user cannot reach local application', (tester) async {
    final auth = TestAuth(null);
    await open(tester, auth);
    expect(find.text('private home'), findsNothing);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });
}
