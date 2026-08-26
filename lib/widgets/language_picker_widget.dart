// lib/widgets/language_picker_widget.dart
// Reusable language picker — used on Login screen and Settings screen.

import 'package:flutter/material.dart';
import '../main.dart';
// LocaleService is defined in main.dart
// AppLocalizations is defined in main.dart

class LanguagePickerWidget extends StatelessWidget {
  const LanguagePickerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final l10n = AppLocalizations.of(context);
    final current = LocaleService().locale.languageCode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            l10n.selectLanguage,
            style: TextStyle(
              color: sl.text3,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
        Row(
          children: LocaleService.languages.map((lang) {
            final code = lang['code']!;
            final isSelected = code == current;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: GestureDetector(
                  onTap: () async {
                    await LocaleService().setLocale(Locale(code));
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.accent.withOpacity(0.15)
                          : sl.card2,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.accent
                            : sl.border,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(lang['flag']!, style: const TextStyle(fontSize: 18)),
                        const SizedBox(height: 4),
                        Text(
                          lang['native']!,
                          style: TextStyle(
                            color: isSelected
                                ? sl.accentText
                                : sl.text3,
                            fontSize: 10,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
