import 'package:flutter/material.dart';

/// 轻量 Markdown 渲染组件（0.3.3 新增）。
///
/// 用途：把 GitHub Release 的更新日志（Markdown 源码）按排版显示，
/// 而不是把 `#`、`**`、反引号等符号原样暴露给用户。
///
/// 只覆盖更新日志实际会用到的最小子集，因此不引入第三方 Markdown 依赖：
/// - 标题：`#` / `##` / `###`（逐级字号递减，加粗）
/// - 列表：`-` / `*` / `+`（圆点）与 `1.`（保留序号）
/// - 引用：`> `（左侧竖线）
/// - 分隔线：`---`
/// - 行内：`**加粗**`、`` `等宽` ``、`[文字](链接)`（只显示文字并高亮）
/// - 表格行（含 `|`）与其它未知行：按普通段落显示，不做解析
class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.text, {super.key, this.baseStyle});

  final String text;
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = baseStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final children = _buildBlocks(context, theme, base);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  List<Widget> _buildBlocks(
    BuildContext context,
    ThemeData theme,
    TextStyle base,
  ) {
    final blocks = <Widget>[];
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    var previousWasBlank = true;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final line = raw.trimRight();
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        previousWasBlank = true;
        continue;
      }

      final topGap = previousWasBlank ? 0.0 : 6.0;
      previousWasBlank = false;

      // 分隔线
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        blocks.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1),
          ),
        );
        previousWasBlank = true;
        continue;
      }

      // 标题
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final content = heading.group(2)!.trim();
        final size = switch (level) {
          1 => (base.fontSize ?? 14) * 1.30,
          2 => (base.fontSize ?? 14) * 1.15,
          _ => (base.fontSize ?? 14) * 1.02,
        };
        blocks.add(
          Padding(
            padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 12, bottom: 4),
            child: Text.rich(
              TextSpan(children: _inlineSpans(context, theme, content)),
              style: base.copyWith(
                fontSize: size,
                fontWeight: FontWeight.bold,
                height: 1.35,
              ),
            ),
          ),
        );
        continue;
      }

      // 引用
      if (trimmed.startsWith('>')) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Container(
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 3,
                  ),
                ),
              ),
              child: Text.rich(
                TextSpan(
                  children: _inlineSpans(
                    context,
                    theme,
                    trimmed.replaceFirst(RegExp(r'^>\s?'), ''),
                  ),
                ),
                style: base.copyWith(
                  height: 1.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
        continue;
      }

      // 无序列表
      final bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        blocks.add(
          _listRow(
            context,
            theme,
            base,
            marker: '•',
            content: bullet.group(1)!,
            topGap: topGap,
          ),
        );
        continue;
      }

      // 有序列表
      final ordered = RegExp(r'^(\d{1,3})[.)]\s+(.*)$').firstMatch(trimmed);
      if (ordered != null) {
        blocks.add(
          _listRow(
            context,
            theme,
            base,
            marker: '${ordered.group(1)}.',
            content: ordered.group(2)!,
            topGap: topGap,
          ),
        );
        continue;
      }

      // 普通段落
      blocks.add(
        Padding(
          padding: EdgeInsets.only(top: topGap),
          child: Text.rich(
            TextSpan(children: _inlineSpans(context, theme, trimmed)),
            style: base.copyWith(height: 1.5),
          ),
        ),
      );
    }

    if (blocks.isEmpty) {
      blocks.add(Text(text, style: base.copyWith(height: 1.5)));
    }
    return blocks;
  }

  Widget _listRow(
    BuildContext context,
    ThemeData theme,
    TextStyle base, {
    required String marker,
    required String content,
    required double topGap,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: topGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(marker, style: base.copyWith(height: 1.5)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: _inlineSpans(context, theme, content)),
              style: base.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 行内语法：`**加粗**`、`` `等宽` ``、`[文字](链接)`。
  List<InlineSpan> _inlineSpans(
    BuildContext context,
    ThemeData theme,
    String source,
  ) {
    final spans = <InlineSpan>[];
    // 一次扫描：加粗 / 行内代码 / 链接；其余按普通文字原样输出。
    final pattern = RegExp(
      r'\*\*(.+?)\*\*|`([^`]+?)`|\[([^\]]+?)\]\(([^)]+?)\)',
    );
    var cursor = 0;
    for (final match in pattern.allMatches(source)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, match.start)));
      }
      if (match.group(1) != null) {
        spans.add(
          TextSpan(
            text: match.group(1),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (match.group(2) != null) {
        spans.add(
          TextSpan(
            text: match.group(2),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        );
      } else if (match.group(3) != null) {
        // 更新日志里的链接多为技术地址，只显示文字并用主题色标记。
        spans.add(
          TextSpan(
            text: match.group(3),
            style: TextStyle(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary,
            ),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }
    return spans;
  }
}
