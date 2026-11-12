import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/book_comment.dart';

/// 详情页剧评首屏条数。
///
/// 卡片只露第一条，但同一份数据会被评论弹层当首屏复用，所以按弹层每页
/// 大小请求，打开弹层时不再二次拉第一页（与小说书评的处理一致）。
const videoCommentsPageSize = 20;

/// 短剧详情页「剧评」第一页。
///
/// 评论是详情页的次要信息：请求失败一律返回 null，页面直接不渲染剧评
/// 区块，不弹错误、也不让主内容进错误态；同时显式关掉 Riverpod 自动
/// 重试，避免次要数据在后台反复打接口。
final videoSeriesCommentsProvider = FutureProvider.autoDispose
    .family<BookCommentPage?, String>((ref, seriesId) async {
      if (seriesId.isEmpty) return null;
      final api = ref.watch(apiClientProvider);
      try {
        return await api.seriesComments(seriesId, count: videoCommentsPageSize);
      } catch (_) {
        return null;
      }
    }, retry: (retryCount, error) => null);
