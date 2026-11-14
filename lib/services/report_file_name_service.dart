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
    final controller = TextEditingController(text: suggestion);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) {
            final valid = controller.text.trim().isNotEmpty;
            return AlertDialog(
              title: const Text('اسم ملف PDF'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('يمكنك تغيير اسم الملف قبل الطباعة أو المشاركة.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => refresh(() {}),
                    onSubmitted: (_) {
                      if (controller.text.trim().isNotEmpty) {
                        Navigator.pop(dialogContext,
                            normalizeBaseName(controller.text));
                      }
                    },
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
                      color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: valid
                      ? () => Navigator.pop(dialogContext,
                          normalizeBaseName(controller.text))
                      : null,
                  child: const Text('متابعة'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      controller.dispose();
      _dialogOpen = false;
    }
  }
}
