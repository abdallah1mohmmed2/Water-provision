import 'package:flutter/material.dart';

import '../services/sync_coordinator.dart';

class SyncConnectionPanel extends StatefulWidget {
  final String initialServerUrl;
  const SyncConnectionPanel({super.key, required this.initialServerUrl});

  @override
  State<SyncConnectionPanel> createState() => _SyncConnectionPanelState();
}

class _SyncConnectionPanelState extends State<SyncConnectionPanel> {
  late final TextEditingController _url;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialServerUrl);
    SyncCoordinator.instance.resume().catchError((Object _) {});
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SyncCoordinator.instance.connect(
        baseUrl: _url.text,
        username: _username.text,
        password: _password.text,
      );
      _password.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تسجيل الدخول إلى خادم المحطة وبدء المزامنة.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر الاتصال: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SyncCoordinator.instance.syncNow();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذرت المزامنة: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncRuntimeStatus>(
      valueListenable: SyncCoordinator.instance.status,
      builder: (context, state, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.sync_rounded),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('مزامنة بيانات المحطة',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  Icon(
                    state.error != null
                        ? Icons.error_outline_rounded
                        : state.connected
                            ? Icons.cloud_done_rounded
                            : Icons.cloud_off_rounded,
                    color: state.error != null
                        ? Colors.red
                        : state.connected
                            ? Colors.green
                            : Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('بانتظار الرفع: ${state.pending}  •  وارد غير مطبّق: ${state.inboxPending}',
                style: Theme.of(context).textTheme.bodySmall),
              if (state.lastSyncAt != null)
                Text('آخر محاولة ناجحة: ${state.lastSyncAt!.toLocal()}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (state.error != null) ...[
                const SizedBox(height: 6),
                Text(state.error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'عنوان الخادم الأساسي',
                  hintText: 'https://station.example.com',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _username,
                textDirection: TextDirection.ltr,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'اسم مستخدم الخادم',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: true,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'كلمة مرور الخادم',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox(width: 17, height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login_rounded),
                label: const Text('اتصال وتفعيل المزامنة'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !state.connected ? null : _syncNow,
                icon: const Icon(Icons.sync_rounded),
                label: const Text('مزامنة الآن'),
              ),
              if (state.connected)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await SyncCoordinator.instance.disconnect();
                        },
                  child: const Text('قطع اتصال هذا الجهاز'),
                ),
              const SizedBox(height: 4),
              Text(
                'تُرفع التغييرات المحلية تلقائياً عند توفر الاتصال. تُحفظ التغييرات الواردة في Inbox للمراجعة؛ لا تُطبّق تلقائياً على البيانات المالية قبل استكمال معالج الاستيراد الآمن.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              const Text(
                'استخدم HTTPS في الخادم المنشور. لا تحفظ كلمة المرور؛ يُحفظ رمز جلسة الخادم في التخزين الآمن للجهاز.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
