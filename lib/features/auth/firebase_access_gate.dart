import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../firebase/station_firebase_config.dart';

/// Wraps the entire Navigator so pushed pages and dialogs cannot bypass access.
/// Firebase identity is an activation gate; existing local roles remain separate.
class FirebaseAccessGate extends StatefulWidget {
  const FirebaseAccessGate({super.key, required this.child, this.auth});
  final Widget child;

  /// Optional adapter for isolated access-gate tests.
  final FirebaseAuth? auth;

  @override
  State<FirebaseAccessGate> createState() => _FirebaseAccessGateState();
}

class _FirebaseAccessGateState extends State<FirebaseAccessGate>
    with WidgetsBindingObserver {
  final _email = TextEditingController();
  final _password = TextEditingController();
  FirebaseAuth? _auth;
  StreamSubscription<User?>? _subscription;
  Timer? _timer;
  bool _allowed = false;
  bool _activated = false;
  bool _busy = false;
  bool _checking = false;
  bool _foreground = true;
  int _generation = 0;
  String? _error;
  String? _verifiedUid;

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (!_android) return;
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_foreground) unawaited(_verify());
    });
  }

  void _initialize() {
    try {
      if (widget.auth == null && Firebase.apps.isEmpty) {
        _error = 'تعذر الاتصال بخدمة التفعيل. أغلق التطبيق وأعد فتحه.';
        return;
      }
      if (widget.auth == null &&
          Firebase.app().options.projectId !=
              StationFirebaseConfig.pilotProjectId) {
        _error = 'إعدادات التفعيل لا تطابق مشروع المنظومة. تواصل مع المسؤول.';
        return;
      }
      _auth = widget.auth ?? FirebaseAuth.instance;
      _subscription = _auth!.authStateChanges().listen(
        (user) {
          _generation++;
          if (!mounted) return;
          setState(() {
            _allowed = false;
            _verifiedUid = null;
          });
          if (user != null) unawaited(_verify());
        },
        onError: (Object _) {
          if (mounted) {
            setState(() {
              _allowed = false;
              _error = 'تعذر التحقق من الحساب. أعد المحاولة عبر الإنترنت.';
            });
          }
        },
      );
    } catch (_) {
      _error = 'تعذر تشغيل خدمة التفعيل. أغلق التطبيق وأعد فتحه.';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Invalidate requests started before backgrounding the application.
    _generation++;
    if (mounted) setState(() => _allowed = false);
    if (_foreground) unawaited(_verify());
  }

  Future<void> _verify() async {
    final auth = _auth;
    final user = auth?.currentUser;
    if (_checking || user == null || !_foreground) return;
    _checking = true;
    final generation = _generation;
    try {
      // Disabling a user in the console does not emit authStateChanges.
      await user.reload().timeout(const Duration(seconds: 12));
      // Also reject revoked/expired credentials rather than trusting persistence.
      await user.getIdToken(true).timeout(const Duration(seconds: 12));
      if (!mounted || generation != _generation || !_foreground) return;
      if (auth!.currentUser?.uid != user.uid) return;
      setState(() {
        _activated = true;
        _verifiedUid = user.uid;
        _allowed = true;
        _error = null;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _allowed = false;
        _error = _message(e.code);
      });
      if (const {
        'user-disabled',
        'user-not-found',
        'user-token-expired',
        'invalid-user-token',
      }.contains(e.code)) {
        await auth!.signOut();
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _allowed = false;
          _error = 'يلزم اتصال بالإنترنت للتحقق من تفعيل حسابك. أعد المحاولة.';
        });
      }
    } finally {
      _checking = false;
      // A resume or account change may have invalidated the in-flight check.
      if (mounted &&
          _foreground &&
          generation != _generation &&
          _auth?.currentUser != null) {
        unawaited(_verify());
      }
    }
  }

  static String _message(String code) => switch (code) {
    'user-disabled' => 'تم إيقاف حسابك. تواصل مع مسؤول المنظومة.',
    'user-not-found' ||
    'invalid-credential' ||
    'wrong-password' => 'البريد الإلكتروني أو كلمة المرور غير صحيحة.',
    'invalid-email' => 'أدخل بريدًا إلكترونيًا صحيحًا.',
    'too-many-requests' => 'محاولات كثيرة. انتظر قليلًا ثم أعد المحاولة.',
    'operation-not-allowed' =>
      'تسجيل الدخول غير مفعّل. تواصل مع مسؤول المنظومة.',
    'user-token-expired' ||
    'invalid-user-token' => 'انتهت صلاحية الدخول. سجل الدخول مجددًا.',
    _ => 'تعذر التحقق من الحساب. تحقق من الإنترنت وأعد المحاولة.',
  };

  Future<void> _login() async {
    if (_busy || _auth == null) return;
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'أدخل البريد الإلكتروني وكلمة المرور.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth!
          .signInWithEmailAndPassword(
            email: _email.text.trim(),
            password: _password.text,
          )
          .timeout(const Duration(seconds: 24));
      _password.clear();
      await _verify();
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _message(e.code));
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'تعذر تسجيل الدخول. تحقق من الإنترنت وأعد المحاولة.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_android) return widget.child;
    final signedIn = _auth?.currentUser != null;
    final allowed = _allowed && _verifiedUid == _auth?.currentUser?.uid;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Keep local navigation and unsaved forms intact during network failures.
        // Hidden routes receive neither input nor semantics while access is locked.
        if (_activated)
          Offstage(
            offstage: !allowed,
            child: TickerMode(enabled: allowed, child: widget.child),
          ),
        if (!allowed)
          Positioned.fill(
            child: PopScope(
              canPop: false,
              child: Scaffold(
                body: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AutofillGroup(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Icon(
                                Icons.verified_user_outlined,
                                size: 64,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'تفعيل الدخول إلى المنظومة',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'استخدم الحساب الذي منحك إياه مسؤول المنظومة. يلزم الاتصال بالإنترنت للتحقق من التفعيل.',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              if (!signedIn) ...[
                                TextField(
                                  controller: _email,
                                  enabled: !_busy,
                                  keyboardType: TextInputType.emailAddress,
                                  textDirection: TextDirection.ltr,
                                  autofillHints: const [AutofillHints.username],
                                  decoration: const InputDecoration(
                                    labelText: 'البريد الإلكتروني',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _password,
                                  enabled: !_busy,
                                  obscureText: true,
                                  textDirection: TextDirection.ltr,
                                  autofillHints: const [AutofillHints.password],
                                  onSubmitted: (_) => _login(),
                                  decoration: const InputDecoration(
                                    labelText: 'كلمة المرور',
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                              FilledButton(
                                onPressed: _busy || _auth == null
                                    ? null
                                    : () async {
                                        if (signedIn) {
                                          setState(() => _busy = true);
                                          await _verify();
                                          if (mounted)
                                            setState(() => _busy = false);
                                        } else {
                                          await _login();
                                        }
                                      },
                                child: Text(
                                  _busy
                                      ? 'جارٍ التحقق…'
                                      : signedIn
                                      ? 'إعادة التحقق'
                                      : 'تسجيل الدخول',
                                ),
                              ),
                              if (signedIn)
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          _generation++;
                                          setState(() {
                                            _allowed = false;
                                            _error = null;
                                          });
                                          await _auth!.signOut();
                                        },
                                  child: const Text('استخدام حساب آخر'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
