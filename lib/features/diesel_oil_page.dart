import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/app_prefs.dart';
import '../data/repositories/repositories.dart';
import '../domain/maintenance/diesel_oil_service.dart';

final _announcedOilStates = <int, String>{};

void _announceOilStatus(int station, OilStatus value) {
  final token = '${value.cycle}/${value.state}/${value.usedMinutes}';
  if (_announcedOilStates[station] == token) {
    return;
  }
  _announcedOilStates[station] = token;
  if (value.state == 'warning' || value.state == 'due') {
    AppAlerts.emit('تنبيه تغيير الزيت', value.message);
  }
}

/// Keep reminders active while the user records irrigation away from Dashboard.
StreamSubscription<void> watchDieselOilAlerts(StationRepository repo) =>
    repo.db.irrigationChanges.listen((_) async {
      try {
        if ((await repo.settings())['system_type'] != 'diesel') {
          return;
        }
        final station = await repo.accounting.currentStationId();
        _announceOilStatus(station, await DieselOilService(repo.db).load(station));
      } catch (_) {
        // A failed read must not emit a misleading maintenance warning.
      }
    });

class DieselOilCard extends StatefulWidget {
  final StationRepository repo;
  final int userId;
  final String role;
  const DieselOilCard(
    this.repo, {
    required this.userId,
    required this.role,
    super.key,
  });
  @override
  State<DieselOilCard> createState() => _DieselOilCardState();
}

class _DieselOilCardState extends State<DieselOilCard>
    with WidgetsBindingObserver {
  OilStatus? status;
  String? error;
  Timer? timer;
  StreamSubscription<void>? irrigationSubscription;
  bool reading = false;
  bool reloadRequested = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    irrigationSubscription = widget.repo.db.irrigationChanges.listen((_) => _load());
    timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void didUpdateWidget(covariant DieselOilCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    irrigationSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (reading) {
      reloadRequested = true;
      return;
    }
    reading = true;
    try {
      final station = await widget.repo.accounting.currentStationId();
      final value = await DieselOilService(widget.repo.db).load(station);
      if (!mounted) {
        return;
      }
      setState(() {
        status = value;
        error = null;
      });
      _announceOilStatus(station, value);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'تعذر قراءة متابعة الزيت؛ اضغط لإعادة المحاولة');
      }
    } finally {
      reading = false;
      if (reloadRequested && mounted) {
        reloadRequested = false;
        unawaited(_load());
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(
        Icons.oil_barrel_outlined,
        color: status?.state == 'due' ? Colors.red : Colors.orange.shade700,
      ),
      title: const Text('زيت منظومة الديزل'),
      subtitle: Text(error ?? status?.message ?? 'جارٍ حساب ساعات السقاية…'),
      trailing: const Icon(Icons.chevron_left),
      onTap: () async {
        if (error != null) {
          await _load();
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DieselOilPage(
              widget.repo,
              userId: widget.userId,
              role: widget.role,
            ),
          ),
        );
        await _load();
      },
    ),
  );
}

class DieselOilPage extends StatefulWidget {
  final StationRepository repo;
  final int userId;
  final String role;
  const DieselOilPage(
    this.repo, {
    required this.userId,
    required this.role,
    super.key,
  });
  @override
  State<DieselOilPage> createState() => _DieselOilPageState();
}

