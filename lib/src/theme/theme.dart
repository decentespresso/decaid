import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DecentColors {
  const DecentColors._();

  static const Color teal = Color(0xFF47cdd9);
  static const Color tealHover = Color(0xFF5cd3dd);
  static const Color tealActive = Color(0xFF32c7d5);

  static const Color cream = Color(0xFFfaeed7);
  static const Color offWhite = Color(0xFFf8f8f8);
  static const Color white = Color(0xFFffffff);

  static const Color bannerBg = Color(0xFF494d53);
  static const Color bannerOverlay = Color(0xFF3d4045);
  static const Color bannerText = Color(0xFFd1d2d4);

  static const Color bodyText = Color(0xFF444444);
  static const Color heading = Color(0xFF333333);
  static const Color strong = Color(0xFF545454);
  static const Color dark = Color(0xFF222222);
  static const Color muted = Color(0xFF949494);

  static const Color border = Color(0x40909090);
  static const Color borderHover = Color(0x13909090);
  static const Color borderActive = Color(0x33909090);

  static const Color darkCard = Color(0xFF3d4045);
  static const Color darkSecondary = Color(0xFF5a5e64);
  static const Color darkMutedForeground = Color(0xFFa3a3a3);
  static const Color darkSelection = Color(0xFF355172);

  static const Color lightMuted = Color(0xFFf5f5f5);

  static const Color destructive = Color(0xFFef4444);
  static const Color selection = Color(0xFFB4D7FF);
}

class DecentColorScheme extends ShadColorScheme {
  const DecentColorScheme({
    required super.background,
    required super.foreground,
    required super.card,
    required super.cardForeground,
    required super.popover,
    required super.popoverForeground,
    required super.primary,
    required super.primaryForeground,
    required super.secondary,
    required super.secondaryForeground,
    required super.muted,
    required super.mutedForeground,
    required super.accent,
    required super.accentForeground,
    required super.destructive,
    required super.destructiveForeground,
    required super.border,
    required super.input,
    required super.ring,
    required super.selection,
    super.custom,
  });

  const DecentColorScheme.light({
    super.background = DecentColors.white,
    super.foreground = DecentColors.bodyText,
    super.card = DecentColors.white,
    super.cardForeground = DecentColors.bodyText,
    super.popover = DecentColors.white,
    super.popoverForeground = DecentColors.bodyText,
    super.primary = DecentColors.teal,
    super.primaryForeground = DecentColors.white,
    super.secondary = DecentColors.cream,
    super.secondaryForeground = DecentColors.dark,
    super.muted = DecentColors.lightMuted,
    super.mutedForeground = DecentColors.muted,
    super.accent = DecentColors.teal,
    super.accentForeground = DecentColors.white,
    super.destructive = DecentColors.destructive,
    super.destructiveForeground = DecentColors.white,
    super.border = DecentColors.border,
    super.input = DecentColors.border,
    super.ring = DecentColors.teal,
    super.selection = DecentColors.selection,
    super.custom,
  });

  const DecentColorScheme.dark({
    super.background = DecentColors.bannerBg,
    super.foreground = DecentColors.bannerText,
    super.card = DecentColors.darkCard,
    super.cardForeground = DecentColors.bannerText,
    super.popover = DecentColors.darkCard,
    super.popoverForeground = DecentColors.bannerText,
    super.primary = DecentColors.teal,
    super.primaryForeground = DecentColors.white,
    super.secondary = DecentColors.darkSecondary,
    super.secondaryForeground = DecentColors.white,
    super.muted = DecentColors.darkSecondary,
    super.mutedForeground = DecentColors.darkMutedForeground,
    super.accent = DecentColors.tealHover,
    super.accentForeground = DecentColors.white,
    super.destructive = DecentColors.destructive,
    super.destructiveForeground = DecentColors.white,
    super.border = DecentColors.darkSecondary,
    super.input = DecentColors.darkSecondary,
    super.ring = DecentColors.teal,
    super.selection = DecentColors.darkSelection,
    super.custom,
  });
}

ShadThemeData buildDecentTheme({Brightness brightness = Brightness.light}) {
  return ShadThemeData(
    colorScheme: brightness == Brightness.light
        ? const DecentColorScheme.light()
        : const DecentColorScheme.dark(),
    brightness: brightness,
  );
}
