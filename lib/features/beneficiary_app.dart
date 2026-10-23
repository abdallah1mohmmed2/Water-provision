import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../api/auth_service.dart';

class BeneficiaryApp extends StatelessWidget {
  final BeneficiaryApi api;
  const BeneficiaryApp(this.api, {super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    home: BeneficiaryLogin(api: api, auth: AuthService(api.api)),
  );
}

class BeneficiaryLogin extends StatefulWidget {
  final BeneficiaryApi api;
  final AuthService auth;
  const BeneficiaryLogin({required this.api, required this.auth, super.key});
  @override
  State<BeneficiaryLogin> createState() => _BeneficiaryLoginState();
}

class _BeneficiaryLoginState extends State<BeneficiaryLogin> {
  final phone = TextEditingController(), code = TextEditingController();
  bool sent = false, loading = false;
  String message = '';
  Future<void> request() async {
    setState(() => loading = true);
    try {
      final x = await widget.auth.requestCode(phone.text.trim());
      setState(() {
        sent = true;
        message = x['dev_code'] == null
            ? 'تم إرسال رمز آمن إن كان مزود الرسائل مفعّلًا.'
            : 'رمز التطوير: ${x['dev_code']}';
      });
    } catch (e) {
      setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> login() async {
    setState(() => loading = true);
    try {
      final x = await widget.auth.loginByPhone(
        phone.text.trim(),
        code.text.trim(),
      );
      widget.api.api.setToken(x['token'] as String);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => BeneficiaryHome(widget.api)),
        );
      }
    } catch (e) {
      setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'ساقية',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'رقم الهاتف'),
                  ),
                  if (sent)
                    TextField(
                      controller: code,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'الرمز السداسي',
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (loading) const LinearProgressIndicator(),
                  if (message.isNotEmpty) Text(message),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: loading ? null : request,
                    child: const Text('إرسال رمز'),
                  ),
                  if (sent)
                    OutlinedButton(
                      onPressed: loading ? null : login,
                      child: const Text('تسجيل الدخول'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class BeneficiaryHome extends StatefulWidget {
  final BeneficiaryApi api;
  const BeneficiaryHome(this.api, {super.key});
  @override
  State<BeneficiaryHome> createState() => _BeneficiaryHomeState();
}

class _BeneficiaryHomeState extends State<BeneficiaryHome> {
  dynamic me, account;
  List<dynamic> requests = [], notifications = [];
  bool loading = true;
  Future<void> load() async {
    try {
      final values = await Future.wait([
        widget.api.me(),
        widget.api.account(),
        widget.api.requests(),
        widget.api.notifications(),
      ]);
      if (mounted) {
        setState(() {
          me = values[0];
          account = values[1];
          requests = values[2] ?? [];
          notifications = values[3] ?? [];
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> request() async {
    try {
      await widget.api.createRequest('طلب حجز سقي');
      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('تطبيق المستفيد')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: ListTile(
                      title: Text(
                        me?['name']?.toString() ?? 'المستفيد',
                      ),
                      subtitle: Text(me?['phone']?.toString() ?? ''),
                    ),
                  ),
                  Card(
                    child: ListTile(
                      title: const Text('الرصيد'),
                      subtitle: Text(account?['label']?.toString() ?? 'متوازن'),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: request,
                    icon: const Icon(Icons.event_available),
                    label: const Text('إرسال طلب حجز'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'طلباتي',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  for (final x in requests)
                    ListTile(
                      title: Text('${x['status']}'),
                      subtitle: Text(
                        '${x['created_at']} • الموعد ${x['scheduled_start'] ?? 'غير محدد'}',
                      ),
                      trailing:
                          (x['status'] == 'new' ||
                              x['status'] == 'under_review')
                          ? TextButton(
                              onPressed: () async {
                                await widget.api.cancelRequest(
                                  x['id'] as int,
                                  'إلغاء من المستفيد',
                                );
                                await load();
                              },
                              child: const Text('إلغاء'),
                            )
                          : null,
                    ),
                  const Divider(),
                  const Text(
                    'الإشعارات',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  for (final x in notifications)
                    ListTile(
                      title: Text('${x['title']}'),
                      subtitle: Text('${x['body']}'),
                      onTap: () async {
                        await widget.api.readNotification(x['id'] as int);
                        await load();
                      },
                    ),
                ],
              ),
            ),
    ),
  );
}
