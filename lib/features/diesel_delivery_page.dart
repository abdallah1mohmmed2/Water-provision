import '../core/diesel_quantity.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/app_clock.dart';
import '../data/repositories/repositories.dart';
import '../domain/maintenance/diesel_delivery_service.dart';

class DieselDeliveryPage extends StatefulWidget {
  final StationRepository repo;
  final int userId;
  final String initialPartyType;
  final int? initialPartyId;
  @Deprecated('Use initialPartyType and initialPartyId')
  final int? initialBeneficiaryId;
  const DieselDeliveryPage(
    this.repo, {
    required this.userId,
    this.initialPartyType = 'beneficiary',
    this.initialPartyId,
    this.initialBeneficiaryId,
    super.key,
  }) : assert(
         initialPartyType == 'beneficiary' ||
             initialPartyType == 'worker' ||
             initialPartyType == 'partner',
       );
  @override
  State<DieselDeliveryPage> createState() => _DieselDeliveryPageState();
}

class _DieselDeliveryPageState extends State<DieselDeliveryPage> {
  late final service = DieselDeliveryService(widget.repo.db);
  final liters = TextEditingController(), notes = TextEditingController();
  late String type;
  String direction = 'from_party';
  String request = const Uuid().v4();
  int? person, station;
  double? balance;
  DateTime date = AppClock.now();
  List<Map<String, Object?>> people = [], movements = [];
  bool busy = false, enabled = false;
  String? error;
  int generation = 0;
  String quantity(double n) => DieselQuantity.format(n.abs());
  String balanceText(double n) => n < 0 && quantity(n) != '0'
      ? 'عليه ${quantity(n)} لتر'
      : n > 0 && quantity(n) != '0'
      ? 'له ${quantity(n)} لتر'
      : 'الرصيد متعادل';
  @override
  void initState() {
    super.initState();
    type = widget.initialPartyType;
    _loadPeople(useInitial: true);
  }

