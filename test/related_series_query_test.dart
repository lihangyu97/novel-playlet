import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/widgets/related_series_sheet.dart';

/// 播放页「相关」的搜索词清洗：去掉季/集号，不动剧名主体。
void main() {
  group('相关搜索词', () {
    test('去掉第 x 集与两侧括号', () {
      expect(relatedSearchQuery('太奶奶的短剧 第12集'), '太奶奶的短剧');
      expect(relatedSearchQuery('某某（第 3 集）'), '某某');
      expect(relatedSearchQuery('某剧 [第9话]'), '某剧');
      expect(relatedSearchQuery('某剧·第2期'), '某剧');
    });

    test('去掉第 x 季（含中文数字与括号）', () {
      expect(relatedSearchQuery('太奶奶的短剧 第二季'), '太奶奶的短剧');
      expect(relatedSearchQuery('某某（第 3 季）'), '某某');
      expect(relatedSearchQuery('某剧 第2季 第3集'), '某剧');
      expect(relatedSearchQuery('某剧（第二季）第5集'), '某剧');
    });

    test('没有季/集号时原样返回', () {
      expect(relatedSearchQuery('太奶奶的短剧'), '太奶奶的短剧');
      expect(relatedSearchQuery('  某剧  '), '某剧');
    });

    test('只剩序号时退回原剧名，避免空查询', () {
      expect(relatedSearchQuery('第 1 集'), '第 1 集');
    });
  });
}
