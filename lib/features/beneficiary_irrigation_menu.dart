import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../domain/accounting/beneficiary_irrigation_actions.dart';

String _error(Object e) => e is StateError
    ? e.message
    : e is ArgumentError
    ? '${e.message}'
    : '$e';

Future<bool> showBeneficiaryIrrigationMenu(
  BuildContext context,
  PartyIrrigationActions actions, {
  Future<void> Function()? onResend,
}) async {
  final row = await actions.record();
  if (!context.mounted) return false;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text('إجراءات السقاية رقم ${actions.irrigationId}')),
          if (onResend != null)
            ListTile(
              leading: const Icon(Icons.send_outlined),
              title: const Text('إعادة إرسال الرسالة'),
              onTap: () => Navigator.pop(c, 'resend'),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('تعديل السقاية'),
            onTap: () => Navigator.pop(c, 'edit'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(c).colorScheme.error),
            title: const Text('حذف السقاية (إلغاء وعكس الأثر)'),
            onTap: () => Navigator.pop(c, 'cancel'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return false;
  if (choice == 'resend') {
    await actions.record();
    await onResend!();
    return false;
  }
  if (choice == 'edit') {
    final total = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditIrrigationDialog(actions, row),
    );
    if (total == null || !context.mounted) return false;
    final paid = (row['paid_amount'] as num?)?.toInt() ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          paid > total
              ? (actions.partyType == 'beneficiary'
                  ? 'تم التعديل. المدفوع يتجاوز القيمة الجديدة؛ راجع رصيد المستفيد.'
                  : 'تم التعديل. المدفوع يتجاوز القيمة الجديدة؛ راجع رصيد صاحب السقاية.')
              : (actions.partyType == 'beneficiary'
                  ? 'تم تعديل السقاية وتحديث حساب المستفيد'
                  : 'تم تعديل السقاية وتحديث حساب صاحب السقاية'),
        ),
      ),
    );
    return true;
  }
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CancelIrrigationDialog(actions),
      ) ??
      false;
}

class _EditIrrigationDialog extends StatefulWidget {
  final PartyIrrigationActions actions;
  final Map<String, Object?> row;
  const _EditIrrigationDialog(this.actions, this.row);
  @override
  State<_EditIrrigationDialog> createState() => _EditIrrigationDialogState();
}

class _EditIrrigationDialogState extends State<_EditIrrigationDialog> {
  late final DateTime start = DateTime.parse('${widget.row['start_datetime']}'),
      end = DateTime.parse('${widget.row['end_datetime']}');
  late final startDate = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(start),
  );
  late final startTime = TextEditingController(
    text: DateFormat('HH:mm').format(start),
  );
  late final endDate = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(end),
  );
  late final endTime = TextEditingController(
    text: DateFormat('HH:mm').format(end),
  );
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [startDate, startTime, endDate, endTime]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (busy) return;
    DateTime from, to;
    try {
      from = DateFormat('yyyy-MM-dd HH:mm')
          .parseStrict('${startDate.text.trim()} ${startTime.text.trim()}');
      to = DateFormat('yyyy-MM-dd HH:mm')
          .parseStrict('${endDate.text.trim()} ${endTime.text.trim()}');
    } catch (_) {
      setState(
        () => error = 'اكتب التاريخ بصيغة yyyy-MM-dd والوقت بصيغة HH:mm',
      );
      return;
    }
    if (!to.isAfter(from)) {
      setState(() => error = 'وقت النهاية يجب أن يكون بعد وقت البداية');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final total = await widget.actions.edit(from, to);
      if (mounted) Navigator.pop(context, total);
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label,
    bool dateField,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      enabled: !busy,
      textDirection: TextDirection.ltr,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          onPressed: busy
              ? null
              : () async {
                  final parsed =
                      DateTime.tryParse(
                        '${(controller == startDate || controller == startTime) ? startDate.text : endDate.text}T${(controller == startDate || controller == startTime) ? startTime.text : endTime.text}:00',
                      ) ??
                      start;
                  if (dateField) {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: parsed,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null && mounted) {
                      setState(
                        () =>
                            controller.text = DateFormat('yyyy-MM-dd')
                                .format(picked),
                      );
                    }
                  } else {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(parsed),
                    );
                    if (picked != null && mounted) {
                      setState(
                        () => controller.text =
                            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
                      );
                    }
                  }
                },
          icon: Icon(dateField ? Icons.calendar_month : Icons.schedule),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('تعديل السقاية'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('ستُعاد حسابات السقاية وقيودها حسب البيانات الجديدة.'),
            _field(startDate, 'تاريخ البداية', true),
            _field(startTime, 'وقت البداية', false),
            _field(endDate, 'تاريخ النهاية', true),
            _field(endTime, 'وقت النهاية', false),
            if (error != null)
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('رجوع'),
      ),
      FilledButton(
        onPressed: busy ? null : _save,
        child: Text(busy ? 'جارٍ الحفظ…' : 'حفظ تعديل السقاية'),
      ),
    ],
  );
}

class _CancelIrrigationDialog extends StatefulWidget {
  final PartyIrrigationActions actions;
  const _CancelIrrigationDialog(this.actions);
  @override
  State<_CancelIrrigationDialog> createState() =>
      _CancelIrrigationDialogState();
}

class _CancelIrrigationDialogState extends State<_CancelIrrigationDialog> {
  final reason = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy) return;
    if (reason.text.trim().isEmpty) {
      setState(() => error = 'سبب الإلغاء مطلوب');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.actions.cancel(reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('تأكيد إلغاء السقاية'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'سيُعكس أثر السقاية والدفعة المرافقة على الحساب والصندوق والديزل عند وجوده. سيبقى الأصل محفوظًا في السجل.',
        ),
        TextField(
          controller: reason,
          enabled: !busy,
          decoration: const InputDecoration(labelText: 'سبب الإلغاء'),
        ),
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('رجوع'),
      ),
      FilledButton(
        onPressed: busy ? null : _save,
        child: Text(busy ? 'جارٍ الإلغاء…' : 'تأكيد إلغاء السقاية'),
      ),
    ],
  );
}
