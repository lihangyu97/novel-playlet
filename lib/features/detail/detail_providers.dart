import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/book_detail.dart';
import '../../data/models/chapter.dart';
import '../../data/models/novel_item.dart';

/// 详情页一屏所需的全部数据：详情 + 目录。
class DetailBundle {
  const DetailBundle({required this.detail, required this.chapters});

  final BookDetail detail;
  final List<Chapter> chapters;

  /// 加入书架只需要这几个字段（书架只存 [NovelItem.toStorageJson] 里的内容）。
  NovelItem get shelfItem => NovelItem(
    id: detail.bookId,
    title: detail.title,
    cover: detail.cover,
    author: detail.author,
    category: detail.category,
  );
}

/// 详情与目录并行取。
///
/// 两个接口互不依赖，放在同一个 provider 里 Future.wait：页面因此只有一份
/// 加载态、一份错误态，不会出现「详情已出、目录还在转」的割裂感。
///
/// 用 autoDispose：目录可能有几百章，退出详情页后没必要长期驻留内存。
final detailBundleProvider = FutureProvider.autoDispose
    .family<DetailBundle, String>((ref, bookId) async {
      final api = ref.watch(apiClientProvider);
      // Future.wait 会原样抛出第一个失败（ApiException），页面才能拿到
      // 可直接展示的 message，而不是被 ParallelWaitError 包一层。
      final values = await Future.wait<Object>([
        api.bookDetail(bookId),
        api.directory(bookId),
      ]);
      return DetailBundle(
        detail: values[0] as BookDetail,
        chapters: values[1] as List<Chapter>,
      );
    });

/// 上次阅读进度，用来把主按钮切成「继续阅读 · 第N章」。
///
/// 阅读页返回后由详情页 invalidate 一次即可：详情页停留期间进度不会再变。
final detailProgressProvider = FutureProvider.autoDispose
    .family<ReadingProgress?, String>((ref, bookId) async {
      final store = ref.watch(readingStoreProvider);
      return store.progress(bookId);
    });

/// 书架状态。
///
/// 用 AsyncNotifier 而不是 FutureProvider：加入/移出要「先回显、后落盘」，
/// 按钮不能等 SharedPreferences 写完才变。
final detailShelfProvider = AsyncNotifierProvider.autoDispose
    .family<DetailShelfController, bool, String>(DetailShelfController.new);

class DetailShelfController extends AsyncNotifier<bool> {
  DetailShelfController(this.bookId);

  final String bookId;

  @override
  Future<bool> build() {
    final store = ref.watch(readingStoreProvider);
    return store.isOnShelf(bookId);
  }

  /// 切换书架，返回切换后的状态。落盘失败会回滚并重新抛出，由页面提示。
  Future<bool> toggle(NovelItem item) async {
    final store = ref.read(readingStoreProvider);
    final wasOnShelf = state.value ?? false;
    // 先回显再落盘；写盘期间用户若已退出详情页（provider 被 autoDispose
    // 回收），就不要再碰 state 了。
    state = AsyncData(!wasOnShelf);
    try {
      if (wasOnShelf) {
        await store.removeFromShelf(bookId);
      } else {
        await store.addToShelf(item);
      }
      return !wasOnShelf;
    } catch (_) {
      if (ref.mounted) state = AsyncData(wasOnShelf);
      rethrow;
    }
  }
}
