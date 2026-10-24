import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../services/cloud_access_service.dart';

class CloudAdminEntryPage extends StatefulWidget {
  const CloudAdminEntryPage({super.key});

  @override
  State<CloudAdminEntryPage> createState() => _CloudAdminEntryPageState();
}

class _CloudAdminEntryPageState extends State<CloudAdminEntryPage> {
  final _service = CloudAccessService();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  User? _user;
  bool _registering = false;
  bool _busy = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _user = _service.currentUser;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
    final credential = await _service.signIn(_email.text, _password.text);
    final user = await _service.refreshCurrentUser() ?? credential.user;
    if (user == null) throw StateError('تعذر تحميل حساب Firebase.');
    if (!user.emailVerified) {
      await _service.sendVerificationEmail(user);
      _message =
          'أرسلنا رابط تحقق إلى بريدك. افتحه ثم اضغط «تحققت من البريد». ';
    }
    if (mounted) setState(() => _user = _service.currentUser ?? user);
  });

  Future<void> _register() => _run(() async {
    if (_displayName.text.trim().isEmpty) {
      throw StateError('أدخل الاسم الظاهر.');
    }
    if (_password.text.length < 12) {
      throw StateError('اختر كلمة مرور لا تقل عن 12 حرفًا.');
    }
    final credential = await _service.register(
      displayName: _displayName.text,
      email: _email.text,
      password: _password.text,
    );
    if (credential.user == null) throw StateError('تعذر إنشاء حساب Firebase.');
    _message =
        'أنشأنا الحساب وأرسلنا رابط تحقق. لن يحصل الحساب على بيانات محطة قبل موافقة المدير الأعلى.';
    if (mounted) setState(() => _user = _service.currentUser);
  });

  Future<void> _refreshVerification() => _run(() async {
    final user = await _service.refreshCurrentUser();
    if (user == null) throw StateError('انتهت الجلسة؛ سجّل الدخول مجددًا.');
    if (!user.emailVerified) {
      _message = 'لم يصل تأكيد البريد بعد. افتح رابط الرسالة ثم أعد المحاولة.';
    } else {
      _message = 'تم التحقق من البريد. يمكنك الآن إرسال طلب الانضمام.';
    }
    if (mounted) setState(() => _user = user);
  });

  Future<void> _sendVerificationAgain() => _run(() async {
    final user = _service.currentUser;
    if (user == null) throw StateError('سجّل الدخول أولًا.');
    await _service.sendVerificationEmail(user);
    _message = 'أرسلنا رابط تحقق جديدًا إلى بريدك.';
    if (mounted) setState(() {});
  });

  Future<void> _resetPassword() => _run(() async {
    final email = _email.text.trim();
    if (email.isEmpty) throw StateError('أدخل البريد أولًا.');
    await _service.sendPasswordReset(email);
    _message = 'إذا كان البريد مسجلًا، فستصل رسالة إعادة تعيين كلمة المرور.';
    if (mounted) setState(() {});
  });

  Future<void> _signOut() => _run(() async {
    await _service.signOut();
    if (mounted) {
      setState(() {
        _user = null;
        _password.clear();
      });
    }
  });

  @override
  Widget build(BuildContext context) {
    if (Firebase.apps.isEmpty) {
      return _messagePage(
        context,
        icon: Icons.cloud_off_outlined,
        title: 'بوابة Firebase غير مهيأة على هذه المنصة',
        body:
            'التطبيق الحالي يهيئ Firebase على Android فقط. بيانات SQLite المحلية لم تتغير.',
      );
    }

    final user = _user ?? _service.currentUser;
    if (user != null && user.emailVerified && _service.isRootAdmin(user)) {
      return CloudAdminDashboard(service: _service, admin: user);
    }
    if (user != null && !user.emailVerified) {
      return _verificationScreen(user);
    }
    if (user != null) {
      return _applicantScreen(user);
    }
    return _authScreen();
  }

  Widget _authScreen() => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('دخول إدارة ساقية السحابية')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.admin_panel_settings_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      _registering ? 'إنشاء حساب وطلب صلاحية' : 'تسجيل الدخول',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'تسجيل البريد لا يمنح صلاحية تلقائيًا. المدير الأعلى هو من يربط الحساب بمحطة ودور.',
                      textAlign: TextAlign.center,
                    ),
                    if (_registering) ...[
                      const SizedBox(height: 18),
                      TextField(
                        controller: _displayName,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'الاسم الظاهر',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'البريد الإلكتروني',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: _registering
                          ? const [AutofillHints.newPassword]
                          : const [AutofillHints.password],
                      onSubmitted: (_) =>
                          _registering ? _register() : _signIn(),
                      decoration: InputDecoration(
                        labelText: _registering
                            ? 'كلمة مرور جديدة (12 حرفًا على الأقل)'
                            : 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _message!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : (_registering ? _register : _signIn),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _registering
                                  ? Icons.person_add_alt_1
                                  : Icons.login,
                            ),
                      label: Text(
                        _busy
                            ? 'جارٍ التنفيذ…'
                            : (_registering
                                  ? 'إنشاء الحساب وإرسال التحقق'
                                  : 'دخول'),
                      ),
                    ),
                    if (!_registering)
                      TextButton(
                        onPressed: _busy ? null : _resetPassword,
                        child: const Text(
                          'نسيت كلمة المرور؟ أرسل رابط تغييرها',
                        ),
                      ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _registering = !_registering;
                              _error = null;
                              _message = null;
                            }),
                      child: Text(
                        _registering
                            ? 'لدي حساب بالفعل'
                            : 'إنشاء حساب جديد وطلب الانضمام',
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'لا يُستخدم SMS ولا رموز تحقق محلية. يعتمد الدخول على Firebase Authentication والبريد الموثّق.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _verificationScreen(User user) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('تحقق من البريد'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.mark_email_unread_outlined, size: 52),
                    const SizedBox(height: 14),
                    const Text(
                      'يلزم تأكيد ملكية البريد قبل إتاحة أي بيانات.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(user.email ?? ''),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 12),
                      Text(_message!, textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _refreshVerification,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('تحققت من البريد، حدّث الحالة'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _sendVerificationAgain,
                      child: const Text('إعادة إرسال رابط التحقق'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _applicantScreen(User user) => _CloudApplicantScreen(
    service: _service,
    user: user,
    onSignOut: _signOut,
    onRefresh: () async {
      final refreshed = await _service.refreshCurrentUser();
      if (mounted && refreshed != null) setState(() => _user = refreshed);
    },
  );

  Widget _messagePage(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
  }) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('إدارة ساقية')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CloudApplicantScreen extends StatefulWidget {
  const _CloudApplicantScreen({
    required this.service,
    required this.user,
    required this.onSignOut,
    required this.onRefresh,
  });

  final CloudAccessService service;
  final User user;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onRefresh;

  @override
  State<_CloudApplicantScreen> createState() => _CloudApplicantScreenState();
}

class _CloudApplicantScreenState extends State<_CloudApplicantScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await widget.service.refreshCurrentUser();
      if (user == null || !user.emailVerified) {
        throw StateError('تحقق من بريدك الإلكتروني أولًا.');
      }
      await widget.service.submitAccessRequest(user);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('طلب صلاحية النظام'),
        actions: [
          IconButton(
            onPressed: _busy ? null : widget.onSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: FutureBuilder<List<Object>>(
        future: Future.wait<Object>([
          widget.service.myAccessRequest(widget.user.uid),
          widget.service.myMemberships(widget.user.uid),
        ]),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _statusMessage(
              context,
              'تعذر تحميل حالة الطلب. تحقق من الاتصال ثم أعد المحاولة.',
            );
          }
          final request = snapshot.data![0] as dynamic;
          final memberships = snapshot.data![1] as dynamic;
          final requestData = request.data() as Map<String, dynamic>?;
          final activeMemberships = memberships.docs as List;
          if (activeMemberships.isNotEmpty) {
            return _membershipList(context, activeMemberships);
          }
          final status = requestData?['status'] as String?;
          if (status == 'pending') {
            return _statusMessage(
              context,
              'طلبك قيد مراجعة المدير الأعلى. لن تُفتح بيانات المحطة قبل تعيين الدور والمحطة.',
            );
          }
          if (status == 'rejected') {
            return _statusMessage(
              context,
              'لم تتم الموافقة على الطلب. تواصل مع المدير الأعلى لمراجعته.',
            );
          }
          if (status == 'approved') {
            return _statusMessage(
              context,
              'تمت الموافقة؛ حدّث الصفحة بعد لحظات لقراءة العضوية.',
            );
          }
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person_search_outlined, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          widget.user.email ?? '',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'أرسل طلبًا للمدير الأعلى ليحدد المحطة والدور. لا تختار صلاحيتك بنفسك.',
                          textAlign: TextAlign.center,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: _busy ? null : _submit,
                          icon: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_outlined),
                          label: const Text('إرسال طلب الانضمام'),
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : widget.onRefresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('تحديث الحالة'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _statusMessage(BuildContext context, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hourglass_top_rounded, size: 44),
          const SizedBox(height: 14),
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('تحديث الحالة'),
          ),
        ],
      ),
    ),
  );

  Widget _membershipList(BuildContext context, List memberships) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'العضويات النشطة',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      for (final item in memberships)
        Card(
          child: ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text('${item.data()['role']}'),
            subtitle: Text('معرّف المحطة: ${item.id}'),
          ),
        ),
      const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'تسجيل دخول Firebase يعمل. عمليات النظام وبيانات SQLite لم تُنقل إلى السحابة ضمن هذه المرحلة.',
          textAlign: TextAlign.center,
        ),
      ),
    ],
  );
}

