library;

final RegExp _win32ReservedChars = RegExp(r'[<>:"|?*]');

bool isSafePathComponent(String component) {
  if (component.isEmpty) return false;
  if (component == '.' || component == '..') return false;
  if (component.contains('/') || component.contains('\\')) return false;
  if (component.contains('\x00')) return false;

  if (component.length >= 2 && component.codeUnitAt(1) == 0x3A) {
    final first = component.codeUnitAt(0);
    final isLetter =
        (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
    if (isLetter) return false;
  }

  if (_win32ReservedChars.hasMatch(component)) return false;
  if (component.endsWith('.') || component.endsWith(' ')) return false;

  return true;
}
