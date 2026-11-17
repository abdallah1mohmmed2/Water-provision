import 'package:flutter/material.dart';

class PartyDieselRateField extends StatelessWidget {
  final TextEditingController controller;
  const PartyDieselRateField(this.controller, {super.key});
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: const InputDecoration(
      labelText: 'استهلاك الديزل الخاص (لتر/ساعة)',
      helperText: 'مثال: 4.65 — اتركه فارغًا لاستخدام معدل المنظومة العام',
      helperMaxLines: 3,
    ),
  );
}