class CloudAdminDashboard extends StatefulWidget {
  const CloudAdminDashboard({
    super.key,
    required this.service,
    required this.admin,
  });

  final CloudAccessService service;
  final User admin;

  @override
  State<CloudAdminDashboard> createState() => _CloudAdminDashboardState();
}

class _CloudAdminDashboardState extends State<CloudAdminDashboard> {
  bool _busy = false;
  String? _error;
  String? _notice;

  Future<void> _addStation() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إضافة محطة'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(labelText: 'اسم المحطة'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('إضافة'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await _perform(() async {
      final stationId = await widget.service.createStation(
        name,
        widget.admin.uid,
      );
      _notice = 'أُضيفت المحطة. معرّفها: $stationId';
    });
  }

  Future<void> _approve(
    CloudAccessRequest request,
    List<CloudStation> stations,
  ) async {
    if (stations.where((station) => station.active).isEmpty) {
      setState(() => _error = 'أضف محطة نشطة أولًا قبل تعيين مستخدم.');
      return;
    }
    final choice = await showDialog<_ApprovalChoice>(
      context: context,
      builder: (context) => _ApprovalDialog(
        stations: stations.where((station) => station.active).toList(),
      ),
    );
    if (choice == null) return;
    await _perform(() async {
      await widget.service.approveRequest(
        request: request,
        stationId: choice.stationId,
        role: choice.role,
        subjectId: choice.subjectId,
        reviewerUid: widget.admin.uid,
      );
      _notice = 'تمت إضافة المستخدم إلى المحطة بالدور المحدد.';
    });
  }

  Future<void> _reject(CloudAccessRequest request) => _perform(() async {
    await widget.service.rejectRequest(
      uid: request.uid,
      reviewerUid: widget.admin.uid,
    );
    _notice = 'تم رفض طلب الوصول مع حفظ حالة القرار.';
  });

  Future<void> _signOutFromDashboard() async {
    await widget.service.signOut();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      _error = _friendlyError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('لوحة المدير الأعلى'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.water_drop_outlined), text: 'المحطات'),
              Tab(icon: Icon(Icons.group_outlined), text: 'طلبات المستخدمين'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: _busy ? null : _signOutFromDashboard,
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('إغلاق'),
                  ),
                ],
              ),
            if (_notice != null)
              MaterialBanner(
                content: Text(_notice!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _notice = null),
                    child: const Text('حسنًا'),
                  ),
                ],
              ),
            Expanded(
              child: TabBarView(children: [_stationsTab(), _requestsTab()]),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _busy ? null : _addStation,
          icon: const Icon(Icons.add_business_outlined),
          label: const Text('إضافة محطة'),
        ),
      ),
    ),
  );

  Widget _stationsTab() => StreamBuilder(
    stream: widget.service.watchStations(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _errorBody(
          'تعذر قراءة المحطات. تحقق من اتصال المدير وقواعد Firestore.',
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final stations = snapshot.data!.docs
          .map(CloudStation.fromSnapshot)
          .toList();
      if (stations.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'لا توجد محطات سحابية حتى الآن. استخدم «إضافة محطة» لإنشاء الأولى.',
            ),
          ),
        );
      }
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        itemCount: stations.length,
        itemBuilder: (context, index) {
          final station = stations[index];
          return Card(
            child: ListTile(
              leading: Icon(
                station.active ? Icons.water_drop : Icons.water_drop_outlined,
              ),
              title: Text(station.name),
              subtitle: SelectableText('معرّف المحطة: ${station.id}'),
              trailing: Icon(
                station.active
                    ? Icons.check_circle_outline
                    : Icons.pause_circle_outline,
              ),
            ),
          );
        },
      );
    },
  );

  Widget _requestsTab() => StreamBuilder(
    stream: widget.service.watchPendingRequests(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _errorBody(
          'تعذر تحميل الطلبات. تحقق من اتصال المدير وقواعد Firestore.',
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final requests = snapshot.data!.docs
          .map(CloudAccessRequest.fromSnapshot)
          .toList();
      final stationsSnapshot = widget.service.watchStations();
      return StreamBuilder(
        stream: stationsSnapshot,
        builder: (context, stationSnapshot) {
          final stations =
              stationSnapshot.data?.docs
                  .map(CloudStation.fromSnapshot)
                  .toList() ??
              const <CloudStation>[];
          if (requests.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'لا توجد طلبات معلّقة. يرسل المستخدم طلبًا بعد إنشاء حسابه والتحقق من بريده.',
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(
                      request.displayName.isEmpty
                          ? request.email
                          : request.displayName,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(request.email),
                        SelectableText('UID: ${request.uid}'),
                        if (request.createdAt != null)
                          Text('تاريخ الطلب: ${request.createdAt}'),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      tooltip: 'مراجعة الطلب',
                      onSelected: (action) {
                        if (action == 'approve') _approve(request, stations);
                        if (action == 'reject') _reject(request);
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'approve',
                          child: Text('اختيار المحطة والدور'),
                        ),
                        PopupMenuItem(
                          value: 'reject',
                          child: Text('رفض الطلب'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    },
  );

  Widget _errorBody(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

class _ApprovalChoice {
  const _ApprovalChoice({
    required this.stationId,
    required this.role,
    this.subjectId,
  });
  final String stationId;
  final SaqiaCloudRole role;
  final String? subjectId;
}

class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({required this.stations});
  final List<CloudStation> stations;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  SaqiaCloudRole _role = SaqiaCloudRole.manager;
  late String _stationId = widget.stations.first.id;
  final _subjectId = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _subjectId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: AlertDialog(
      title: const Text('تعيين محطة ودور'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _stationId,
              decoration: const InputDecoration(labelText: 'المحطة'),
              items: widget.stations
                  .map(
                    (station) => DropdownMenuItem(
                      value: station.id,
                      child: Text(station.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _stationId = value ?? _stationId),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SaqiaCloudRole>(
              initialValue: _role,
              decoration: const InputDecoration(labelText: 'الدور'),
              items: SaqiaCloudRole.values
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(role.arabicLabel),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _role = value ?? _role),
            ),
            if (_role.needsSubject) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _subjectId,
                decoration: const InputDecoration(
                  labelText: 'معرّف سجل المستفيد/الشريك/العامل',
                  helperText:
                      'يجب أن يطابق معرّف المستند الموجود في Firestore.',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            if (_role.needsSubject && _subjectId.text.trim().isEmpty) {
              setState(() => _error = 'أدخل معرّف السجل قبل المتابعة.');
              return;
            }
            Navigator.pop(
              context,
              _ApprovalChoice(
                stationId: _stationId,
                role: _role,
                subjectId: _role.needsSubject ? _subjectId.text.trim() : null,
              ),
            );
          },
          child: const Text('منح العضوية'),
        ),
      ],
    ),
  );
}

String _friendlyError(Object error) {
  if (error is StateError) return error.message;
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'invalid-credential' ||
      'user-not-found' ||
      'wrong-password' => 'بيانات الدخول غير صحيحة.',
      'email-already-in-use' => 'هذا البريد مسجل بالفعل؛ جرّب تسجيل الدخول.',
      'weak-password' => 'كلمة المرور ضعيفة. استخدم 12 حرفًا على الأقل.',
      'invalid-email' => 'صيغة البريد الإلكتروني غير صحيحة.',
      'too-many-requests' =>
        'توقفت المحاولات مؤقتًا لأسباب أمنية. انتظر ثم أعد المحاولة.',
      'network-request-failed' => 'تعذر الاتصال بالإنترنت.',
      _ => 'تعذر إتمام المصادقة. راجع البريد وكلمة المرور وإعداد Firebase.',
    };
  }
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' =>
        'رفضت قواعد Firestore العملية. تحقق من البريد الموثق والمحطة والدور.',
      'unavailable' =>
        'خدمة Firestore غير متاحة مؤقتًا؛ أعد المحاولة عند عودة الاتصال.',
      _ => 'تعذر تنفيذ العملية السحابية (${error.code}).',
    };
  }
  return 'تعذر تنفيذ العملية. تحقق من الاتصال ثم أعد المحاولة.';
}
