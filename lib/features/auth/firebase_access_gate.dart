import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../firebase/station_firebase_config.dart';
import '../../services/firebase_activation_store.dart';

/// Wraps the entire Navigator so pushed pages and dialogs cannot bypass access.
/// Firebase identity is an activation gate; existing local roles remain separate.
class FirebaseAccessGate extends StatefulWidget {
  const FirebaseAccessGate({
    super.key,
    required this.child,
    this.auth,
    this.activationStore,
  });
  final Widget child;

  /// Optional adapter for isolated access-gate tests.
  final FirebaseAuth? auth;
  final FirebaseActivationStore? activationStore;

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
  late final FirebaseActivationStore _store;
  Set<String> _disabledUids = {};
  int _loginEpoch = 0;
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
    _store = widget.activationStore ?? const FirebaseActivationStore();
    unawaited(_initialize());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_foreground) unawaited(_verify());
    });
  }

  Future<void> _initialize() async {
    try {
      _disabledUids = await _store.readDisabled();
      if (!mounted) return;
      if (widget.auth == null && Firebase.apps.isEmpty) {
        setState(
          () => _error = 'تعذر تشغيل خدمة التفعيل. أغلق التطبيق وأعد فتحه.',
        );
        return;
      }
      if (widget.auth == null &&
          Firebase.app().options.projectId !=
              StationFirebaseConfig.pilotProjectId) {
        setState(
          () => _error =
              'إعدادات التفعيل لا تطابق مشروع المنظومة. تواصل مع المسؤول.',
        );
        return;
      }
      _auth = widget.auth ?? FirebaseAuth.instance;
      _subscription = _auth!.authStateChanges().listen(
        (user) {
          _generation++;
          if (!mounted) return;
          setState(() {
            // Firebase persists only accounts that already signed in. An
            // unavailable network does not invalidate that established login.
            _allowed = user != null && !_disabledUids.contains(user.uid);
            _verifiedUid = user?.uid;
            if (_allowed) {
              _activated = true;
              _error = null;
            } else if (user != null && _disabledUids.contains(user.uid)) {
              _error = _message('user-disabled');
            }
          });
          if (user != null) unawaited(_verify());
        },
        // A stream/transport failure is not an administrator's disable command.
        onError: (Object _) {},
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'تعذر قراءة إعدادات التفعيل على الجهاز. أغلق التطبيق وأعد فتحه.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Invalidate requests started before backgrounding the application.
    _generation++;
    // Keep established access during background/resume and network outages.
    if (_foreground) unawaited(_verify());
  }

  Future<void> _verify() async {
    final auth = _auth;
    final user = auth?.currentUser;
    if (_checking || user == null || !_foreground) return;
    _checking = true;
    final generation = _generation;
    final loginEpoch = _loginEpoch;
    try {
      // Disabling a user in the console does not emit authStateChanges.
      await user.reload().timeout(const Duration(seconds: 12));
      // Refresh online when possible, without making connectivity a lease.
      await user.getIdToken(true).timeout(const Duration(seconds: 12));
      if (!mounted || generation != _generation || !_foreground) return;
      if (auth!.currentUser?.uid != user.uid) return;
      if (_disabledUids.contains(user.uid)) {
        final next = {..._disabledUids}..remove(user.uid);
        await _store.writeDisabled(next);
        if (!mounted || generation != _generation || !_foreground) return;
        _disabledUids = next;
      }
      setState(() {
        _activated = true;
        _verifiedUid = user.uid;
        _allowed = true;
        _error = null;
      });
    } on FirebaseAuthException catch (e) {
      // Only an authoritative disabled/deleted-account response changes access.
      // A result from before a newer successful login cannot revoke that login.
      if (!const {'user-disabled', 'user-not-found'}.contains(e.code) ||
          loginEpoch != _loginEpoch) {
        return;
      }
      final currentUid = auth?.currentUser?.uid;
      if (currentUid != null && currentUid != user.uid) return;
      _disabledUids.add(user.uid);
      if (mounted) {
        setState(() {
          _allowed = false;
          _error = _message('user-disabled');
        });
      }
      try {
        await _store.writeDisabled({..._disabledUids});
      } catch (_) {
        // If secure storage fails, clear Firebase persistence as a fallback so
        // restarting offline cannot restore a known disabled login.
        if (auth?.currentUser?.uid == user.uid) await auth!.signOut();
      }
    } catch (_) {
      // Timeout, connectivity, service, and credential refresh errors do not
      // close a previously activated application or show an internet warning.
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
      final credential = await _auth!
          .signInWithEmailAndPassword(
            email: _email.text.trim(),
            password: _password.text,
          )
          .timeout(const Duration(seconds: 24));
      _password.clear();
      final user = credential.user;
      if (user == null || _auth!.currentUser?.uid != user.uid) return;
      _loginEpoch++;
      _generation++;
      final next = {..._disabledUids}..remove(user.uid);
      await _store.writeDisabled(next);
      if (!mounted || _auth!.currentUser?.uid != user.uid) return;
      _disabledUids = next;
      setState(() {
        _activated = true;
        _verifiedUid = user.uid;
        _allowed = true;
        _error = null;
      });
      unawaited(_verify());
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
                                'استخدم الحساب الذي منحك إياه مسؤول المنظومة. يلزم الإنترنت لتسجيل الدخول أول مرة فقط؛ بعدها يمكنك العمل دون اتصال.',
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
                                          if (mounted) {
                                            setState(() => _busy = false);
                                          }
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
