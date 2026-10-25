import '../domain/branch.dart';
import 'branch_codec.dart';

/// `支线.md` 编解码（formatId: `md-branch/1`，格式见 docs/formats/branch.md）。
///
/// 文件结构：**一段一条支线**，段标题是 `## 名字`，段内一行一条任务引用：
///
/// ```markdown
/// ## 校招准备
///
/// - 投一份简历 #[k3f9a2]
/// - 刷完 DP 二十题 #[m8c1d4]
/// ```
///
/// 行尾的 `#[id]` 是判据，前面那截标题只给人读（保存时按任务实时标题重写）。
/// **正文不保真**：不属于段标题或条目行的自由文字保存时消失。解析永不抛异常：
/// 认不出的行直接跳过、进 warnings。
class MarkdownBranchCodec implements BranchCodec {
  @override
  String get formatId => 'md-branch/1';

  /// 段标题：`## 名字`（一至六级都认）。
  static final RegExp _heading = RegExp(r'^#{1,6}\s+(.+)$');

  /// 条目行：`- ` / `* ` 开头。
  static final RegExp _bullet = RegExp(r'^[-*]\s+(.*)$');

  /// 行尾的任务引用 `#[id]`，前面那截是标题。
  static final RegExp _ref = RegExp(r'^(.*?)\s*#\[([^\[\]\s]+)\]\s*$');

  @override
  BranchDecodeResult decode(String raw) {
    final out = <Branch>[];
    final warnings = <String>[];
    String? name;
    var entries = <BranchEntry>[];

    void flush() {
      final current = name;
      if (current == null) return;
      out.add(Branch(name: current, entries: entries));
      entries = <BranchEntry>[];
    }

    for (final line in raw.split('\n')) {
      final text = line.replaceAll('\r', '').trim();
      if (text.isEmpty) continue;

      final heading = _heading.firstMatch(text);
      if (heading != null) {
        flush();
        final title = heading.group(1)!.trim();
        if (title.isEmpty) {
          name = null;
          warnings.add('支线.md: 跳过空名字的段');
        } else {
          name = title;
        }
        continue;
      }

      final bullet = _bullet.firstMatch(text);
      if (bullet == null) continue;
      if (name == null) {
        warnings.add('支线.md: 跳过不属于任何支线的行');
        continue;
      }
      final ref = _ref.firstMatch(bullet.group(1)!.trim());
      if (ref == null) {
        warnings.add('支线.md: 跳过缺少 #[id] 的行');
        continue;
      }
      entries.add(BranchEntry(
        taskId: ref.group(2)!,
        title: ref.group(1)!.trim(),
      ));
    }
    flush();
    return BranchDecodeResult(out, warnings);
  }

  @override
  String encode(List<Branch> branches) {
    final out = StringBuffer();
    for (final b in branches) {
      // 空名字不会由界面产生（服务里拦了），文件被手改坏了也别写出一个认不回的段。
      final name = _oneLine(b.name);
      out.write('## ${name.isEmpty ? '未命名' : name}\n\n');
      for (final e in b.entries) {
        out.write('- ${_oneLine(e.title)} #[${e.taskId}]\n');
      }
      out.write('\n');
    }
    final text = out.toString().trimRight();
    return text.isEmpty ? '' : '$text\n';
  }

  static String _oneLine(String s) =>
      s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
}
