import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme/app_theme.dart';

/// 阅读页自定义背景图。
///
/// 图片是**本机文件**，不进 ReaderSettings，也不参与 WebDAV 云同步：另一台
/// 设备没有这份文件，同步过去只会得到一张坏图。换机后回退到纸色即可。
@immutable
class ReaderBackground {
  const ReaderBackground({this.filePath});

  /// 已落盘的绝对路径；null = 没设背景图（或文件已丢失）。
  final String? filePath;

  bool get hasImage => filePath != null;

  @override
  bool operator ==(Object other) =>
      other is ReaderBackground && other.filePath == filePath;

  @override
  int get hashCode => filePath.hashCode;
}

final readerBackgroundProvider =
    NotifierProvider<ReaderBackgroundController, ReaderBackground>(
      ReaderBackgroundController.new,
    );

/// 背景图的本地存储：AppSupport/reader/reader_bg_<ts>.jpg。
///
/// 只存文件名到 SharedPreferences，不存绝对路径：iOS 的容器路径在重装/升级
/// 后会变，存绝对路径下次启动就是一张坏图。
class ReaderBackgroundController extends Notifier<ReaderBackground> {
  static const String prefsKey = 'reader_background_image_v1';
  static const String _dirName = 'reader';

  /// 相册原图动辄几 MB，按屏幕需要的上限压一道再落盘。
  static const int _maxWidth = 1800;
  static const int _maxHeight = 2700;
  static const int _quality = 85;

  /// 用户在磁盘恢复返回前就选过图时，不让旧值把它盖回去。
  bool _userChanged = false;

  Future<void>? _restoreFuture;

  @override
  ReaderBackground build() {
    _restoreFuture ??= _restore();
    return const ReaderBackground();
  }

  /// 本地偏好恢复完成的 Future；给需要等待背景图状态的调用方用。
  Future<void> get restoreFuture => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(prefsKey);
      if (name == null || name.isEmpty) return;
      if (_userChanged) return;
      final directory = await _directory();
      final file = File('${directory.path}/$name');
      // 文件被用户/系统清理掉时顺手清掉悬空偏好，下次照常走纸色。
      // 恢复期间用户刚选过图就不要再动偏好，否则会把新文件名删掉。
      if (!await file.exists()) {
        if (!_userChanged) await prefs.remove(prefsKey);
        return;
      }
      if (_userChanged) return;
      state = ReaderBackground(filePath: file.path);
    } catch (_) {
      // 平台通道/磁盘不可用（Widget 测试、首次启动）时静默回退纸色。
      return;
    }
  }

  /// 从相册选图。返回 false 表示用户取消；异常交给调用方提示。
  Future<bool> pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: _maxWidth.toDouble(),
      maxHeight: _maxHeight.toDouble(),
      imageQuality: _quality,
      // 不读 EXIF：iOS 走 PHPicker 时不触发相册完整权限，也不需要位置等元数据。
      requestFullMetadata: false,
    );
    if (picked == null) return false;
    final bytes = await picked.readAsBytes();
    final directory = await _directory();
    final name = 'reader_bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final target = File('${directory.path}/$name');
    await target.writeAsBytes(bytes, flush: true);

    final previous = state.filePath;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, name);
    _userChanged = true;
    state = ReaderBackground(filePath: target.path);
    // 旧图只留一份，避免每次更换都多占几百 KB。
    if (previous != null && previous != target.path) {
      await _deleteQuietly(File(previous));
    }
    return true;
  }

  Future<void> clear() async {
    final previous = state.filePath;
    _userChanged = true;
    state = const ReaderBackground();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {
      return;
    }
    if (previous != null) await _deleteQuietly(File(previous));
  }

  Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/$_dirName');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      return;
    }
  }
}

/// 阅读页背景层：图片铺满 + 纸色遮罩。
///
/// 遮罩用当前纸色叠加，正文对比度仍由纸色决定，图片再花也不会把字糊掉；
/// 底部再加一点纸色渐变，保证页码/信息条这类半透明前景色在亮图上可读。
/// 夜间纸不铺图片（由阅读页决定不挂载本组件）。
class ReaderBackgroundLayer extends StatelessWidget {
  const ReaderBackgroundLayer({
    super.key,
    required this.paper,
    required this.filePath,
  });

  final ReaderPaper paper;

  /// 背景图绝对路径；null 时只画纸色（用于状态页兜底）。
  final String? filePath;

  /// 纸色遮罩透明度：0.55 意味着图片只贡献 45%，正文仍是"纸上的字"。
  static const double scrimAlpha = 0.55;

  @override
  Widget build(BuildContext context) {
    final file = filePath == null ? null : File(filePath!);
    // 只按屏幕需要的尺寸解码：整张相册原图（4000px+）解成 RGBA 会白占几十 MB。
    final decodeWidth = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context) *
            1.2)
        .round();
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (file != null)
            Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: decodeWidth > 0 ? decodeWidth : null,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              // 文件被删/损坏时只保留纸色遮罩，不影响正文。
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
          ColoredBox(
            color: paper.background.withValues(
              alpha: file == null ? 1 : scrimAlpha,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  paper.background.withValues(alpha: 0),
                  paper.background.withValues(alpha: 0.35),
                ],
                stops: const [0.72, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
