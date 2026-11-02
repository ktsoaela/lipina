import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../services/auth_service.dart';
import '../services/offline_store.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _server = TextEditingController(text: OfflineStore.instance.serverUrl);
  bool _register = false;
  bool _busy = false;
  bool _showServer = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    OfflineStore.instance.serverUrl = _server.text.trim();
    final auth = context.read<AuthService>();
    try {
      if (_register) {
        await auth.register(_user.text.trim(), _email.text.trim(), _pass.text);
      } else {
        await auth.login(_user.text.trim(), _pass.text);
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Icon(Icons.graphic_eq_rounded, size: 64, color: LipinaColors.accent),
                  const SizedBox(height: 12),
                  Text('Lipina', textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900)),
                  const Text('Music · Radio · Podcasts · Focus', textAlign: TextAlign.center,
                      style: TextStyle(color: LipinaColors.muted)),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _user,
                    decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                  if (_register) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email (optional)', prefixIcon: Icon(Icons.mail_outline)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) => (v ?? '').length < (_register ? 8 : 1) ? 'At least 8 characters' : null,
                  ),
                  if (_showServer) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(labelText: 'Server URL', prefixIcon: Icon(Icons.dns_outlined)),
                      validator: (v) => Uri.tryParse(v ?? '')?.hasScheme == true ? null : 'e.g. https://music.example.com',
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: _busy
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_register ? 'Create account' : 'Log in'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _register = !_register),
                    child: Text(_register ? 'Have an account? Log in' : 'New here? Create an account'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _showServer = !_showServer),
                    child: const Text('Server settings', style: TextStyle(color: LipinaColors.muted)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