class _DieselOilPageState extends State<DieselOilPage> {
  late final service = DieselOilService(widget.repo.db);
  final interval = TextEditingController();
  final warning = TextEditingController();
  final initial = TextEditingController(text: '0');
  final cost = TextEditingController();
  OilStatus? status;
  int? station, method, cashbox;
  List<Map<String, Object?>> methods = [], boxes = [];
  bool busy = false;
  bool confirming = false;
  String? error;
  String request = const Uuid().v4();
  bool get manager => widget.role == 'manager';
  bool get canPost => manager || widget.role == 'accountant';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [interval, warning, initial, cost]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final id = await widget.repo.accounting.currentStationId();
      final value = await service.load(id);
      final m = await widget.repo.paymentMethods();
      final b = await widget.repo.cashboxes();
      if (!mounted) {
        return;
      }
      setState(() {
        station = id;
        status = value;
        methods = m.where((e) => e['station_id'] == id).toList();
        boxes = b.where((e) => e['station_id'] == id).toList();
        if (!methods.any((e) => e['id'] == method)) {
          method = null;
          cashbox = null;
        }
        if (!boxes.any((e) => e['id'] == cashbox)) {
          cashbox = null;
        }
        interval.text = value.configured ? OilStatus.hours(value.interval) : '';
        warning.text = value.configured ? OilStatus.hours(value.warning) : '';
        initial.text = value.configured
            ? OilStatus.hours(value.config['initial'] as int)
            : '0';
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
  }

  int _minutes(String text) {
    final n = double.tryParse(text.trim());
    if (n == null || !n.isFinite || n < 0 || n > 1000000) {
      throw ArgumentError('أدخل عدد ساعات صحيحًا أو عشريًا بين صفر ومليون');
    }
    return (n * 60).round();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || station == null) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('تم الحفظ')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _change() async {
    if (busy || confirming) return;
    final amount = int.tryParse(cost.text.trim());
    if (amount == null || amount <= 0 || method == null || cashbox == null) {
      setState(() => error = 'أدخل تكلفة موجبة واختر طريقة الدفع والصندوق');
      return;
    }
    final cycle = status!.cycle;
    final requestId = request;
    final sourceMethod = method!;
    final sourceBox = cashbox!;
    final sourceStation = station!;
    setState(() => confirming = true);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تأكيد تغيير الزيت'),
        content: Text(
          'تسجيل مصروف زيت بمبلغ $amount، وبدء دورة ساعات جديدة الآن؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('تم تغيير الزيت'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirming = false);
    if (yes != true) return;
    await _run(() async {
      await service.change(
        station: sourceStation,
        user: widget.userId,
        amount: amount,
        paymentMethod: sourceMethod,
        cashbox: sourceBox,
        expectedCycle: cycle,
        requestId: requestId,
      );
      request = const Uuid().v4();
      cost.clear();
    });
  }

  Future<void> _cancel(int expense) async {
    final reason = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('إلغاء تغيير الزيت'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'سيُعكس المصروف وتُستعاد دورة الزيت السابقة. أدخل سبب الإلغاء:',
            ),
            TextField(controller: reason),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () {
              if (reason.text.trim().isNotEmpty) {
                Navigator.pop(c, reason.text.trim());
              }
            },
            child: const Text('تأكيد الإلغاء'),
          ),
        ],
      ),
    );
    // Dialog routes finish their exit transition before disposing field controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    reason.dispose();
    if (text != null && mounted) {
      await _run(
        () => service.cancel(
          station: station!,
          user: widget.userId,
          expense: expense,
          reason: text,
        ),
      );
    }
  }

  Widget _hours(
    TextEditingController controller,
    String label, {
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      enabled: enabled && !busy,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, suffixText: 'ساعة'),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final value = status;
    final availableBoxes = method == null
        ? boxes
        : boxes.where((b) {
            final selected = methods.firstWhere((e) => e['id'] == method);
            return selected['cashbox_id'] == null ||
                selected['cashbox_id'] == b['id'];
          }).toList();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('متابعة تغيير الزيت')),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'خاص بمنظومة الديزل. تُحتسب مدة السقاية الفعلية المسجلة فقط، دون تقريب الفاتورة. التنبيه يظهر داخل التطبيق.',
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (value == null)
                const LinearProgressIndicator()
              else ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          value.message,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (value.configured)
                          Text(
                            'المستهلك منذ آخر تغيير: ${OilStatus.hours(value.usedMinutes)} ساعة',
                          ),
                      ],
                    ),
                  ),
                ),
                if (manager) ...[
                  const Text(
                    'إعداد موعد التغيير',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  _hours(interval, 'تغيير الزيت كل'),
                  _hours(warning, 'التنبيه قبل الموعد بـ'),
                  if (!value.configured)
                    _hours(
                      initial,
                      'ساعات مستهلكة منذ آخر تغيير عند بدء المتابعة',
                    ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => _run(
                            () => service.configure(
                              station: station!,
                              user: widget.userId,
                              interval: _minutes(interval.text),
                              warning: _minutes(warning.text),
                              initial: _minutes(initial.text),
                            ),
                          ),
                    child: const Text('حفظ إعدادات الزيت'),
                  ),
                ],
                if (canPost && value.configured) ...[
                  const Divider(),
                  const Text(
                    'تسجيل تغيير الزيت',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextField(
                    controller: cost,
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'تكلفة تغيير الزيت',
                    ),
                  ),
                  DropdownButtonFormField<int>(
                    key: ValueKey('method-$method'),
                    initialValue: method,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                    items: [
                      for (final m in methods)
                        DropdownMenuItem(
                          value: m['id'] as int,
                          child: Text('${m['name']}'),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() {
                            method = v;
                            cashbox =
                                methods.firstWhere(
                                      (e) => e['id'] == v,
                                    )['cashbox_id']
                                    as int?;
                            if (!boxes.any((e) => e['id'] == cashbox)) {
                              cashbox = null;
                            }
                          }),
                  ),
                  DropdownButtonFormField<int>(
                    key: ValueKey('$method/$cashbox'),
                    initialValue: cashbox,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'الصندوق'),
                    items: [
                      for (final b in availableBoxes)
                        DropdownMenuItem(
                          value: b['id'] as int,
                          child: Text('${b['name']}'),
                        ),
                    ],
                    onChanged: busy ? null : (v) => setState(() => cashbox = v),
                  ),
                  const Text(
                    'تُسجّل التكلفة مرة واحدة كمصروف زيت، وتُخصم من الصندوق ومن صافي الربح.',
                  ),
                  FilledButton.icon(
                    onPressed: busy || confirming ? null : _change,
                    icon: const Icon(Icons.oil_barrel_outlined),
                    label: const Text('تم تغيير الزيت'),
                  ),
                ],
                const Divider(),
                const Text(
                  'سجل تغييرات الزيت',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (value.history.isEmpty)
                  const Text('لم يُسجّل تغيير زيت بعد.'),
                for (final row in value.history)
                  ListTile(
                    title: Text(
                      '${row['amount']} • ${row['status'] == 'posted' ? 'مسجل' : 'ملغى'}',
                    ),
                    subtitle: Text('${row['at']}'),
                    trailing: canPost && row['status'] == 'posted'
                        ? TextButton(
                            onPressed: busy
                                ? null
                                : () => _cancel(row['expense_id'] as int),
                            child: const Text('إلغاء بعكس المصروف'),
                          )
                        : null,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
