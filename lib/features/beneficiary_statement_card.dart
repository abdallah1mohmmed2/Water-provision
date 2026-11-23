import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../core/theme.dart';

/// Read-only Android preview. Never changes the rows used to generate PDF.
class BeneficiaryStatementCard extends StatelessWidget {
  final Map<String, Object?> row;
  const BeneficiaryStatementCard({required this.row, super.key});


  num _amount(String key) => row[key] is num
      ? row[key] as num
      : num.tryParse('${row[key] ?? ''}') ?? 0;
  String _money(num value) => NumberFormat('#,##0.##').format(value);
  String _balance(num value) => value > 0
      ? 'عليه ${_money(value)}'
      : value < 0 ? 'له ${_money(value.abs())}' : '0 — متوازن';
  String _date(Object? value) {
    final parsed = DateTime.tryParse('${value ?? ''}');
    return parsed == null ? '—' : DateFormat('yyyy/MM/dd').format(parsed);
  }
  String _time(Object? value) {
    final parsed = DateTime.tryParse('${value ?? ''}');
    return parsed == null ? '—' : DateFormat('HH:mm').format(parsed);
  }

  String _title(String type) => switch (type) {
    's' => 'تسقية',
    'p' => _amount('credit') < 0 ? 'صرف' : 'قبض',
    'disbursement' => 'صرف',
    'receipt' || 'payment' => 'قبض',
    'manual_debt' => 'مديونية سابقة',
    'manual_debt_reversal' => 'إلغاء مديونية',
    'opening_balance' => 'رصيد افتتاحي',
    'carried_balance' => 'رصيد مرحّل',
    _ => '${row['description'] ?? 'حركة حساب'}',
  };

  Widget _field(String label, String value, Color muted, Color ink) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 5),
      Text(value, softWrap: true,
        style: TextStyle(color: ink, fontSize: 15, fontWeight: FontWeight.w700)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    final green = SaqiaTheme.reportPositive;
    final orange = SaqiaTheme.reportNegative;
    final line = scheme.outlineVariant;
    final type = '${row['type'] ?? ''}';
    final irrigation = type == 's';
    final balance = _amount('balance');
    // Same signed debit/credit convention as beneficiaryStatement; no writes.
    final previous = balance - _amount('debit') + _amount('credit');
    final paid = irrigation ? _amount('paid_amount').abs()
        : type == 'p' ? _amount('credit').abs()
        : type == 'payment' || type == 'receipt' || type == 'disbursement'
            ? (_amount('credit') - _amount('debit')).abs() : 0;
    final color = balance > 0 ? orange : green;
    final fields = <(String, String)>[
      (irrigation ? 'تاريخ السقو' : 'التاريخ', _date(row['date'])),
      if (irrigation) ...[
        ('الوقت', 'من ${_time(row['start_datetime'])} إلى ${_time(row['end_datetime'])}'),
        ('المدة بالدقائق', _money(_amount('minutes'))),
        ('دقائق الغيم', _money(_amount('cloud_minutes'))),
        ('الإجمالي', _money(_amount('total_amount'))),
      ] else ('الرصيد السابق', _balance(previous)),
      ('المدفوع', _money(paid)),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _line),
        boxShadow: [BoxShadow(color: ink.withValues(alpha: .04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: green.withValues(alpha: .08), borderRadius: BorderRadius.circular(12)),
              child: Icon(irrigation ? Icons.water_drop_outlined : Icons.receipt_long_outlined, color: green, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(_title(type), style: const TextStyle(color: ink, fontSize: 17, fontWeight: FontWeight.w800))),
          ]),
          const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: _line)),
          LayoutBuilder(builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 260 && MediaQuery.textScalerOf(context).scale(14) <= 19;
            final width = twoColumns ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth;
            return Wrap(spacing: 16, runSpacing: 16, children: [
              for (final field in fields)
                SizedBox(width: width, child: _field(field.$1, field.$2, muted, ink)),
            ]);
          }),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: color.withValues(alpha: .08), borderRadius: BorderRadius.circular(14)),
            child: _field('المتبقي', _balance(balance), muted, ink),
          ),
          if (!irrigation) ...[
            const SizedBox(height: 16),
            _field('الملاحظات', '${row['notes'] ?? ''}'.trim().isEmpty ? '—' : '${row['notes']}', muted, ink),
          ],
        ],
      ),
    );
  }
}
