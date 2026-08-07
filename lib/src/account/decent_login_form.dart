import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DecentLoginForm extends StatefulWidget {
  const DecentLoginForm({
    super.key,
    required this.accountService,
    required this.onSuccess,
    this.secondaryLabel,
    this.onSecondary,
  });

  final DecentAccountService accountService;

  final VoidCallback onSuccess;

  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  State<DecentLoginForm> createState() => _DecentLoginFormState();
}

class _DecentLoginFormState extends State<DecentLoginForm> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  final Logger _log = Logger('DecentLoginForm');

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShadInput(
          controller: _emailController,
          placeholder: const Text('Email'),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        ShadInput(
          controller: _passwordController,
          placeholder: const Text('Password'),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _login(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (widget.secondaryLabel != null) ...[
              ShadButton.outline(
                onPressed: _loading ? null : widget.onSecondary,
                child: Text(widget.secondaryLabel!),
              ),
              const SizedBox(width: 8),
            ],
            ShadButton(
              onPressed: _loading ? null : _login,
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Login'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final ok = await widget.accountService.login(
        _emailController.text.trim(),
        _passwordController.text,
      );

      if (!mounted) return;

      if (ok) {
        widget.onSuccess();
      } else {
        setState(() {
          _error = 'Login failed. Check your email and password.';
          _loading = false;
        });
      }
    } catch (e, st) {
      _log.warning('failed to perform login', e, st);
      if (!mounted) return;
      setState(() {
        _error = 'Network error. Check your connection and try again.';
        _loading = false;
      });
    }
  }
}
