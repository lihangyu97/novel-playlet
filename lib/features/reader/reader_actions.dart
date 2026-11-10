import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// 阅读页顶部「加入书架 / 已在书架」状态。
///
/// 只读一份布尔值：阅读页不允许移出书架（移出属于详情页/我的页），所以用
/// FutureProvider 而不是可切换的 Notifier，加入成功后再 invalidate 重读。
final readerShelfProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, bookId) => ref.watch(readingStoreProvider).isOnShelf(bookId),
);
