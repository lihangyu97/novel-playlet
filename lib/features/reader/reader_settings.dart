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
    this.showBubbles = true,
  });

  /// 15–30，单位与 Flutter 逻辑像素一致。
  final double fontSize;

  /// 1.3–2.0 的行高倍数。
  final double lineHeight;

  final ReaderPaper paper;

  /// 是否在段尾画段评气泡。关掉只影响气泡渲染，章末/工具栏评论入口仍在。
  final bool showBubbles;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    ReaderPaper? paper,
    bool? showBubbles,
  }) => ReaderSettings(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    paper: paper ?? this.paper,
    showBubbles: showBubbles ?? this.showBubbles,
  );

  @override
  bool operator ==(Object other) =>
      other is ReaderSettings &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.paper == paper &&
      other.showBubbles == showBubbles;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, paper, showBubbles);
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
  static const _bubblesKey = 'reader_show_bubbles_v1';

  static const double minFontSize = 15;
  static const double maxFontSize = 30;
  static const double minLineHeight = 1.3;
  static const double maxLineHeight = 2.0;

  /// 用户在磁盘读取返回前就改过设置时，不能被旧的落盘值覆盖。
  bool _userChanged = false;

  @override
  ReaderSettings build() {
    _restore();
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
    state = state.copyWith(paper: paper);
    _persist();
  }

  void setShowBubbles(bool value) {
    if (value == state.showBubbles) return;
    _userChanged = true;
    state = state.copyWith(showBubbles: value);
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
      final restored = ReaderSettings(
        fontSize: (prefs.getDouble(_fontSizeKey) ?? fallback.fontSize)
            .clamp(minFontSize, maxFontSize)
            .toDouble(),
        lineHeight: (prefs.getDouble(_lineHeightKey) ?? fallback.lineHeight)
            .clamp(minLineHeight, maxLineHeight)
            .toDouble(),
        paper: paper,
        showBubbles: prefs.getBool(_bubblesKey) ?? fallback.showBubbles,
      );
      if (restored != state) state = restored;
    } catch (_) {
      // 本地偏好读不到就用默认排版，不影响正文展示。
      return;
    }
  }

  Future<void> _persist() async {
    final snapshot = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontSizeKey, snapshot.fontSize);
      await prefs.setDouble(_lineHeightKey, snapshot.lineHeight);
      await prefs.setString(_paperKey, snapshot.paper.name);
      await prefs.setBool(_bubblesKey, snapshot.showBubbles);
    } catch (_) {
      // 偏好落盘失败只影响下次启动的默认值，不打扰当前阅读。
      return;
    }
  }
}
