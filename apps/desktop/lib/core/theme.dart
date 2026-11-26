import 'package:flutter/material.dart';

class Brand {
  static const ink = Color(0xFF10242B);
  static const ink2 = Color(0xFF1B343D);
  static const orange = Color(0xFFFF5A26);
  static const bg = Color(0xFFF3F5F6);
  static const line = Color(0xFFDFE5E8);
  static const muted = Color(0xFF62727A);
  static const ok = Color(0xFF1D7A4F);
  static const bad = Color(0xFFB42318);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Brand.orange, brightness: Brightness.light)
      .copyWith(primary: Brand.orange, onPrimary: Colors.white, surface: Colors.white, error: Brand.bad);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.bg,
    fontFamily: 'Segoe UI',
    textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 16, color: Brand.ink), bodyLarge: TextStyle(fontSize: 17, color: Brand.ink)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Brand.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Brand.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Brand.orange, width: 2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.orange,
        foregroundColor: Colors.white,
        minimumSize: const Size(120, 52),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'Segoe UI'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Brand.ink,
        minimumSize: const Size(100, 48),
        side: const BorderSide(color: Brand.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}

/// شارة حالة الاتصال — تظهر في كل الشاشات.
class ConnectionBadge extends StatelessWidget {
  final bool? online;
  final bool onDark;
  const ConnectionBadge({super.key, required this.online, this.onDark = true});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (online) {
      true => ('متصل', const Color(0xFF4ADE80)),
      false => ('غير متصل — الاعتماد متوقف', const Color(0xFFFF8A80)),
      null => ('جارٍ فحص الاتصال', Colors.amber),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 12, color: color),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: onDark ? Colors.white : Brand.ink, fontWeight: FontWeight.w600)),
    ]);
  }
}
