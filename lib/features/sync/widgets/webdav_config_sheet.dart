import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_bottom_sheet.dart';
import '../webdav_client.dart';
import '../webdav_config.dart';

const Key webDavUrlFieldKey = Key('webdav-url-field');
const Key webDavUserFieldKey = Key('webdav-user-field');
const Key webDavPasswordFieldKey = Key('webdav-password-field');
const Key webDavTestButtonKey = Key('webdav-test-button');
const Key webDavSaveButtonKey = Key('webdav-save-button');
const Key webDavClearButtonKey = Key('webdav-clear-button');

/// 打开 WebDAV 配置表单；保存成功返回 true。
Future<bool?> showWebDavConfigSheet(BuildContext context) {
  return showAppBottomSheet<bool>(
    context: context,
    builder: (_) => const WebDavConfigSheet(),
  );
}

class WebDavConfigSheet extends ConsumerStatefulWidget {
  const WebDavConfigSheet({super.key});

  @override
  ConsumerState<WebDavConfigSheet> createState() => _WebDavConfigSheetState();
}

class _WebDavConfigSheetState extends ConsumerState<WebDavConfigSheet> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  WebDavConfig? _existing;
  bool _loading = true;
  bool _testing = false;
  bool _tested = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    WebDavConfig? config;
    try {
      config = await ref.read(webDavConfigProvider.future);
    } catch (_) {
      config = null;
    }
    if (!mounted) return;
    setState(() {
      _existing = config;
      _url.text = config?.baseUrl ?? 'https://dav.jianguoyun.com/dav/';
      _user.text = config?.username ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  WebDavConfig? _currentConfig() {
    final password = _password.text.isEmpty
        ? (_existing?.password ?? '')
        : _password.text;
    final config = WebDavConfig(
      baseUrl: _url.text.trim(),
      username: _user.text.trim(),
      password: password,
    );
    final invalid = config.validate();
    if (invalid != null) {
      setState(() {
        _message = invalid;
        _messageIsError = true;
        _tested = false;
      });
      return null;
    }
    return config;
  }

  void _markEdited() {
    if (!_tested && !_messageIsError) return;
    setState(() {
      _tested = false;
      _message = null;
      _messageIsError = false;
    });
  }

  Future<void> _test() async {
    final config = _currentConfig();
    if (config == null || _testing) return;
    setState(() {
      _testing = true;
      _tested = false;
      _message = null;
      _messageIsError = false;
    });
    final result = await ref.read(webDavClientProvider).testConnection(config);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _tested = result.ok;
      _message = result.message;
      _messageIsError = !result.ok;
    });
  }

  Future<void> _save() async {
    if (!_tested || _testing) return;
    final config = _currentConfig();
    if (config == null) return;
    try {
      await ref.read(webDavConfigStoreProvider).write(config);
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '保存配置失败，请重试';
          _messageIsError = true;
        });
      }
      return;
    }
    ref.invalidate(webDavConfigProvider);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    try {
      await ref.read(webDavConfigStoreProvider).clear();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '清除配置失败，请重试';
          _messageIsError = true;
        });
      }
      return;
    }
    ref.invalidate(webDavConfigProvider);
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return AppBottomSheet(
      title: 'WebDAV',
      closeTooltip: '关闭 WebDAV 配置',
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: webDavUrlFieldKey,
                    controller: _url,
                    enabled: !_testing,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    onChanged: (_) => _markEdited(),
                    decoration: const InputDecoration(
                      labelText: 'WebDAV 地址',
                      hintText: 'https://dav.jianguoyun.com/dav/',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: webDavUserFieldKey,
                    controller: _user,
                    enabled: !_testing,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    onChanged: (_) => _markEdited(),
                    decoration: const InputDecoration(
                      labelText: '账号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: webDavPasswordFieldKey,
                    controller: _password,
                    enabled: !_testing,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) => _markEdited(),
                    decoration: InputDecoration(
                      labelText: '应用密码',
                      hintText: _existing == null ? '不是登录密码' : '已保存，留空表示不修改',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (_existing != null) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: webDavClearButtonKey,
                        onPressed: _clear,
                        child: const Text('清除已保存配置'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_message != null) ...[
                    Text(
                      _message!,
                      style: TextStyle(
                        color: _messageIsError
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          key: webDavTestButtonKey,
                          onPressed: _testing ? null : _test,
                          child: _testing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('测试连接'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: webDavSaveButtonKey,
                          onPressed: _tested && !_testing ? _save : null,
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
