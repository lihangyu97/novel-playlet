import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/comment_image_loader.dart';
import 'package:novel_playlet/app/widgets/comment_image_strip.dart';
import 'package:novel_playlet/app/widgets/comment_image_viewer.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/data/models/comment_reply.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/features/reader/reader_comments_sheet.dart';

import 'test_images.dart';

/// 阅读页评论面板的行为回归：首屏渲染、回复懒加载、翻页与失败重试。
///
/// 用 fake ApiClient 替换网络层，不启动 Rust 核；评论配图用 1×1 内存图
/// 替换 ImageProvider，不加载任何网络图片。
void main() {
  testWidgets('首屏渲染评论：作者徽章、配图、时间与点赞数', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            _comment(
              id: 'c1',
              name: '作者甲',
              text: '这段写得好',
              isAuthor: true,
              diggCount: 7,
              replyCount: 2,
              imageUrls: const ['https://example.com/a.jpg'],
            ),
            _comment(id: 'c2', name: '读者乙', text: '同意', minutesAgo: 120),
          ],
          totalCount: 2,
        ),
      },
    );
    await _openSheet(tester, api: api, totalCount: 2);

    // 标题区拆成主标题 + 副标题（同一行内排布），总数在副标题里。
    expect(find.text('本章评论'), findsOneWidget);
    expect(find.text('2 条评论'), findsOneWidget);
    expect(find.text('作者甲'), findsOneWidget);
    expect(find.text('作者'), findsOneWidget, reason: 'isAuthor 时显示作者徽章');
    expect(find.text('这段写得好'), findsOneWidget);
    expect(find.text('[图片]'), findsNothing, reason: '图片不再用文字占位');
    expect(find.byType(CommentImageStrip), findsOneWidget, reason: '配图渲染成缩略图');
    expect(find.text('5分钟前'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('2 条回复'), findsOneWidget);
    expect(find.text('还没有评论'), findsNothing);
    expect(
      find.byType(CircleAvatar),
      findsNWidgets(2),
      reason: '头像用昵称首字，不加载网络头像',
    );
    // 定位参数要原样传到接口，否则会拉到别段/别章的评论。
    expect(api.lastBookId, 'book-1');
    expect(api.lastItemId, 'chapter-1');
    expect(api.lastItemVersion, 'v1');
    expect(api.paraIndexes, [3]);
    expect(api.cursors, ['']);
    expect(api.paragraphCounts, [20], reason: '首屏按 count=20 拉取');
    expect(
      tester.widget<Text>(find.text('本章评论')).style?.color,
      ReaderPaper.white.foreground,
      reason: '文字色跟随传入的纸色',
    );
    // 昵称和时间要挨着（此前用 Spacer 把时间顶到最右，和回复行不一致）。
    final nameRect = tester.getRect(
      find.byKey(const ValueKey('comment-name-c2')),
    );
    final timeRect = tester.getRect(
      find.byKey(const ValueKey('comment-time-c2')),
    );
    expect(
      timeRect.left - nameRect.right,
      lessThanOrEqualTo(8),
      reason: '昵称与时间之间不应有大段空白',
    );

    // 关闭按钮直接把弹层 pop 掉，不留下遮罩。
    await tester.tap(find.byTooltip('关闭评论'));
    await tester.pumpAndSettle();
    expect(find.text('本章评论'), findsNothing);
    expect(find.text('2 条评论'), findsNothing);
  });

  testWidgets('点评论配图打开全屏查看器，可翻页并关闭', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            _comment(
              id: 'c1',
              name: '读者甲',
              text: '配图评论',
              imageUrls: const [
                'https://example.com/a.jpg',
                'https://example.com/b.jpg',
              ],
            ),
          ],
          totalCount: 1,
        ),
      },
    );
    await _openSheet(tester, api: api);

    await tester.tap(find.byType(Image).first);
    // 全屏页里的图片加载占位是转圈动画：不能 pumpAndSettle，否则永远转。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CommentImageViewer), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget, reason: '从第一张进入');
    expect(find.byTooltip('关闭图片'), findsOneWidget);

    // 多图时右侧箭头切到下一张（1x 左右滑同样可切，见 Listener 逻辑）。
    await tester.tap(find.byTooltip('下一张'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭图片'));
    await tester.pumpAndSettle();
    expect(find.byType(CommentImageViewer), findsNothing);
    expect(find.text('本章评论'), findsOneWidget, reason: '关闭后回到评论面板');
  });

  testWidgets('全屏查看器：点画面任意处立即关闭（不再等双击仲裁）', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            _comment(
              id: 'c1',
              name: '读者甲',
              text: '配图评论',
              imageUrls: const ['https://example.com/a.jpg'],
            ),
          ],
          totalCount: 1,
        ),
      },
    );
    await _openSheet(tester, api: api);
    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CommentImageViewer), findsOneWidget);

    // 单击（非 x / 箭头按钮）：tap 回调应在当前帧就 pop，而不是等约 300ms
    // 的双击判定超时；用路由动画状态断言「立刻开始退场」。
    await tester.tapAt(tester.getCenter(find.byType(CommentImageViewer)));
    await tester.pump();
    final route = ModalRoute.of(
      tester.element(find.byType(CommentImageViewer)),
    );
    expect(
      route?.animation?.status,
      AnimationStatus.reverse,
      reason: '单击当帧就要开始关闭，不能有双击仲裁延迟',
    );
    await tester.pumpAndSettle();
    expect(find.byType(CommentImageViewer), findsNothing);
    expect(find.text('本章评论'), findsOneWidget);
  });

  testWidgets('回复里的配图也渲染成缩略图', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            _comment(id: 'c1', name: '读者甲', text: '回复带图', replyCount: 1),
          ],
          totalCount: 1,
        ),
      },
      repliesByCommentId: {
        'c1': _replyPage([
          _reply(
            id: 'r1',
            name: '回复者乙',
            text: '图来了',
            imageUrls: const ['https://example.com/reply.jpg'],
          ),
        ]),
      },
    );
    await _openSheet(tester, api: api);
    expect(find.byType(CommentImageStrip), findsNothing, reason: '回复未展开前不构建');

    await tester.tap(find.text('1 条回复'));
    await tester.pumpAndSettle();
    expect(find.text('图来了'), findsOneWidget);
    expect(find.byType(CommentImageStrip), findsOneWidget);
  });

  testWidgets('点击「N 条回复」懒加载并展开，再次点击收起且不重复请求', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            _comment(id: 'c1', name: '读者甲', text: '有同感', replyCount: 2),
          ],
          totalCount: 1,
        ),
      },
      repliesByCommentId: {
        'c1': _replyPage([
          _reply(id: 'r1', name: '回复者乙', text: '我也这么觉得'),
          _reply(id: 'r2', name: '回复者丙', text: '同感'),
        ]),
      },
    );
    await _openSheet(tester, api: api);

    expect(api.replyCalls, 0, reason: '首屏不预热回复');
    expect(find.text('我也这么觉得'), findsNothing);

    await tester.tap(find.text('2 条回复'));
    await tester.pumpAndSettle();

    expect(api.replyCalls, 1, reason: '首次点击才懒加载');
    expect(api.lastReplyBookId, 'book-1');
    expect(api.lastReplyGroupId, 'chapter-1', reason: '回复按章节 itemId 归组');
    expect(api.lastReplyCount, 10, reason: '回复首屏 count=10');
    expect(find.text('我也这么觉得'), findsOneWidget);
    expect(find.text('回复者乙'), findsOneWidget);
    expect(find.text('收起回复'), findsOneWidget);

    await tester.tap(find.text('收起回复'));
    await tester.pumpAndSettle();
    expect(find.text('我也这么觉得'), findsNothing, reason: '再次点击收起回复区');

    await tester.tap(find.text('2 条回复'));
    await tester.pumpAndSettle();
    expect(find.text('我也这么觉得'), findsOneWidget, reason: '重新展开用缓存结果');
    expect(api.replyCalls, 1, reason: '已加载过就不再请求');
  });

  testWidgets('回复加载失败：面板内提示可重试，重试后展开', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            _comment(id: 'c1', name: '读者甲', text: '等回复', replyCount: 3),
          ],
          totalCount: 1,
        ),
      },
      repliesByCommentId: {
        'c1': _replyPage([_reply(id: 'r1', name: '回复者乙', text: '来了')]),
      },
      failingReplyIds: {'c1'},
    );
    await _openSheet(tester, api: api);

    await tester.tap(find.text('3 条回复'));
    await tester.pumpAndSettle();
    expect(find.text('回复加载失败，点击重试'), findsOneWidget);

    api.failingReplyIds.remove('c1');
    await tester.tap(find.text('回复加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(find.text('来了'), findsOneWidget);
    expect(api.replyCalls, 2);
  });

  testWidgets('滚动近底加载下一页、按 id 去重追加，到底显示没有更多了', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            for (var i = 1; i <= 12; i++)
              _comment(id: 'p1-$i', name: '读者$i', text: '第一页评论 $i'),
          ],
          totalCount: 22,
          cursor: 'cursor-1',
          hasMore: true,
        ),
        'cursor-1': _page(
          comments: [
            // 上游翻页偶有重复：同 id 不能被追加第二次。
            _comment(id: 'p1-12', name: '读者12', text: '第一页评论 12'),
            for (var i = 1; i <= 10; i++)
              _comment(id: 'p2-$i', name: '第2页读者$i', text: '第二页评论 $i'),
          ],
          totalCount: 22,
          cursor: 'cursor-2',
        ),
      },
    );
    await _openSheet(tester, api: api, totalCount: 22);

    expect(api.paragraphCalls, 1, reason: '首屏只请求一页');
    expect(find.text('第一页评论 1'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(api.paragraphCalls, 2, reason: '滚动近底触发下一页');
    expect(api.cursors, ['', 'cursor-1'], reason: '翻页必须回传上一页 cursor');

    // ListView 懒构建：加载完成后要把第二页第一行滚进可视区才能断言。
    await tester.dragUntilVisible(
      find.text('第二页评论 1'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('第二页评论 1'), findsOneWidget);

    // 往回滚一点，让页 1 末条与页 2 首条同时构建：若没去重，这里会找到两条
    // 同文案的「第一页评论 12」。
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.text('第一页评论 12'), findsOneWidget, reason: '重复 id 的评论只保留一条');

    await tester.drag(find.byType(ListView), const Offset(0, -1400));
    await tester.pumpAndSettle();
    expect(find.text('没有更多了'), findsOneWidget);
    expect(api.paragraphCalls, 2, reason: 'hasMore=false 后不再请求');
  });

  testWidgets('首屏失败显示重试，重试成功后渲染评论', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [_comment(id: 'c1', name: '读者甲', text: '恢复后的评论')],
          totalCount: 1,
        ),
      },
      failingParagraphCalls: {1},
    );
    await _openSheet(tester, api: api);

    expect(find.text('评论加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    api.failingParagraphCalls.remove(1);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(api.paragraphCalls, 2);
    expect(find.text('恢复后的评论'), findsOneWidget);
    expect(find.text('评论加载失败'), findsNothing);
  });

  testWidgets('下一页失败：footer 提示重试，点击后恢复', (tester) async {
    final api = _FakeApi(
      pagesByCursor: {
        '': _page(
          comments: [
            for (var i = 1; i <= 12; i++)
              _comment(id: 'p1-$i', name: '读者$i', text: '第一页评论 $i'),
          ],
          totalCount: 22,
          cursor: 'cursor-1',
          hasMore: true,
        ),
        'cursor-1': _page(
          comments: [
            for (var i = 1; i <= 10; i++)
              _comment(id: 'p2-$i', name: '第2页读者$i', text: '第二页评论 $i'),
          ],
          totalCount: 22,
          cursor: 'cursor-2',
        ),
      },
      failingParagraphCalls: {2},
    );
    await _openSheet(tester, api: api, totalCount: 22);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(api.paragraphCalls, 2);

    // 失败后滚动不会再自动重试，footer 的重试入口是唯一恢复路径。
    await tester.dragUntilVisible(
      find.text('加载失败，点击重试'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    expect(api.paragraphCalls, 2, reason: '失败后滚动不自动重试');

    api.failingParagraphCalls.remove(2);
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();

    expect(api.paragraphCalls, 3, reason: '重试沿用同一 cursor 再请求');
    expect(api.cursors, ['', 'cursor-1', 'cursor-1']);
    expect(find.text('加载失败，点击重试'), findsNothing);

    await tester.dragUntilVisible(
      find.text('第二页评论 1'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('第二页评论 1'), findsOneWidget);
  });

  testWidgets('空评论显示空态', (tester) async {
    final api = _FakeApi(pagesByCursor: {'': const BookCommentPage()});
    await _openSheet(tester, api: api, totalCount: 0);

    expect(find.text('本章评论'), findsOneWidget);
    expect(find.text('0 条评论'), findsOneWidget);
    expect(find.text('还没有评论'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });
}

Future<void> _openSheet(
  WidgetTester tester, {
  required ApiClient api,
  int totalCount = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        // 配图不碰网络/磁盘缓存：统一换成 1×1 内存图。
        commentImageLoaderProvider.overrideWithValue(fakeCommentImageLoader),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showReaderCommentsSheet(
                  context,
                  paper: ReaderPaper.white,
                  bookId: 'book-1',
                  chapterId: 'chapter-1',
                  itemVersion: 'v1',
                  paraIndex: 3,
                  title: '本章评论',
                  totalCount: totalCount,
                ),
                child: const Text('打开评论'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开评论'));
  await tester.pumpAndSettle();
}

BookCommentPage _page({
  List<BookComment> comments = const <BookComment>[],
  int totalCount = 0,
  String cursor = '',
  bool hasMore = false,
}) {
  return BookCommentPage(
    comments: comments,
    totalCount: totalCount,
    cursor: cursor,
    hasMore: hasMore,
  );
}

BookComment _comment({
  required String id,
  required String name,
  String text = '',
  bool isAuthor = false,
  int diggCount = 0,
  int replyCount = 0,
  List<String> imageUrls = const <String>[],
  int minutesAgo = 5,
}) {
  return BookComment(
    id: id,
    text: text,
    userName: name,
    isAuthor: isAuthor,
    diggCount: diggCount,
    replyCount: replyCount,
    imageUrls: imageUrls,
    createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
  );
}

CommentReply _reply({
  required String id,
  required String name,
  String text = '',
  List<String> imageUrls = const <String>[],
}) {
  return CommentReply(
    id: id,
    userName: name,
    text: text,
    imageUrls: imageUrls,
    createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
  );
}

CommentReplyPage _replyPage(List<CommentReply> replies) {
  return CommentReplyPage(
    replies: replies,
    totalCount: replies.length,
    cursor: '',
    hasMore: false,
  );
}

/// 网络层替身：按 cursor 回放预置分页，并可指定第几次调用失败。
class _FakeApi extends ApiClient {
  _FakeApi({
    this.pagesByCursor = const <String, BookCommentPage>{},
    this.repliesByCommentId = const <String, CommentReplyPage>{},
    this.failingParagraphCalls = const <int>{},
    this.failingReplyIds = const <String>{},
  }) : super(BackendTransport());

  final Map<String, BookCommentPage> pagesByCursor;
  final Map<String, CommentReplyPage> repliesByCommentId;

  /// 第 N 次（1-based）`paragraphComments` 调用抛错；可变集合，测试中途可恢复。
  final Set<int> failingParagraphCalls;
  final Set<String> failingReplyIds;

  int paragraphCalls = 0;
  int replyCalls = 0;
  final List<String> cursors = <String>[];
  final List<int> paraIndexes = <int>[];
  final List<int> paragraphCounts = <int>[];
  String? lastBookId;
  String? lastItemId;
  String? lastItemVersion;
  String? lastReplyBookId;
  String? lastReplyGroupId;
  int? lastReplyCount;

  @override
  Future<BookCommentPage> paragraphComments(
    String bookId,
    String itemId, {
    required int paraIndex,
    required String itemVersion,
    int count = 20,
    String cursor = '',
  }) async {
    paragraphCalls += 1;
    cursors.add(cursor);
    paraIndexes.add(paraIndex);
    paragraphCounts.add(count);
    lastBookId = bookId;
    lastItemId = itemId;
    lastItemVersion = itemVersion;
    if (failingParagraphCalls.contains(paragraphCalls)) {
      throw ApiException('模拟评论接口失败');
    }
    return pagesByCursor[cursor] ?? const BookCommentPage();
  }

  @override
  Future<CommentReplyPage> commentReplies(
    String commentId, {
    required String bookId,
    required String groupId,
    int count = 10,
  }) async {
    replyCalls += 1;
    lastReplyBookId = bookId;
    lastReplyGroupId = groupId;
    lastReplyCount = count;
    if (failingReplyIds.contains(commentId)) {
      throw ApiException('模拟回复接口失败');
    }
    return repliesByCommentId[commentId] ?? const CommentReplyPage();
  }
}
