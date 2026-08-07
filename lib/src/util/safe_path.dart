/// Rules for turning untrusted strings into single filesystem path
/// components (skin ids, plugin ids).
///
/// Both skin and plugin ids come from untrusted manifests and are used
/// directly as directory names under an app-owned root (web-ui/ or
/// plugins/). An id that is not exactly one safe component could resolve
/// outside that root when joined with it, so the same rules apply in both
/// places.
library;

/// Win32 forbids these characters in path components: `<>:"|?*`.
final RegExp _win32ReservedChars = RegExp(r'[<>:"|?*]');

/// Returns true when [component] is exactly one safe filesystem path
/// component under both POSIX and Windows path rules:
///
///   - non-empty
///   - not `.` or `..`
///   - no `/` or `\` separators (rejects nested and absolute paths)
///   - no NUL byte
///   - not a Windows drive path (`C:...`)
///   - not a Windows reserved-character name (`<>:"|?*`)
///   - no trailing dot or space (Win32 silently strips these from path
///     components, so what we write would not be what we read)
///
/// An id that passes can be used as exactly one directory name under a
/// parent directory without escaping it.
bool isSafePathComponent(String component) {
  if (component.isEmpty) return false;
  if (component == '.' || component == '..') return false;
  if (component.contains('/') || component.contains('\\')) return false;
  if (component.contains('\x00')) return false;

  if (component.length >= 2 && component.codeUnitAt(1) == 0x3A /* : */ ) {
    final first = component.codeUnitAt(0);
    final isLetter =
        (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
    if (isLetter) return false;
  }

  if (_win32ReservedChars.hasMatch(component)) return false;
  if (component.endsWith('.') || component.endsWith(' ')) return false;

  return true;
}
