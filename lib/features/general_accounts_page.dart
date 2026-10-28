import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../core/app_clock.dart';
import '../data/repositories/repositories.dart';
import '../services/manual_message_service.dart';
import '../services/official_report_template.dart';

/// Signed balance: positive means "لنا عليه"; negative means "له علينا".
/// A receipt reduces the amount owed to us; a payment increases it.
int calculateGeneralAccountBalance(
  int openingBalance,
  Iterable<Map<String, Object?>> transactions,
) {
  var balance = openingBalance;
  for (final row in transactions) {
    final amount = (row['amount'] as num?)?.toInt() ?? 0;
    if (row['type'] == 'receipt') {
      balance -= amount;
    } else if (row['type'] == 'payment') {
      balance += amount;
    }
  }
  return balance;
}

class GeneralAccountsPage extends StatefulWidget {
  final StationRepository repository;
  final int? userId;
  const GeneralAccountsPage(this.repository, {super.key, this.userId});

  @override
  State<GeneralAccountsPage> createState() => _GeneralAccountsPageState();
}

class _GeneralAccountsPageState extends State<GeneralAccountsPage> {
  final _search = TextEditingController();
  List<Map<String, Object?>> _accounts = [];
  Map<int, List<Map<String, Object?>>> _transactions = {};
  bool _loading = true;
  String? _error;
  int? _expandedId;

