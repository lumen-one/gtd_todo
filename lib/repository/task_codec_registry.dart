import 'task_codec.dart';

/// Codec 注册表（§4.1）：按内容嗅探挑 codec；旧格式的 codec 永远保留
/// 负责读旧文件。换格式/升版本 = 注册新 codec，旧数据照读。
class TaskCodecRegistry {
  final List<TaskCodec> _codecs;
  final String defaultFormatId;

  TaskCodecRegistry(List<TaskCodec> codecs, {required this.defaultFormatId})
      : _codecs = List.unmodifiable(codecs) {
    if (_codecs.isEmpty) {
      throw ArgumentError('至少注册一个 codec');
    }
    if (!_codecs.any((c) => c.formatId == defaultFormatId)) {
      throw ArgumentError('defaultFormatId 未注册: $defaultFormatId');
    }
  }

  /// 按内容嗅探；无匹配返回 null（调用方降级为 warning）。
  TaskCodec? codecFor(String raw) {
    for (final c in _codecs) {
      if (c.canDecode(raw)) return c;
    }
    return null;
  }

  TaskCodec get defaultCodec => _codecs
      .firstWhere((c) => c.formatId == defaultFormatId);

  List<TaskCodec> get all => _codecs;
}
