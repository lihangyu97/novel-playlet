import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme/app_theme.dart';

/// 阅读排版偏好。
///
/// 字号/行距参与分页测量，底色只影响配色，所以分页缓存的 key 里不含底色：
/// 换底色不应该重排正文、更不应该丢阅读位置。
@immutable
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 21,
    this.lineHeight = 1.8,
    this.paper = ReaderPaper.parchment,
    this.dayPaper = ReaderPaper.parchment,
    this.showBubbles = true,
    this.showDialogueHighlight = true,
  }) : assert(dayPaper != ReaderPaper.night, '日间底色必须是浅色纸');

  /// 15–30，单位与 Flutter 逻辑像素一致。
  final double fontSize;

  /// 1.3–2.0 的行高倍数。
  final double lineHeight;

  final ReaderPaper paper;

  /// 最近一次选择的浅色纸：工具栏「日间」按钮从夜间切回来时用它。
  ///
  /// 单独存一份而不是从 [paper] 猜：夜间只是临时切换，用户在设置里挑的
  /// 白/纸/护眼要在退出阅读页、甚至重启 App 后仍然记得。
  final ReaderPaper dayPaper;

  /// 是否在段尾画段评气泡。关掉只影响气泡渲染，章末/工具栏评论入口仍在。
  final bool showBubbles;

  /// 是否给双引号里的人物对话画荧光笔。只影响渲染，不参与分页测量。
  final bool showDialogueHighlight;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    ReaderPaper? paper,
    ReaderPaper? dayPaper,
    bool? showBubbles,
    bool? showDialogueHighlight,
  }) => ReaderSettings(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    paper: paper ?? this.paper,
    dayPaper: dayPaper ?? this.dayPaper,
    showBubbles: showBubbles ?? this.showBubbles,
    showDialogueHighlight: showDialogueHighlight ?? this.showDialogueHighlight,
  );

  @override
  bool operator ==(Object other) =>
      other is ReaderSettings &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.paper == paper &&
      other.dayPaper == dayPaper &&
      other.showBubbles == showBubbles &&
      other.showDialogueHighlight == showDialogueHighlight;

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineHeight,
    paper,
    dayPaper,
    showBubbles,
    showDialogueHighlight,
  );
}

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsController, ReaderSettings>(
      ReaderSettingsController.new,
    );

/// 阅读设置：默认值同步可用，本地偏好异步补上，避免首帧等待磁盘。
class ReaderSettingsController extends Notifier<ReaderSettings> {
  static const _fontSizeKey = 'reader_font_size_v1';
  static const _lineHeightKey = 'reader_line_height_v1';
  static const _paperKey = 'reader_paper_v1';
  static const _dayPaperKey = 'reader_day_paper_v1';
  static const _bubblesKey = 'reader_show_bubbles_v1';
  static const _dialogueHighlightKey = 'reader_show_dialogue_highlight_v1';

  static const double minFontSize = 15;
  static const double maxFontSize = 30;
  static const double minLineHeight = 1.3;
  static const double maxLineHeight = 2.0;

  /// 用户在磁盘读取返回前就改过设置时，不能被旧的落盘值覆盖。
  bool _userChanged = false;

  bool _restored = false;
  Future<void>? _restoreFuture;

  /// 本地偏好是否已从磁盘恢复（成功/失败都算完成）。
  ///
  /// 冷启动时 [build] 先给默认值、异步补磁盘值；「按开关决定要不要发请求」
  /// 的逻辑（如段评锚点补取）必须等它，否则会拿默认值误判。
  bool get isRestored => _restored;

  /// 本地偏好恢复完成的 Future；没有开始恢复时立即触发一次。
  Future<void> get restoreFuture => _restoreFuture ??= _restore();

  @override
  ReaderSettings build() {
    _restoreFuture = _restore();
    return const ReaderSettings();
  }

