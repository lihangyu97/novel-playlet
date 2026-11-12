import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/comment_image_loader.dart';
import 'package:novel_playlet/app/widgets/comment_image_strip.dart';
import 'package:novel_playlet/app/widgets/comment_image_viewer.dart';
import 'package:novel_playlet/data/models/comment_image.dart';

import 'test_images.dart';

/// 评论配图的解码尺寸限制：`CachedNetworkImageProvider.maxWidth` 在普通
/// CacheManager 下会被忽略（release）/断言（debug），所以生产 loader 必须
/// 自己套一层 `ResizeImage`，否则缩略图位会按原图解码进 ImageCache。
void main() {
  group('buildCommentImageProvider', () {
    test('用 ResizeImage 限制解码宽度，且不向 provider 传 maxWidth', () {
      final provider = buildCommentImageProvider(
        'https://example.com/a.jpg',
        memCacheWidth: 200,
      );
      expect(provider, isA<ResizeImage>(), reason: '解码尺寸必须由 ResizeImage 限制');
      final resized = provider as ResizeImage;
      expect(resized.width, 200);
      expect(resized.height, isNull);
      expect(resized.policy, ResizeImagePolicy.exact);

      final inner = resized.imageProvider;
      expect(inner, isA<CachedNetworkImageProvider>());
      expect(
        (inner as CachedNetworkImageProvider).maxWidth,
        isNull,
        reason: '普通 CacheManager 会忽略/断言 provider.maxWidth，尺寸交给 ResizeImage',
      );
    });

    test('同一 URL 不同格位宽度产生不同解码 key（避免 ImageCache 串图）', () {
      ImageProvider load(int? width) => buildCommentImageProvider(
        'https://example.com/a.jpg',
        memCacheWidth: width,
      );

      expect(load(100), isNot(load(200)));
      expect(load(200), load(200));
      // 没给格位宽度时原样返回 provider（查看器/无尺寸场景）。
      expect(load(null), isA<CachedNetworkImageProvider>());
    });
  });

  testWidgets('缩略图用 thumb 地址，点开查看器才用原图地址', (tester) async {
    final loaded = <String>[];
    ImageProvider record(String url, {int? memCacheWidth}) {
      loaded.add(url);
      return MemoryImage(transparentPixelPng);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [commentImageLoaderProvider.overrideWithValue(record)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: CommentImageStrip(
                  imageRefs: const [
                    CommentImageRef(
                      thumb: 'https://example.com/a-thumb.jpg',
                      full: 'https://example.com/a.jpg',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loaded, ['https://example.com/a-thumb.jpg'], reason: '缩略图格位只能下小图');

    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(CommentImageViewer), findsOneWidget);
    expect(loaded, contains('https://example.com/a.jpg'), reason: '全屏查看器才拿原图');
    expect(
      loaded.where((url) => url.endsWith('a-thumb.jpg')),
      hasLength(1),
      reason: '缩略图地址只用于列表格位，查看器不重复解码',
    );
  });
}
