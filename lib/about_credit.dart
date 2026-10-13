import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 「关于」对话框里的作者信息条目（0.2.30 新增）。
///
/// 需求（用户原话）：
/// "在关于里加入原作者和我的名字，名字蓝色点击能跳转对应的 github 页面，要说清身份。"
///
/// 展示形式：`名字（身份）`，名字为蓝色可点击，点击用系统浏览器打开对应链接。
class AboutCredit extends StatelessWidget {
  const AboutCredit({
    super.key,
    required this.name,
    required this.role,
    required this.url,
  });

  /// 显示的名字（蓝色、可点击）。
  final String name;

  /// 身份说明（如"开源项目 guoapp3 原作者"）。
  final String role;

  /// 点击后打开的地址。
  final String url;

  /// 用系统浏览器打开链接。
  ///
  /// 说明：失败时给出轻提示，避免"点了没反应"。
  /// `mode: LaunchMode.externalApplication` 强制走外部浏览器，
  /// 不用应用内 WebView（本应用无 WebView 依赖）。
  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(url);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (uri == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('链接无效')));
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger?.showSnackBar(const SnackBar(content: Text('未能打开浏览器')));
      }
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text('未能打开浏览器')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final linkColor = Theme.of(context).colorScheme.primary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            InkWell(
              key: ValueKey('about-credit-$name'),
              onTap: () => _open(context),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Text(
                  name,
                  style: TextStyle(
                    color: linkColor,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: linkColor,
                  ),
                ),
              ),
            ),
            Text(
              '（$role）',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
