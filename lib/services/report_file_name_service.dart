import 'package:flutter/material.dart';

/// Selects a PDF filename for a single export without changing the report
/// title, data, or any persisted settings.
class ReportFileNameService {
  ReportFileNameService._();

  static final navigatorKey = GlobalKey<NavigatorState>();
  static bool _dialogOpen = false;

  static String normalizeBaseName(String candidate) {
    var name = candidate.trim();
    while (name.toLowerCase().endsWith('.pdf')) {
      name = name.substring(0, name.length - 4).trim();
    }
    name = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (name.length > 120) {
      name = name.substring(0, 120).trim().replaceAll(RegExp(r'[. ]+$'), '');
    }
    return name.isEmpty ? 'تقرير' : name;
  }

  static String withExtension(String baseName) =>
      '${normalizeBaseName(baseName)}.pdf';

  /// Null means the user cancelled; no print/share should occur.
  static Future<String?> choose(String suggestedName) async {
    final suggestion = normalizeBaseName(suggestedName);
    final context = navigatorKey.currentContext;
    // Keep an existing noninteractive export path functional before mounting.
    if (context == null) return suggestion;
    if (_dialogOpen) return null;

    _dialogOpen = true;
    try {
      return await showDialog<String>(
        context: context,
        builder: (_) => _ReportFileNameDialog(suggestion: suggestion),
      );
    } finally {
      _dialogOpen = false;
    }
  }
}

/// Own the controller within the dialog State: showDialog's returned Future
/// resolves when the route pops, before its reverse animation is finished.
class _ReportFileNameDialog extends StatefulWidget {
  const _ReportFileNameDialog({required this.suggestion});

  final String suggestion;

  @override
  State<_ReportFileNameDialog> createState() => _ReportFileNameDialogState();
}

class _ReportFileNameDialogState extends State<_ReportFileNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.suggestion);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.trim().isEmpty) return;
    Navigator.of(context).pop(
      ReportFileNameService.normalizeBaseName(_controller.text),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('اسم ملف PDF'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('يمكنك تغيير اسم الملف قبل الطباعة أو المشاركة.'),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'اسم الملف',
            helperText: 'يُضاف الامتداد PDF تلقائيًا',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'عنوان التقرير داخل المستند لن يتغير.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(
        onPressed: _controller.text.trim().isNotEmpty ? _submit : null,
        child: const Text('متابعة'),
      ),
    ],
  );
}
