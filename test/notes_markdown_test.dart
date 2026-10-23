import 'package:flutter_test/flutter_test.dart';
import 'package:gtd_todo/application/notes_markdown.dart';

/// 灵感页只读态的分块与行内样式（docs/panels/notes.md）。
/// 这里只测纯函数；长什么样在 widget 层，不在这测。
void main() {
  List<NotesSpan> inline(String s) => parseNotesInline(s);
  List<NotesBlock> blocks(List<String> lines) => parseNotesMarkdown(lines);

  group('行内样式', () {
    test('加粗、斜体、粗斜体', () {
      expect(inline('**粗**'), [const NotesSpan('粗', NotesSpanStyle.bold)]);
      expect(inline('*斜*'), [const NotesSpan('斜', NotesSpanStyle.italic)]);
      expect(inline('_斜_'), [const NotesSpan('斜', NotesSpanStyle.italic)]);
      expect(
          inline('***都要***'), [const NotesSpan('都要', NotesSpanStyle.boldItalic)]);
    });

    test('删除线与反引号代码', () {
      expect(inline('~~删~~'), [const NotesSpan('删', NotesSpanStyle.strike)]);
      // 代码内部不再解析：星号原样
      expect(inline('`a**b**`'), [const NotesSpan('a**b**', NotesSpanStyle.code)]);
    });

    test('混排时前后文字保持原样', () {
      expect(inline('前 **中** 后'), [
        const NotesSpan('前 '),
        const NotesSpan('中', NotesSpanStyle.bold),
        const NotesSpan(' 后'),
      ]);
    });

    test('链接只留文字', () {
      expect(inline('见 [文档](https://x.y/z) 末尾'), [
        const NotesSpan('见 '),
        const NotesSpan('文档', NotesSpanStyle.link),
        const NotesSpan(' 末尾'),
      ]);
    });

    test('图片只留说明文字，感叹号不落地', () {
      expect(inline('![截图](a.png)'), [const NotesSpan('截图', NotesSpanStyle.link)]);
    });

    test('粗体里套斜体', () {
      expect(inline('**粗 *斜* 粗**'), [
        const NotesSpan('粗 ', NotesSpanStyle.bold),
        const NotesSpan('斜', NotesSpanStyle.boldItalic),
        const NotesSpan(' 粗', NotesSpanStyle.bold),
      ]);
    });

    test('两侧带空格的星号不是斜体', () {
      expect(inline('2 * 3 * 4'), [const NotesSpan('2 * 3 * 4')]);
    });

    test('单词里的下划线不斜', () {
      expect(inline('snake_case_name'), [const NotesSpan('snake_case_name')]);
    });

    test('未闭合的定界符原样显示', () {
      expect(inline('**没闭合'), [const NotesSpan('**没闭合')]);
      expect(inline('`没闭合'), [const NotesSpan('`没闭合')]);
    });

    test('反斜杠转义', () {
      expect(inline(r'\*不斜\*'), [const NotesSpan('*不斜*')]);
    });

    test('空串没有段', () {
      expect(inline(''), isEmpty);
    });
  });

  group('块级', () {
    test('标题吃掉井号，层级照原样', () {
      final h1 = blocks(['# 一']).single;
      expect(h1.kind, NotesBlockKind.heading);
      expect(h1.level, 1);
      expect(h1.spans, [const NotesSpan('一')]);

      final h3 = blocks(['### 三']).single;
      expect(h3.level, 3);
      expect(h3.spans, [const NotesSpan('三')]);
    });

    test('标题收尾的井号也吃掉', () {
      expect(blocks(['## 标题 ##']).single.spans, [const NotesSpan('标题')]);
    });

    test('七个井号不是标题', () {
      expect(blocks(['####### 不是']).single.kind, NotesBlockKind.paragraph);
    });

    test('无序列表按缩进分层', () {
      final bs = blocks(['- 一', '  - 二', '    - 三']);
      expect(bs.map((b) => b.kind), everyElement(NotesBlockKind.bullet));
      expect(bs.map((b) => b.level), [0, 1, 2]);
      expect(bs.first.spans, [const NotesSpan('一')]);
    });

    test('三种无序符号等价', () {
      expect(blocks(['- 项']).single.kind, NotesBlockKind.bullet);
      expect(blocks(['* 项']).single.kind, NotesBlockKind.bullet);
      expect(blocks(['+ 项']).single.kind, NotesBlockKind.bullet);
    });

    test('有序列表保留序号', () {
      final b = blocks(['3. 第三']).single;
      expect(b.kind, NotesBlockKind.ordered);
      expect(b.number, 3);
      expect(blocks(['1) 第一']).single.number, 1);
    });

    test('引用与嵌套层级', () {
      expect(blocks(['> 一层']).single.level, 1);
      expect(blocks(['>> 二层']).single.level, 2);
      expect(blocks(['> 一层']).single.kind, NotesBlockKind.quote);
    });

    test('列表项里照样解析行内', () {
      expect(blocks(['- 先看 **这本**']).single.spans, [
        const NotesSpan('先看 '),
        const NotesSpan('这本', NotesSpanStyle.bold),
      ]);
    });

    test('代码块内部不解析，空行保留', () {
      final b = blocks(['```dart', 'a **b**', '', '  c', '```']).single;
      expect(b.kind, NotesBlockKind.code);
      expect(b.spans.single.style, NotesSpanStyle.plain);
      expect(b.spans.single.text, 'a **b**\n\n  c');
    });

    test('没闭合的代码块吃到末尾', () {
      final b = blocks(['```', 'x']).single;
      expect(b.kind, NotesBlockKind.code);
      expect(b.spans.single.text, 'x');
    });

    test('空行分段，段内保留换行', () {
      final bs = blocks(['第一行', '第二行', '', '第二段']);
      expect(bs.length, 2);
      expect(bs.first.kind, NotesBlockKind.paragraph);
      expect(bs.first.spans.single.text, '第一行\n第二行');
      expect(bs.last.spans.single.text, '第二段');
    });

    test('段落被块级标记打断', () {
      final bs = blocks(['说明', '- 项']);
      expect(bs.map((b) => b.kind),
          [NotesBlockKind.paragraph, NotesBlockKind.bullet]);
    });

    test('纯空行不产生空块', () {
      expect(blocks(['', '   ', '']), isEmpty);
    });

    test('行尾残留的 \\r 不会进正文', () {
      expect(blocks(['# 标题\r']).single.spans, [const NotesSpan('标题')]);
    });
  });
}
