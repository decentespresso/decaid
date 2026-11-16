import 'package:flutter/material.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_token_verifier.dart';
import 'package:url_launcher/url_launcher.dart';

class GithubTokenSection extends StatefulWidget {
  const GithubTokenSection({
    super.key,
    required this.credentials,
    this.verifier = const GithubTokenVerifier(),
  });

  final GithubCredentialProvider credentials;
  final GithubTokenVerifier verifier;

  @override
  State<GithubTokenSection> createState() => _GithubTokenSectionState();
}

class _GithubTokenSectionState extends State<GithubTokenSection> {
  final _tokenController = TextEditingController();
  bool _loading = true;
  bool _configured = false;
  bool _storageAvailable = false;
  bool _unreadable = false;
  bool _testing = false;
  int _verificationGeneration = 0;
  String? _verificationMessage;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tokenController.addListener(_invalidateVerification);
    _load();
  }

  @override
  void dispose() {
    _tokenController.removeListener(_invalidateVerification);
    _tokenController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GithubTokenSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.credentials, widget.credentials)) _load();
  }

  void _invalidateVerification() {
    _verificationGeneration++;
    setState(() => _verificationMessage = null);
  }

  Future<void> _load() async {
    _invalidateVerification();
    final credentials = widget.credentials;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await credentials.load();
      if (!mounted || !identical(credentials, widget.credentials)) return;
      setState(() {
        _configured = widget.credentials.current.isUser;
        _unreadable = false;
        _storageAvailable = true;
        _loading = false;
      });
    } on GithubCredentialException catch (error) {
      if (!mounted || !identical(credentials, widget.credentials)) return;
      setState(() {
        _loading = false;
        _unreadable = widget.credentials.isUnreadable;
        _storageAvailable = false;
        _error = error.message;
      });
    }
  }

  Future<void> _save() async {
    _invalidateVerification();
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() {
        _error = 'Enter a GitHub personal access token before saving.';
      });
      return;
    }
    final wasConfigured = _configured;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.credentials.save(token);
      if (!mounted) return;
      _tokenController.clear();
      setState(() {
        _configured = true;
        _unreadable = false;
        _storageAvailable = true;
        _loading = false;
      });
    } on GithubCredentialException catch (error) {
      if (!mounted) return;
      setState(() {
        _configured = wasConfigured;
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _remove() async {
    _invalidateVerification();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.credentials.remove();
      if (!mounted) return;
      _tokenController.clear();
      setState(() {
        _configured = false;
        _unreadable = false;
        _storageAvailable = true;
        _loading = false;
      });
    } on GithubCredentialException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _testToken() async {
    if (_loading || _testing) return;
    _invalidateVerification();
    final generation = _verificationGeneration;
    final credentials = widget.credentials;
    final draft = _tokenController.text.trim();
    setState(() => _testing = true);
    try {
      final authorization = draft.isNotEmpty
          ? GithubCredentialSnapshot.user(draft)
          : await credentials.currentForRequest();
      if (!mounted || generation != _verificationGeneration) return;
      final result = await widget.verifier.verify(authorization);
      if (!mounted ||
          generation != _verificationGeneration ||
          !identical(credentials, widget.credentials) ||
          (draft.isEmpty &&
              credentials.current.identityKey != authorization.identityKey)) {
        return;
      }
      final source = draft.isNotEmpty
          ? 'Pasted token (not saved)'
          : 'Saved token';
      setState(() => _verificationMessage = '$source: ${result.message}');
    } catch (_) {
      if (mounted && generation == _verificationGeneration) {
        setState(() {
          _verificationMessage = 'Could not test token. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    final status = _loading
        ? 'Checking secure storage…'
        : _unreadable
        ? 'Stored token cannot be read'
        : !_storageAvailable
        ? 'Unknown (storage unavailable)'
        : (_configured ? 'Configured' : 'Not configured');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'GitHub personal access token',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Optional. Stored securely on this device and used for all '
                'Decaid GitHub API requests. Feedback issues and attachment '
                'gists will be attributed to the token owner.',
              ),
              const SizedBox(height: 8),
              Text('Status: $status'),
              const SizedBox(height: 12),
              TextField(
                controller: _tokenController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                keyboardType: TextInputType.visiblePassword,
                enableIMEPersonalizedLearning: false,
                enabled: !_loading && !_testing,
                decoration: const InputDecoration(
                  labelText: 'Personal access token',
                  hintText: 'Paste a token; it will not be shown again',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _loading || _testing ? null : _save,
                    child: Text(
                      _configured || _unreadable ? 'Replace' : 'Save',
                    ),
                  ),
                  if (_configured || _unreadable)
                    OutlinedButton(
                      onPressed: _loading || _testing ? null : _remove,
                      child: const Text('Remove'),
                    ),
                  OutlinedButton.icon(
                    onPressed:
                        _loading ||
                            _testing ||
                            (_tokenController.text.trim().isEmpty &&
                                (!_configured || !_storageAvailable))
                        ? null
                        : _testToken,
                    icon: _testing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(_testing ? 'Testing token...' : 'Test token'),
                  ),
                ],
              ),
              if (_verificationMessage != null) ...[
                const SizedBox(height: 8),
                Semantics(liveRegion: true, child: Text(_verificationMessage!)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (_loading == false &&
                    _error ==
                        'GitHub credential storage failed. Check device secure storage and try again.')
                  TextButton(onPressed: _load, child: const Text('Retry')),
              ],
              const SizedBox(height: 8),
              Text(
                'For Decaid feedback, create a personal access token (classic) '
                'with public_repo for public issues, plus gist only for '
                'logs/screenshots. The broader repo scope also works but grants '
                'private-repository access and is not needed for Decaid. '
                'GitHub limits fine-grained token writes to public organization '
                'repositories when you are not a member. Such tokens can '
                'authenticate and read metadata, but are not generally suitable '
                'for external contributors creating Decaid issues. '
                'A token is optional for public app, skin and plugin update checks. '
                'Feedback is posted as your GitHub account. Set an expiry and '
                'keep your token private.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () =>
                        _open('https://github.com/settings/tokens/new'),
                    child: const Text('Create classic token'),
                  ),
                  TextButton(
                    onPressed: () => _open(
                      'https://docs.github.com/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token',
                    ),
                    child: const Text('Token documentation'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
