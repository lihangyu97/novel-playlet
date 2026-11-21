import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/app_bottom_sheet.dart';
import '../../../app/widgets/states.dart';
import '../../../core/storage/library_records.dart';
import '../../sync/sync_log.dart';
import '../../sync/sync_status.dart';
import '../mine_providers.dart';
import '../mine_record_copy.dart';
import 'library_type_badge.dart';
import 'mine_recent_tile.dart';

/// 「全部」弹窗看的是哪一类数据。
enum MineAllScope { history, collection }

/// 全量列表弹窗的定位 key（测试 / 无障碍）。
const Key mineAllSheetKey = Key('mine-all-sheet');

/// 打开「全部历史 / 全部收藏」底部弹窗。
Future<void> showMineAllSheet({
  required BuildContext context,
  required MineAllScope scope,
  required ValueChanged<LibraryRecord> onOpen,
}) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (_) => MineAllSheet(scope: scope, onOpen: onOpen),
  );
}

/// 全量历史 / 收藏列表（底部弹窗）。
///
/// 两个入口共用一套版式：`MineRecentTile` 列表 + 左滑删除。删除语义按入口
/// 区分——历史只清进度（收藏还在就保留），收藏走原有的移出收藏（墓碑）。
/// 删除落库后立刻尝试一次 WebDAV 同步，让云端跟本机一致。
class MineAllSheet extends ConsumerStatefulWidget {
  const MineAllSheet({super.key, required this.scope, required this.onOpen});

  final MineAllScope scope;
  final ValueChanged<LibraryRecord> onOpen;

  @override
  ConsumerState<MineAllSheet> createState() => _MineAllSheetState();
}

class _MineAllSheetState extends ConsumerState<MineAllSheet> {
  /// 已经从界面上删掉的 key：等 provider 重新查库前先把它藏掉，避免
  /// Dismissible 在下一帧又整行出现。
  final Set<String> _removedKeys = <String>{};

  bool get _isHistory => widget.scope == MineAllScope.history;

  FutureProvider<List<LibraryRecord>> get _itemsProvider =>
      _isHistory ? mineHistoryAllProvider : mineCollectionProvider;

  FutureProvider<int> get _countProvider =>
      _isHistory ? mineHistoryCountProvider : mineCollectionCountProvider;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_itemsProvider);
    final count = ref.watch(_countProvider).value;
    final visible = async.value
        ?.where((item) => !_removedKeys.contains(item.key))
        .toList(growable: false);
    // 删完一条后本地隐藏会先于 provider 重查生效，标题条数按可见行走，
    // 不会出现「已经只剩 4 条，标题还写共 5 条」。
    final total = visible?.length ?? count;
    return AppBottomSheet(
      key: mineAllSheetKey,
      title: _isHistory ? '全部历史' : '全部收藏',
      subtitle: total == null ? null : '共 $total 条',
      heightFactor: 0.72,
      child: _body(async, visible),
    );
  }

  Widget _body(
    AsyncValue<List<LibraryRecord>> async,
    List<LibraryRecord>? items,
  ) {
    if (items == null) {
      return async.hasError
          ? ErrorView(
              message: '读取本地数据失败，请重试',
              onRetry: () => ref.invalidate(_itemsProvider),
            )
          : const LoadingView(label: '正在读取本地数据…');
    }
    if (items.isEmpty) {
      return EmptyView(
        message: _isHistory ? '还没有阅读记录，去推荐页逛逛' : '收藏夹还是空的，去推荐页看看',
        icon: _isHistory ? Icons.history_rounded : Icons.star_border_rounded,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Dismissible(
          key: ValueKey('mine-all-${widget.scope.name}/${item.key}'),
          direction: DismissDirection.endToStart,
          background: _SwipeDeleteBackground(label: _isHistory ? '删除' : '移出收藏'),
          confirmDismiss: (_) => _confirmDelete(item),
          onDismissed: (_) => _delete(item),
          child: MineRecentTile(
            cover: item.cover,
            title: item.title.isEmpty ? '未命名作品' : item.title,
            label: LibraryTypeBadge(type: item.type),
            subtitle: _isHistory
                ? mineHistorySubtitle(item)
                : mineCollectionSubtitle(item),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              _isHistory ? item.lastReadAt : item.shelfAt,
            ),
            onTap: () => widget.onOpen(item),
          ),
        );
      },
    );
  }

  Future<bool> _confirmDelete(LibraryRecord item) async {
    final title = item.title.isEmpty ? '未命名作品' : item.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(_isHistory ? '删除这条历史？' : '移出收藏？'),
          content: Text(
            _isHistory
                ? '会清掉本机的阅读进度；如果《$title》还在收藏里，收藏不受影响。'
                      '删除会同步到 WebDAV。'
                : '《$title》会从收藏里移除，阅读/观看记录也会一并清掉。'
                      '操作会同步到 WebDAV。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              child: Text(_isHistory ? '删除' : '移出收藏'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  /// Dismissible 完成滑出后才调用：先同步藏行，再落库。
  ///
  /// 先藏行是硬要求——Dismissible 认为「已经 dismiss 的组件不能还留在树里」，
  /// 等 provider 异步重查会晚一帧触发断言。
  Future<void> _delete(LibraryRecord item) async {
    final sync = ref.read(syncStatusProvider.notifier);
    final store = ref.read(readingStoreProvider);
    setState(() => _removedKeys.add(item.key));
    try {
      if (_isHistory) {
        await store.removeHistory(item.type, item.sourceId);
      } else if (item.type.isPlaylet) {
        await store.removeVideoFromShelf(item.sourceId);
      } else {
        await store.removeFromShelf(item.sourceId);
      }
      // 删除已落库：后台推一次书架同步。失败只更新同步状态，不打断列表。
      unawaited(sync.syncNow(trigger: SyncTrigger.library));
    } catch (_) {
      if (!mounted) return;
      // 删除失败把行放回来，避免界面和本地库不一致；错误用对话框提示，
      // 不用 SnackBar——弹层盖在页面 Scaffold 上，SnackBar 会被它挡住。
      setState(() => _removedKeys.remove(item.key));
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除失败'),
          content: const Text('本地数据没有变化，请稍后再试。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }
}

/// 左滑露出的红底删除条：图标 + 文案贴右边，与左滑方向一致。
class _SwipeDeleteBackground extends StatelessWidget {
  const _SwipeDeleteBackground({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: scheme.error,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline_rounded, size: 18, color: scheme.onError),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onError),
          ),
        ],
      ),
    );
  }
}
