import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'modules/auth/login_screen.dart';
import 'modules/cash/shift_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;
  try {
    await Api.init(AppConfig.load());
  } on FormatException catch (e) {
    startupError = e.message;
  } catch (e) {
    startupError = 'تعذّر بدء التطبيق: $e';
  }
  runApp(LamsatApp(startupError: startupError));
}

class LamsatApp extends StatelessWidget {
  final String? startupError;
  const LamsatApp({super.key, this.startupError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'لمسات — الكاشير',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: startupError != null
          ? Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(startupError!, style: const TextStyle(fontSize: 20, color: Brand.bad)))))
          : const _Root(),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Api.client.auth.onAuthStateChange,
      builder: (context, _) {
        final session = Api.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return ShiftGate(key: ValueKey(session.user.id));
      },
    );
  }
}