  Future<Database> get _db async => widget.repository.db.db;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final db = await _db;
      final stationId = await widget.repository.accounting.currentStationId();
      final accounts = await db.query(
        'general_accounts',
        where: 'station_id=? AND active=1 AND (name LIKE ? OR COALESCE(phone, \'\') LIKE ?)',
        whereArgs: [stationId, '%${_search.text.trim()}%', '%${_search.text.trim()}%'],
        orderBy: 'name COLLATE NOCASE',
      );
      final transactions = <int, List<Map<String, Object?>>>{};
      for (final account in accounts) {
        final id = (account['id'] as num).toInt();
        transactions[id] = await db.query(
          'general_account_transactions',
          where: 'account_id=? AND station_id=?',
          whereArgs: [id, stationId],
          orderBy: 'date DESC, id DESC',
        );
      }
      if (mounted) setState(() { _accounts = accounts; _transactions = transactions; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'تعذر تحميل الحسابات العامة: $e'; _loading = false; });
    }
  }

  int _balance(Map<String, Object?> account) {
    final opening = (account['opening_balance'] as num?)?.toInt() ?? 0;
    final id = (account['id'] as num).toInt();
    return calculateGeneralAccountBalance(opening, _transactions[id] ?? const []);
  }

  String _money(int value) => value.abs().toString();

  Future<void> _createAccount() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final address = TextEditingController();
    final notes = TextEditingController();
    final opening = TextEditingController(text: '0');
    String direction = 'receivable';
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('إضافة حساب عام'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم الحساب *'), validator: (v) => v == null || v.trim().isEmpty ? 'اسم الحساب مطلوب' : null),
                TextFormField(controller: phone, decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)'), keyboardType: TextInputType.phone),
                TextFormField(controller: address, decoration: const InputDecoration(labelText: 'العنوان (اختياري)')),
                TextFormField(controller: opening, decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'), keyboardType: TextInputType.number, validator: (v) => int.tryParse((v ?? '').trim()) == null || int.parse(v!.trim()) < 0 ? 'أدخل مبلغًا صحيحًا موجبًا أو صفرًا' : null),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: direction,
                  decoration: const InputDecoration(labelText: 'اتجاه الرصيد الافتتاحي'),
                  items: const [
                    DropdownMenuItem(value: 'receivable', child: Text('لنا عليه')),
                    DropdownMenuItem(value: 'payable', child: Text('له علينا')),
                  ],
                  onChanged: (v) => setDialogState(() => direction = v ?? 'receivable'),
                ),
                TextFormField(controller: notes, decoration: const InputDecoration(labelText: 'ملاحظات'), maxLines: 2),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () { if (formKey.currentState!.validate()) Navigator.pop(dialogContext, true); }, child: const Text('حفظ')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        final db = await _db;
        final stationId = await _stationId();
        final value = int.parse(opening.text.trim());
        await db.transaction((tx) async {
          await tx.insert('general_accounts', {
            'station_id': stationId,
            'name': name.text.trim(),
            'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
            'address': address.text.trim().isEmpty ? null : address.text.trim(),
            'opening_balance': direction == 'receivable' ? value : -value,
            'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
            'active': 1,
            'created_at': AppClock.now().toIso8601String(),
            'updated_at': AppClock.now().toIso8601String(),
          });
        });
        await _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل حفظ الحساب: $e')));
      }
    }
    name.dispose(); phone.dispose(); address.dispose(); notes.dispose(); opening.dispose();
  }

  Future<int> _stationId() => widget.repository.accounting.currentStationId();

  Future<void> _addTransaction(Map<String, Object?> account, String type) async {
    final amount = TextEditingController();
    final notes = TextEditingController();
    final reference = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(type == 'receipt' ? 'قبض من الحساب' : 'صرف للحساب'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('الحساب: ${account['name']}'),
              TextFormField(controller: amount, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ *'), validator: (v) => int.tryParse((v ?? '').trim()) == null || int.parse(v!.trim()) <= 0 ? 'أدخل مبلغًا أكبر من صفر' : null),
              TextFormField(controller: reference, decoration: const InputDecoration(labelText: 'رقم مرجعي (اختياري)')),
              TextFormField(controller: notes, decoration: const InputDecoration(labelText: 'ملاحظات'), maxLines: 3),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () { if (formKey.currentState!.validate()) Navigator.pop(dialogContext, true); }, child: const Text('حفظ الحركة')),
        ],
      ),
    );
    if (ok == true) {
      try {
        final db = await _db;
        final stationId = await _stationId();
        final value = int.parse(amount.text.trim());
        await db.transaction((tx) async {
          final accountId = (account['id'] as num).toInt();
          final exists = await tx.query('general_accounts', columns: ['id'], where: 'id=? AND station_id=? AND active=1', whereArgs: [accountId, stationId], limit: 1);
          if (exists.isEmpty) throw StateError('الحساب غير موجود أو غير نشط');
          await tx.insert('general_account_transactions', {
            'station_id': stationId,
            'account_id': accountId,
            'date': AppClock.now().toIso8601String(),
            'type': type,
            'amount': value,
            'reference_number': reference.text.trim().isEmpty ? null : reference.text.trim(),
            'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
            'created_by': widget.userId,
            'created_at': AppClock.now().toIso8601String(),
          });
        });
        if (mounted) setState(() => _expandedId = (account['id'] as num).toInt());
        await _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل حفظ الحركة: $e')));
      }
    }
    amount.dispose(); notes.dispose(); reference.dispose();
  }


  int _sumType(Iterable<Map<String, Object?>> rows, String type) {
    return rows
        .where((row) => row['type'] == type)
        .fold<int>(0, (sum, row) => sum + ((row['amount'] as num?)?.toInt() ?? 0));
  }

  String _balanceDescription(int balance) {
    if (balance > 0) return 'لنا عليه ${_money(balance)} ريال';
    if (balance < 0) return 'له علينا ${_money(balance)} ريال';
    return 'الرصيد متوازن: 0 ريال';
  }

  Future<void> _editAccount(Map<String, Object?> account) async {
    final name = TextEditingController(text: '${account['name'] ?? ''}');
    final phone = TextEditingController(text: '${account['phone'] ?? ''}');
    final address = TextEditingController(text: '${account['address'] ?? ''}');
    final notes = TextEditingController(text: '${account['notes'] ?? ''}');
    final openingValue = (account['opening_balance'] as num?)?.toInt() ?? 0;
    final opening = TextEditingController(text: _money(openingValue));
    String direction = openingValue < 0 ? 'payable' : 'receivable';
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('تعديل حساب ${account['name']}'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'اسم الحساب *'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'اسم الحساب مطلوب' : null,
                ),
                TextFormField(controller: phone, decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)'), keyboardType: TextInputType.phone),
                TextFormField(controller: address, decoration: const InputDecoration(labelText: 'العنوان (اختياري)')),
                TextFormField(
                  controller: opening,
                  decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
                  keyboardType: TextInputType.number,
                  validator: (v) {
                    final parsed = int.tryParse((v ?? '').trim());
                    return parsed == null || parsed < 0 ? 'أدخل مبلغًا صحيحًا موجبًا أو صفرًا' : null;
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: direction,
                  decoration: const InputDecoration(labelText: 'اتجاه الرصيد الافتتاحي'),
                  items: const [
                    DropdownMenuItem(value: 'receivable', child: Text('لنا عليه')),
                    DropdownMenuItem(value: 'payable', child: Text('له علينا')),
                  ],
                  onChanged: (v) => setDialogState(() => direction = v ?? 'receivable'),
                ),
                TextFormField(controller: notes, decoration: const InputDecoration(labelText: 'ملاحظات'), maxLines: 2),
                const SizedBox(height: 8),
                const Text('تعديل الرصيد الافتتاحي لا يغيّر الحركات المسجلة.', style: TextStyle(fontSize: 12)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () { if (formKey.currentState!.validate()) Navigator.pop(dialogContext, true); }, child: const Text('حفظ التعديلات')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        final db = await _db;
        final stationId = await _stationId();
        final value = int.parse(opening.text.trim());
        final accountId = (account['id'] as num).toInt();
        final changed = await db.update(
          'general_accounts',
          {
            'name': name.text.trim(),
            'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
            'address': address.text.trim().isEmpty ? null : address.text.trim(),
            'opening_balance': direction == 'receivable' ? value : -value,
            'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
            'updated_at': AppClock.now().toIso8601String(),
          },
          where: 'id=? AND station_id=? AND active=1',
          whereArgs: [accountId, stationId],
        );
        if (changed == 0) throw StateError('الحساب غير موجود أو لم يعد نشطًا');
        await _load();
        if (mounted) {
          setState(() => _expandedId = accountId);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تحديث بيانات الحساب')));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل تعديل الحساب: $e')));
      }
    }
    name.dispose();
    phone.dispose();
    address.dispose();
    notes.dispose();
    opening.dispose();
  }

  Future<void> _exportAccountPdf(Map<String, Object?> account) async {
    try {
      final db = await _db;
      final stationId = await _stationId();
      final accountId = (account['id'] as num).toInt();
      final transactions = await db.query(
        'general_account_transactions',
        where: 'account_id=? AND station_id=?',
        whereArgs: [accountId, stationId],
        orderBy: 'date ASC, id ASC',
      );
      final opening = (account['opening_balance'] as num?)?.toInt() ?? 0;
      var runningBalance = opening;
      var totalReceipts = 0;
      var totalPayments = 0;
      final rows = <List<String>>[];
      for (final transaction in transactions) {
        final amount = (transaction['amount'] as num?)?.toInt() ?? 0;
        final receipt = transaction['type'] == 'receipt';
        if (receipt) {
          totalReceipts += amount;
          runningBalance -= amount;
        } else {
          totalPayments += amount;
          runningBalance += amount;
        }
        final rawDate = '${transaction['date'] ?? ''}';
        final date = rawDate.contains('T') ? rawDate.split('T').first : rawDate;
        final reference = '${transaction['reference_number'] ?? ''}'.trim();
        final notes = '${transaction['notes'] ?? ''}'.trim();
        rows.add([
          date,
          receipt ? 'قبض من الحساب' : 'صرف للحساب',
          _money(amount),
          [reference, notes].where((value) => value.isNotEmpty).join(' — '),
          _money(runningBalance),
        ]);
      }
      final settings = await widget.repository.settings();
      await OfficialReportTemplate.preview(
        rightHeader1: settings['station_name']?.toString() ?? 'منظومة السقاية',
        rightHeader2: 'الحسابات العامة',
        rightHeader3: 'كشف حساب مستقل',
        date: AppClock.now().toIso8601String().split('T').first,
        refNumber: 'حساب رقم $accountId',
        attachments: '—',
        reportTitle: 'كشف حساب عام — ${account['name']}',
        summaryBoxes: [
          StatBoxData(number: '1', title: 'الرصيد الافتتاحي', value: _balanceDescription(opening)),
          StatBoxData(number: '2', title: 'إجمالي القبض', value: '${_money(totalReceipts)} ريال'),
          StatBoxData(number: '3', title: 'إجمالي الصرف', value: '${_money(totalPayments)} ريال'),
          StatBoxData(number: '4', title: 'الرصيد الحالي', value: _balanceDescription(runningBalance), isBlueTint: true),
        ],
        columns: const ['التاريخ', 'نوع الحركة', 'المبلغ (ريال)', 'المرجع / الملاحظات', 'الرصيد الجاري'],
        rows: rows,
        fileName: 'general_account_$accountId.pdf',
        preferredRowsPerPage: 20,
        printAfterGenerate: true,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إنشاء كشف PDF: $e')));
    }
  }

  Future<void> _sendAccountMessage(Map<String, Object?> account) async {
    final accountId = (account['id'] as num).toInt();
    final rows = _transactions[accountId] ?? const <Map<String, Object?>>[];
    final balance = _balance(account);
    final name = '${account['name'] ?? 'الحساب'}';
    final message = [
      ManualMessageService.accountSummaryMessage(
        recipientName: name,
        partyLabel: 'الحساب العام',
        balanceLabel: _balanceDescription(balance),
        asOf: AppClock.now(),
      ),
      'إجمالي القبض: ${_money(_sumType(rows, 'receipt'))} ريال',
      'إجمالي الصرف: ${_money(_sumType(rows, 'payment'))} ريال',
    ].join('\n');
    await ManualMessageService.offerChoices(
      context,
      title: 'إرسال رسالة حساب عام',
      recipientName: name,
      phone: '${account['phone'] ?? ''}',
      message: message,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الحسابات العامة'),
        actions: [
          IconButton(onPressed: _load, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded)),
          IconButton(onPressed: _createAccount, tooltip: 'إضافة حساب', icon: const Icon(Icons.person_add_alt_1_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _createAccount, icon: const Icon(Icons.add), label: const Text('حساب جديد')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(controller: _search, onChanged: (_) => _load(), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'ابحث باسم الحساب أو الهاتف', suffixIcon: IconButton(onPressed: () { _search.clear(); _load(); }, icon: const Icon(Icons.clear)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)))),
        ),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!)))
            : _accounts.isEmpty
              ? const Center(child: Text('لا توجد حسابات عامة. أضف حسابًا للبدء.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                    itemCount: _accounts.length,
                    itemBuilder: (context, index) {
                      final account = _accounts[index];
                      final id = (account['id'] as num).toInt();
                      final balance = _balance(account);
                      final rows = _transactions[id] ?? const <Map<String, Object?>>[];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          key: PageStorageKey('general-account-$id'),
                          initiallyExpanded: _expandedId == id,
                          onExpansionChanged: (expanded) => setState(() => _expandedId = expanded ? id : null),
                          leading: const CircleAvatar(child: Icon(Icons.account_balance_wallet_outlined)),
                          title: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${account['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                              Wrap(
                                spacing: 0,
                                runSpacing: 0,
                                children: [
                                  IconButton(
                                    tooltip: 'كشف حساب PDF',
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                                    padding: EdgeInsets.zero,
                                    onPressed: () => _exportAccountPdf(account),
                                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                                  ),
                                  IconButton(
                                    tooltip: 'تعديل الحساب',
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                                    padding: EdgeInsets.zero,
                                    onPressed: () => _editAccount(account),
                                    icon: const Icon(Icons.edit_outlined, size: 20),
                                  ),
                                  IconButton(
                                    tooltip: 'إرسال رسالة',
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                                    padding: EdgeInsets.zero,
                                    onPressed: () => _sendAccountMessage(account),
                                    icon: const Icon(Icons.message_outlined, size: 20),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          subtitle: Text('${account['phone'] ?? 'بدون هاتف'}\n${balance > 0 ? 'لنا عليه' : balance < 0 ? 'له علينا' : 'الرصيد متوازن'}: ${_money(balance)} ريال', style: const TextStyle(height: 1.5)),
                          children: [
                            if ((account['address'] as String?)?.isNotEmpty == true || (account['notes'] as String?)?.isNotEmpty == true)
                              Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: Align(alignment: Alignment.centerRight, child: Text([account['address'], account['notes']].where((x) => x != null && '$x'.trim().isNotEmpty).join(' — ')))),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              child: Wrap(spacing: 8, runSpacing: 8, children: [
                                FilledButton.icon(onPressed: () => _addTransaction(account, 'receipt'), icon: const Icon(Icons.call_received_rounded), label: const Text('قبض من الحساب')),
                                OutlinedButton.icon(onPressed: () => _addTransaction(account, 'payment'), icon: const Icon(Icons.call_made_rounded), label: const Text('صرف للحساب')),
                              ]),
                            ),
                            if (rows.isEmpty)
                              const Padding(padding: EdgeInsets.all(16), child: Text('لا توجد حركات مسجلة'))
                            else
                              ...rows.map((row) {
                                final receipt = row['type'] == 'receipt';
                                return ListTile(
                                  dense: true,
                                  leading: Icon(receipt ? Icons.south_west_rounded : Icons.north_east_rounded, color: receipt ? Colors.green : Colors.orange),
                                  title: Text('${receipt ? 'قبض' : 'صرف'} — ${_money((row['amount'] as num).toInt())} ريال'),
                                  subtitle: Text('${row['date']}\n${[row['reference_number'], row['notes']].where((x) => x != null && '$x'.trim().isNotEmpty).join(' • ')}'),
                                  isThreeLine: true,
                                );
                              }),
                          ],
                        ),
                      );
                    },
                  ),
                )),
      ]),
    );
  }
}
