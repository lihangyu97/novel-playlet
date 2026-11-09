import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/chapter_ideas.dart';
import 'package:novel_playlet/features/reader/reader_bubble.dart';

import 'preview_harness.dart';

/// 段评气泡外观：空心描边 + **左侧朝左**的小尾巴，三种 variant 只换配色。
///
/// 更新基线：`flutter test --update-goldens test/ui/reader_bubble_test.dart`。
void main() {
  testWidgets('段评气泡-朝左尾巴与三种 variant', (tester) async {
    await loadPreviewFont();
    tester.view.physicalSize = const Size(520, 220);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        // 用预览主题：字体走 previewFontFamily，避免测试环境把数字画成方块。
        theme: previewTheme(const Color(0xFF3B82F6)),
        home: Scaffold(
          body: Center(
            // 放大 4 倍，golden 里能看清描边与尾巴方向。
            child: Transform.scale(
              scale: 4,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ReaderParagraphBubble(
                    count: 3,
                    variant: ParagraphBubbleVariant.plain,
                  ),
                  ReaderParagraphBubble(
                    count: 12,
                    variant: ParagraphBubbleVariant.users,
                  ),
                  ReaderParagraphBubble(
                    count: 120,
                    variant: ParagraphBubbleVariant.author,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('../goldens/reader_bubble.png'),
    );
  });
}
