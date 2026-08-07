/// No-op stub for flutter_inappwebview_linux.
///
/// WPE WebKit 2.0 (libwpewebkit-2.0-dev) is not packaged for Ubuntu/Debian,
/// so the real Linux plugin cannot be built. This stub satisfies the dependency
/// without any native code or WPE WebKit requirement.
class LinuxInAppWebViewPlatform {
  static void registerWith() {}
}
