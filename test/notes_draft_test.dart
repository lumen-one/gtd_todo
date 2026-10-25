import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/notes_reader.dart';

/// 灵感页的编辑草稿（docs/panels/notes.md）：编辑态与只读态看到同一批行，
/// 被 `[[` 屏蔽的行不进编辑框，保存时按原行号插回。
void main() {
  test('正文段里含 [[ 的行不进编辑框，按原行号记下来', () {
    final d = buildNotesDraft(['[[相关链接]]', '## 今天', '', '- 一件事']);
    expect(d.text, '## 今天\n\n- 一件事');
    expect(d.hidden.map((h) => h.index), [0]);
    expect(d.hidden.single.line, '[[相关链接]]');
  });

  test('中间夹着的屏蔽行也能插回原来的位置', () {
    final body = ['第一段', '[[链接]]', '第二段', '[[又一个]]', '第三段'];
    final d = buildNotesDraft(body);
    expect(d.text, '第一段\n第二段\n第三段');
    expect(d.merge(d.text), body.join('\n'));
  });

  test('一个字都没改：原文一进一出不变', () {
    final body = ['[[a]]', '标题', '内容', '[[b]]', '尾巴'];
    final d = buildNotesDraft(body);
    expect(d.merge(d.text), body.join('\n'));
  });

  test('改了正文：屏蔽行仍在原位，编辑内容按新样子落', () {
    final d = buildNotesDraft(['[[a]]', '旧标题', '旧内容']);
    expect(d.merge('新标题\n新内容\n多加一行'),
        '[[a]]\n新标题\n新内容\n多加一行');
  });

  test('正文被删空：屏蔽行照样留下来，不会跟着被抹掉', () {
    final d = buildNotesDraft(['[[a]]', '内容', '[[b]]']);
    expect(d.merge(''), '[[a]]\n[[b]]');
  });

  test('行数缩到比原行号还短：屏蔽行落到末尾，不越界', () {
    final d = buildNotesDraft(['一', '二', '三', '[[a]]']);
    expect(d.merge('一'), '一\n[[a]]');
  });
}
