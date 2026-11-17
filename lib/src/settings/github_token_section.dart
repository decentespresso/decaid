import 'package:flutter/material.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:url_launcher/url_launcher.dart';

class GithubTokenSection extends StatefulWidget {
  const GithubTokenSection({super.key, required this.credentials});

  final GithubCredentialProvider credentials;

  @override
  State<GithubTokenSection> createState() => _GithubTokenSectionState();
}

class _GithubTokenSectionState extends State<GithubTokenSection> {
  final _tokenController = TextEditingController();
  bool _loading = true;
  bool _configured = false;
  bool _storageAvailable = false;
  bool _unreadable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.credentials.load();
      if (!mounted) return;
      setState(() {
        _configured = widget.credentials.current.isUser;
        _unreadable = false;
        _storageAvailable = true;
        _loading = false;
      });
    } on GithubCredentialException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unreadable = widget.credentials.isUnreadable;
        _storageAvailable = false;
        _error = error.message;
      });
    }
  }

  Future<void> _save() async {
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
                enabled: !_loading,
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
                    onPressed: _loading ? null : _save,
                    child: Text(
                      _configured || _unreadable ? 'Replace' : 'Save',
                    ),
                  ),
                  if (_configured || _unreadable)
                    OutlinedButton(
                      onPressed: _loading ? null : _remove,
                      child: const Text('Remove'),
                    ),
                ],
              ),
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
                'For feedback, use a fine-grained token with Issues: write for '
                'decentespresso/decaid and Gists: write for attachments. '
                'Grant only the additional repositories and permissions you need.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _open(
                      'https://github.com/settings/personal-access-tokens',
                    ),
                    child: const Text('GitHub token settings'),
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
