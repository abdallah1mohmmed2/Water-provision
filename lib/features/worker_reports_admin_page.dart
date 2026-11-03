import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/local_worker_auth_service.dart';

class WorkerReportsAdminPage extends StatefulWidget {
  const WorkerReportsAdminPage({super.key, required this.managerId, required this.workerId, required this.stationId, required this.workerName});
  final int managerId, workerId, stationId;
  final String workerName;
  @override State<WorkerReportsAdminPage> createState() => _WorkerReportsAdminPageState();
}

class _WorkerReportsAdminPageState extends State<WorkerReportsAdminPage> {
  late final auth = LocalWorkerAuthService(stationId: widget.stationId);
  List<Map<String, Object?>> reports = [];
  bool loading = true;
  String? error;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    setState(() { loading = true; error = null; });
    try {
      final result = await auth.workerReportsForManager(managerId: widget.managerId, workerId: widget.workerId);
      if (!mounted) return;
      setState(() { reports = result; loading = false; });
    } catch (e) { if (mounted) setState(() { error = '$e'; loading = false; }); }
  }
  String date(Object? value) { final parsed = DateTime.tryParse('$value'); return parsed == null ? '—' : DateFormat('yyyy/MM/dd • hh:mm a', 'en').format(parsed); }
  String label(Object? status) => switch ('$status') {
    'new' => 'جديد', 'under_review' => 'قيد المراجعة', 'accepted' => 'مقبول',
    'rejected' => 'مرفوض', 'resolved' => 'تمت المعالجة', _ => 'غير معروف',
  };
  Future<void> review(Map<String, Object?> report) async {
    final reply = TextEditingController(text: report['admin_reply']?.toString() ?? '');
    var status = report['status']?.toString() ?? 'new';
    final saved = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text('الرد على البلاغ #${report['id']}'),
        content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: status, decoration: const InputDecoration(labelText: 'حالة البلاغ'),
            items: const [
              DropdownMenuItem(value: 'under_review', child: Text('قيد المراجعة')),
              DropdownMenuItem(value: 'accepted', child: Text('مقبول')),
              DropdownMenuItem(value: 'rejected', child: Text('مرفوض')),
              DropdownMenuItem(value: 'resolved', child: Text('تمت المعالجة')),
            ], onChanged: (value) { if (value != null) setDialogState(() => status = value); },
          ),
          const SizedBox(height: 10),
          TextField(controller: reply, minLines: 3, maxLines: 6, maxLength: 3000, decoration: const InputDecoration(labelText: 'رد الإدارة'))
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('حفظ الرد'))
        ],
      ),
    )) ?? false;
    if (saved && mounted) {
      try {
        await auth.replyToWorkerReport(managerId: widget.managerId, reportId: (report['id'] as num).toInt(), status: status, reply: reply.text);
        await load();
      } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    }
    reply.dispose();
  }
  @override Widget build(BuildContext context) => Directionality(
    textDirection: ui.TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: Text('بلاغات ${widget.workerName}'), actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))]),
      body: loading ? const Center(child: CircularProgressIndicator()) : error != null
        ? Center(child: Text(error!))
        : reports.isEmpty ? const Center(child: Text('لا توجد بلاغات لهذا العامل.'))
        : ListView.builder(padding: const EdgeInsets.all(12), itemCount: reports.length, itemBuilder: (context, index) {
            final report = reports[index];
            return Card(child: ExpansionTile(
              leading: CircleAvatar(child: Icon(report['status'] == 'resolved' ? Icons.check_circle_outline : Icons.report_problem_outlined)),
              title: Text('${report['subject']}'),
              subtitle: Text('${label(report['status'])} • ${date(report['created_at'])} • ${report['category']}'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Align(alignment: Alignment.centerRight, child: Text('${report['description']}')),
                if ('${report['admin_reply'] ?? ''}'.trim().isNotEmpty) Align(alignment: Alignment.centerRight, child: Text('الرد السابق: ${report['admin_reply']}')),
                Align(alignment: Alignment.centerLeft, child: FilledButton.icon(onPressed: () => review(report), icon: const Icon(Icons.reply), label: const Text('مراجعة والرد'))),
              ],
            ));
          }),
    ),
  );
}
