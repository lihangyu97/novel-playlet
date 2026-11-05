import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'shell/home_shell.dart';

/// 启动闸门：内核就绪后才进首页。
///
/// 内核负责加解密、签名与设备池，起不来时所有页面都只会报错，所以第一步
/// 就是把它拉起来；失败展示可读原因 + 重试，而不是让用户对着白屏。
class BootstrapGate extends ConsumerWidget {
  const BootstrapGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bootstrap = ref.watch(bootstrapProvider);
    return bootstrap.when(
      data: (_) => const HomeShell(),
      loading: () => const _Splash(),
      error: (error, _) => _StartupError(
        message: '$error',
        onRetry: () => ref.invalidate(bootstrapProvider),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    // 用 scheme.primary 而不是 raw seed：M3 会保证它与页面底色有对比度，
    // 用户把主题色选成近白/近黑时，Splash 图标也不会消失。
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.menu_book_rounded, color: accent, size: 32),
            ),
            const SizedBox(height: 20),
            Text(
              '正在准备阅读环境…',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.error_outline_rounded, size: 44, color: scheme.error),
              const SizedBox(height: 16),
              Text(
                '阅读环境启动失败',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
