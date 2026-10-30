import 'package:flutter/material.dart';

import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';
import '../services/local_beneficiary_auth_service.dart';

class BeneficiaryLoginPage extends StatefulWidget {
  const BeneficiaryLoginPage({super.key});

  @override
  State<BeneficiaryLoginPage> createState() => _BeneficiaryLoginPageState();
}

class _BeneficiaryLoginPageState extends State<BeneficiaryLoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _auth = LocalBeneficiaryAuthService();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await _auth.login(_username.text, _password.text);
      if (!mounted) return;
      if (!ok) {
        setState(() => _error = 'اسم المستخدم أو كلمة المرور غير صحيحة، أو أن الحساب غير نشط.');
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BeneficiaryHomePage(auth: _auth),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر تسجيل الدخول حاليًا. حاول مرة أخرى.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('دخول المستفيد')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.person_outline_rounded, size: 52),
                    const SizedBox(height: 12),
                    const Text(
                      'بوابة المستفيد',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      onSubmitted: (_) => _login(),
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _login,
                      icon: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.login_rounded),
                      label: Text(_busy ? 'جارٍ التحقق…' : 'تسجيل الدخول'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'بيانات الدخول ينشئها مدير المحطة. إذا لم تستلمها، تواصل مع الإدارة.',
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
}

class BeneficiaryHomePage extends StatefulWidget {
  const BeneficiaryHomePage({required this.auth, super.key});
  final LocalBeneficiaryAuthService auth;

  @override
  State<BeneficiaryHomePage> createState() => _BeneficiaryHomePageState();
}

class _BeneficiaryHomePageState extends State<BeneficiaryHomePage> {
  final _repo = StationRepository();
  Map<String, Object?>? _beneficiary;
  List<Map<String, Object?>> _statement = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = await widget.auth.currentBeneficiaryId();
      if (id == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'انتهت جلسة الدخول. سجّل الدخول مرة أخرى.';
          });
        }
        return;
      }
      final values = await Future.wait([
        _repo.beneficiaryDetails(id),
        _repo.beneficiaryStatement(id),
      ]);
      if (!mounted) return;
      setState(() {
        _beneficiary = values[0] as Map<String, Object?>;
        _statement = values[1] as List<Map<String, Object?>>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر تحميل بيانات الحساب.';
        });
      }
    }
  }

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('حسابي'),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                          title: Text('${_beneficiary?['name'] ?? 'المستفيد'}'),
                          subtitle: Text('${_beneficiary?['phone'] ?? ''}'),
                        ),
                      ),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('الرصيد الحالي', style: TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 8),
                              Text(
                                AccountingCalculations.balanceLabel((_beneficiary?['balance'] as num?)?.round() ?? 0),
                                style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text('كشف الحساب', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      if (_statement.isEmpty)
                        const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('لا توجد حركات مسجلة.')))
                      else
                        for (final row in _statement.reversed.take(100))
                          Card(
                            child: ListTile(
                              title: Text('${row['description'] ?? 'حركة حساب'}'),
                              subtitle: Text('${row['date'] ?? 'رصيد افتتاحي'}'),
                              trailing: Text(
                                AccountingCalculations.balanceLabel((row['balance'] as num?)?.round() ?? 0),
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
    ),
  );
}
