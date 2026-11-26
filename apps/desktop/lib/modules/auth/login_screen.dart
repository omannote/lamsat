import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';
import '../../core/theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _State();
}

class _State extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await Api.client.auth.signInWithPassword(email: _email.text.trim(), password: _password.text).timeout(const Duration(seconds: 15));
    } on AuthException catch (e) {
      _error = (e.statusCode == '400') ? 'البريد أو كلمة المرور غير صحيحة.' : 'تعذّر تسجيل الدخول. أعد المحاولة.';
    } catch (_) {
      _error = 'لا يوجد اتصال بالخادم. تحقق من الإنترنت ثم أعد المحاولة.';
      unawaited(Api.checkConnection());
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Center(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Image.asset('assets/brand/lamsat-logo.png', width: 220)),
            const SizedBox(height: 8),
            Center(child: Text('الكاشير — ${Api.config.deviceCode}', style: const TextStyle(color: Brand.muted))),
            const SizedBox(height: 24),
            TextField(
              controller: _email,
              autofocus: true,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'البريد الإلكتروني'),
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _passwordFocus.requestFocus(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              focusNode: _passwordFocus,
              obscureText: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'كلمة المرور'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'جارٍ الدخول…' : 'دخول (Enter)')),
            const SizedBox(height: 16),
            Center(child: ValueListenableBuilder<bool?>(valueListenable: Api.online, builder: (_, v, __) => ConnectionBadge(online: v, onDark: false))),
          ]),
        ),
      ),
    );
  }
}
