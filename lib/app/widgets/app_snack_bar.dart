import 'package:flutter/material.dart';

/// 全站轻提示的统一时长：1 秒。
///
/// SnackBar 默认 4 秒，操作回执读一遍就够；挂太久会挡住底部内容（播放页
/// 操作行、阅读页工具栏都在底部，最容易被压住）。确实需要更久的地方再显式
/// 传 [showAppSnackBar] 的 `duration`。
const Duration appSnackBarDuration = Duration(seconds: 1);

/// 统一的轻提示：先收掉上一条再显示，连续操作不会排队越积越多。
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = appSnackBarDuration,
  SnackBarBehavior behavior = SnackBarBehavior.fixed,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: duration, behavior: behavior),
    );
}
