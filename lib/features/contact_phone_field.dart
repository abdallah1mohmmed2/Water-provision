import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/android_contact_picker.dart';

/// A normal editable phone field with an Android contacts shortcut.
/// Choosing a number updates only this controller; saving the form remains
/// an explicit user action. Names and other fields are never overwritten.
class ContactPhoneField extends StatefulWidget {
  const ContactPhoneField({
    required this.controller,
    required this.labelText,
    this.hintText,
    super.key,
  });

  final TextEditingController controller;
  final String labelText;
  final String? hintText;

  @override
  State<ContactPhoneField> createState() => _ContactPhoneFieldState();
}

class _ContactPhoneFieldState extends State<ContactPhoneField> {
  bool _picking = false;

  Future<void> _pickNumber() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final number = await AndroidContactPicker.pickPhoneNumber();
      if (!mounted || number == null) return;
      widget.controller.value = TextEditingValue(
        text: number,
        selection: TextSelection.collapsed(offset: number.length),
      );
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(error.message ?? 'تعذر فتح جهات الاتصال'),
          ),
        );
      }
    } on MissingPluginException {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('ميزة جهات الاتصال غير متاحة في هذا الإصدار')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      keyboardType: TextInputType.phone,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        suffixIcon: AndroidContactPicker.supported
            ? IconButton(
                tooltip: 'اختيار رقم من جهات الاتصال',
                onPressed: _picking ? null : _pickNumber,
                icon: _picking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.contact_phone_outlined),
              )
            : null,
      ),
    );
  }
}