  void setFontSize(double value) {
    final next = value.clamp(minFontSize, maxFontSize).toDouble();
    if (next == state.fontSize) return;
    _userChanged = true;
    state = state.copyWith(fontSize: next);
    _persist();
  }

  void setLineHeight(double value) {
    // Slider 的浮点步进会带出 1.6500000000000001，落盘前收一下。
    final next = double.parse(
      value.clamp(minLineHeight, maxLineHeight).toStringAsFixed(2),
    );
    if (next == state.lineHeight) return;
    _userChanged = true;
    state = state.copyWith(lineHeight: next);
    _persist();
  }

  void setPaper(ReaderPaper paper) {
    if (paper == state.paper) return;
    _userChanged = true;
    // 选浅色纸时同步记住「日间底色」；选夜间只切换当前纸，不动记忆，
    // 这样切回日间能回到用户上次挑的纸色。
    final dayPaper = paper == ReaderPaper.night ? state.dayPaper : paper;
    state = state.copyWith(paper: paper, dayPaper: dayPaper);
    _persist();
  }

  /// 日间/夜间切换：夜间回到上次选择的浅色纸，浅色进夜间。
  void toggleDayNight() {
    final next = state.paper == ReaderPaper.night
        ? state.dayPaper
        : ReaderPaper.night;
    setPaper(next);
  }

  void setShowBubbles(bool value) {
    if (value == state.showBubbles) return;
    _userChanged = true;
    state = state.copyWith(showBubbles: value);
    _persist();
  }

  void setShowDialogueHighlight(bool value) {
    if (value == state.showDialogueHighlight) return;
    _userChanged = true;
    state = state.copyWith(showDialogueHighlight: value);
    _persist();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_userChanged) return;
      const fallback = ReaderSettings();
      final paperName = prefs.getString(_paperKey);
      final paper = ReaderPaper.values.firstWhere(
        (candidate) => candidate.name == paperName,
        orElse: () => fallback.paper,
      );
      final storedDayPaper = ReaderPaper.values.firstWhere(
        (candidate) => candidate.name == prefs.getString(_dayPaperKey),
        orElse: () => paper == ReaderPaper.night ? fallback.dayPaper : paper,
      );
      // 老版本只存了 paper：若存的正是浅色纸就沿用它，夜间则退回默认纸。
      final dayPaper = storedDayPaper == ReaderPaper.night
          ? fallback.dayPaper
          : storedDayPaper;
      final restored = ReaderSettings(
        fontSize: (prefs.getDouble(_fontSizeKey) ?? fallback.fontSize)
            .clamp(minFontSize, maxFontSize)
            .toDouble(),
        lineHeight: (prefs.getDouble(_lineHeightKey) ?? fallback.lineHeight)
            .clamp(minLineHeight, maxLineHeight)
            .toDouble(),
        paper: paper,
        dayPaper: dayPaper,
        showBubbles: prefs.getBool(_bubblesKey) ?? fallback.showBubbles,
        showDialogueHighlight:
            prefs.getBool(_dialogueHighlightKey) ??
            fallback.showDialogueHighlight,
      );
      if (restored != state) state = restored;
    } catch (_) {
      // 本地偏好读不到就用默认排版，不影响正文展示。
      return;
    } finally {
      _restored = true;
    }
  }

  Future<void> _persist() async {
    final snapshot = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontSizeKey, snapshot.fontSize);
      await prefs.setDouble(_lineHeightKey, snapshot.lineHeight);
      await prefs.setString(_paperKey, snapshot.paper.name);
      await prefs.setString(_dayPaperKey, snapshot.dayPaper.name);
      await prefs.setBool(_bubblesKey, snapshot.showBubbles);
      await prefs.setBool(
        _dialogueHighlightKey,
        snapshot.showDialogueHighlight,
      );
    } catch (_) {
      // 偏好落盘失败只影响下次启动的默认值，不打扰当前阅读。
      return;
    }
  }
}