  @override
  void dispose() {
    generation++;
    liters.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> _loadPeople({bool useInitial = false}) async {
    final token = ++generation;
    setState(() {
      enabled = false;
      person = null;
      balance = null;
      people = [];
      movements = [];
    });
    try {
      final id = await widget.repo.accounting.currentStationId();
      await service.authorize(await widget.repo.db.db, id, widget.userId);
      final rows = await widget.repo.db.query(
        'SELECT id,name FROM ${DieselDeliveryService.tables[type]} WHERE station_id=? ORDER BY name',
        args: [id],
      );
      if (!mounted || token != generation) {
        return;
      }
      final initial = useInitial
          ? widget.initialPartyId ?? widget.initialBeneficiaryId
          : null;
      if (initial != null && !rows.any((row) => row['id'] == initial)) {
        throw StateError(
          'الطرف المحدد غير موجود في بيانات المحطة الحالية؛ حدّث بيانات الأطراف',
        );
      }
      setState(() {
        station = id;
        people = rows;
        enabled = true;
        error = null;
        person = null;
        balance = null;
        movements = [];
      });
      if (initial != null) await _select(initial);
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          error = '$e';
          enabled = false;
        });
      }
    }
  }

  Future<void> _select(int? id) async {
    final token = ++generation;
    setState(() {
      person = id;
      balance = null;
      movements = [];
    });
    if (id == null || station == null) {
      return;
    }
    try {
      final value = await service.balance(station!, type, id);
      final rows = await widget.repo.db.query(
        'SELECT dm.*,EXISTS(SELECT 1 FROM diesel_movements r WHERE r.reversal_of=dm.id) cancelled FROM diesel_movements dm WHERE station_id=? AND ${type}_id=? AND party_receipt=1 ORDER BY date DESC,id DESC',
        args: [station, id],
      );
      if (!mounted || token != generation) {
        return;
      }
      setState(() {
        balance = value;
        movements = rows;
        error = null;
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() => error = '$e');
      }
    }
  }

  Future<void> _save() async {
    if (busy || !enabled || person == null || station == null) {
      return;
    }
    final amount = DieselQuantity.parseInput(liters.text);
    if (amount == null || !amount.isFinite || amount <= 0) {
      setState(() => error = 'أدخل كمية لترات موجبة بمنزلتين عشريتين كحد أقصى، مثل 5.75');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (direction == 'from_party') {
        await service.receive(
          station: station!,
          user: widget.userId,
          type: type,
          person: person!,
          liters: amount,
          date: date,
          requestId: request,
          notes: notes.text.trim(),
        );
      } else {
        await service.issueToParty(
          station: station!,
          user: widget.userId,
          type: type,
          person: person!,
          liters: amount,
          date: date,
          requestId: request,
          notes: notes.text.trim(),
        );
      }
      request = const Uuid().v4();
      liters.clear();
      notes.clear();
      await _select(person);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تسجيل التسليم وتسوية رصيد الديزل')),
        );
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

  Future<void> _cancel(int id) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('إلغاء تسليم الديزل'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'سبب الإلغاء'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(c, controller.text.trim());
              }
            },
            child: const Text('تأكيد الإلغاء'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (reason == null || !mounted || busy) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.repo.accounting.cancelDieselMovement(
        id,
        widget.userId,
        reason,
      );
      await _select(person);
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

  @override
  Widget build(BuildContext context) {
    final amount = DieselQuantity.parseInput(liters.text);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إضافة تسليم ديزل')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              direction == 'from_party'
                  ? 'ديزل يسلّمه الطرف للمنظومة: يُخصم من الكمية المستحقة عليه، ويُضاف الفائض إلى رصيده. العملية باللترات فقط دون مبلغ مالي.'
                  : 'ديزل تسلّمه المنظومة للطرف: تُضاف الكمية إلى ما عليه من لترات. العملية باللترات فقط دون مبلغ مالي.',
            ),
            if (error != null)
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (enabled) ...[
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'نوع الطرف'),
                items: const [
                  DropdownMenuItem(value: 'beneficiary', child: Text('مستفيد')),
                  DropdownMenuItem(value: 'worker', child: Text('عامل')),
                  DropdownMenuItem(value: 'partner', child: Text('شريك')),
                ],
                onChanged: busy
                    ? null
                    : (v) {
                        setState(() => type = v!);
                        _loadPeople();
                      },
              ),
              DropdownButtonFormField<String>(
                initialValue: direction,
                decoration: const InputDecoration(labelText: 'اتجاه حركة الديزل'),
                items: const [
                  DropdownMenuItem(
                    value: 'from_party',
                    child: Text('الطرف يسلّم ديزل للمنظومة (له / تسديد ما عليه)'),
                  ),
                  DropdownMenuItem(
                    value: 'to_party',
                    child: Text('المنظومة تسلّم ديزل للطرف (عليه / استلام منه)'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => direction = value!),
              ),
              DropdownButtonFormField<int>(
                key: ValueKey('$type/$person/${people.length}'),
                initialValue: person,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'الاسم'),
                items: [
                  for (final p in people)
                    DropdownMenuItem(
                      value: p['id'] as int,
                      child: Text('${p['name']}'),
                    ),
                ],
                onChanged: busy ? null : _select,
              ),
              if (balance != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('الرصيد الحالي: ${balanceText(balance!)}'),
                ),
              TextField(
                controller: liters,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: direction == 'from_party' ? 'الكمية المستلمة باللترات' : 'الكمية المسلّمة للطرف باللترات',
                  helperText: 'مثال: 5.75 — منزلتان عشريتان كحد أقصى',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (balance != null &&
                  amount != null &&
                  amount.isFinite &&
                  amount > 0)
                Text('بعد الحركة: ${balanceText(balance! + (direction == 'from_party' ? amount : -amount))}'),
              ListTile(
                title: const Text('تاريخ التسليم'),
                subtitle: Text('${date.year}-${date.month}-${date.day}'),
                trailing: const Icon(Icons.calendar_month),
                onTap: busy
                    ? null
                    : () async {
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime(2000),
                          lastDate: AppClock.now(),
                        );
                        if (selected != null && mounted) {
                          setState(
                            () => date = DateTime(
                              selected.year,
                              selected.month,
                              selected.day,
                              date.hour,
                              date.minute,
                            ),
                          );
                        }
                      },
              ),
              TextField(
                controller: notes,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات اختيارية',
                ),
              ),
              FilledButton(
                onPressed: busy || person == null || balance == null
                    ? null
                    : _save,
                child: Text(busy ? 'جارٍ الحفظ…' : 'حفظ تسليم الديزل'),
              ),
              const Divider(),
              const Text('سجل حركات الديزل للطرف المختار'),
              for (final row in movements)
                ListTile(
                  title: Text(
                    '${quantity((row['liters'] as num).toDouble())} لتر • ${row['reversal_of'] != null
                        ? 'حركة عكسية'
                        : row['cancelled'] == 1
                        ? 'ملغى'
                        : row['kind'] == 'consumption'
                        ? 'من المنظومة للطرف'
                        : 'من الطرف للمنظومة'}',
                  ),
                  subtitle: Text('${row['date']} • ${row['notes'] ?? ''}'),
                  trailing:
                      !busy &&
                          row['cancelled'] != 1 &&
                          row['reversal_of'] == null
                      ? TextButton(
                          onPressed: () => _cancel(row['id'] as int),
                          child: const Text('إلغاء'),
                        )
                      : null,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
