import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/season_title.dart';

/// 短剧标题 → 季号。上游没有季字段，只能从标题文字里认（形态见
/// `lib/core/season_title.dart` 顶部注释）。
void main() {
  group('seasonOf', () {
    test('后缀式：季直接拼在剧名末尾', () {
      expect(seasonOf('反差大佬：我家小师妹超正经第七季'), 7);
      expect(seasonOf('满级小师妹师兄们站稳啦第二季'), 2);
      expect(seasonOf('小师妹一来，全宗门都起飞了第一季'), 1);
    });

    test('无季标记 = 第 1 季的老标题，不硬猜成 1', () {
      expect(seasonOf('反差大佬：我家小师妹超正经'), isNull);
      expect(seasonOf('逾矩'), isNull);
    });

    test('括号包裹 / 季后面还有副标题', () {
      expect(seasonOf('全能鬼才小师妹（第一季）'), 1);
      expect(seasonOf('大佬，你该出手了第五季：我真不是大佬啊'), 5);
      expect(seasonOf('大佬，你该出手了第四季：我真不是大佬啊'), 4);
    });

    test('阿拉伯数字与空格', () {
      expect(seasonOf('某剧 第12季'), 12);
      expect(seasonOf('某剧第 3 季'), 3);
    });

    test('中文十位以上', () {
      expect(seasonOf('某剧第十季'), 10);
      expect(seasonOf('某剧第十一季'), 11);
      expect(seasonOf('某剧第二十季'), 20);
      expect(seasonOf('某剧第二十三季'), 23);
    });

    test('不是季号的字样不误伤', () {
      expect(seasonOf('四季更迭'), isNull);
      expect(seasonOf('第一名的季军'), isNull);
      expect(seasonOf(''), isNull);
    });

    test('季号超出范围视为没有', () {
      expect(seasonOf('某剧第一百季'), isNull);
      expect(seasonOf('某剧第0季'), isNull);
    });
  });
}
