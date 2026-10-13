import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_build.dart';

/// 开屏页（启动画面）。
///
/// 解决的问题：进入软件后，首页要等原生核心初始化 + 拉取第一批视频
/// 才显示内容，中间这段时间是空白等待。
///
/// 做法：先用开屏页盖住，等首页真正"有视频可播"再淡出，
/// 用户感知上就是"一点开就有画面"，而不是"进去后干等"。
///
/// 设计约束：
/// - 不阻塞启动：只做视觉遮挡，初始化逻辑仍在后台并行进行。
/// - **最多停留 3 秒**：首次拉数据可能较慢，不能让用户干等；
///   3 秒后无论如何都进入首页，首页自己显示加载占位（骨架屏）。
/// - 淡出动画不改变布局，不影响底部导航与顶部标题栏。
class AppSplash extends StatefulWidget {
  const AppSplash({
    super.key,
    required this.child,
    required this.ready,
    this.minimumDuration = const Duration(milliseconds: 500),
    this.timeout = const Duration(seconds: 3),
  });

  /// 真正的主界面。
  final Widget child;

  /// 主界面是否已经准备好（例如首页已拉到第一批视频）。
  final ValueListenable<bool> ready;

  /// 开屏页最短展示时间，避免"闪一下就没了"。
  final Duration minimumDuration;

  /// 最长等待时间，超过则强制放行。
  final Duration timeout;

  @override
  State<AppSplash> createState() => _AppSplashState();
}

class _AppSplashState extends State<AppSplash> {
  bool _dismissed = false;
  bool _minimumElapsed = false;
  Timer? _minimumTimer;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _minimumTimer = Timer(widget.minimumDuration, () {
      if (!mounted) return;
      _minimumElapsed = true;
      _maybeDismiss();
    });
    _timeoutTimer = Timer(widget.timeout, () {
      if (!mounted) return;
      _minimumElapsed = true;
      _maybeDismiss();
    });
    widget.ready.addListener(_maybeDismiss);
    _maybeDismiss();
  }

  @override
  void didUpdateWidget(covariant AppSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ready != widget.ready) {
      oldWidget.ready.removeListener(_maybeDismiss);
      widget.ready.addListener(_maybeDismiss);
    }
  }

  @override
  void dispose() {
    _minimumTimer?.cancel();
    _timeoutTimer?.cancel();
    widget.ready.removeListener(_maybeDismiss);
    super.dispose();
  }

  void _maybeDismiss() {
    if (!mounted || _dismissed) return;
    if (!_minimumElapsed || !widget.ready.value) return;
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_dismissed)
          AnimatedOpacity(
            opacity: 1,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            child: const _SplashSurface(),
          ),
      ],
    );
  }
}

class _SplashSurface extends StatelessWidget {
  const _SplashSurface();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF101114),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.play_circle_fill_rounded,
            color: Color(0xFFFF765F),
            size: 84,
          ),
          const SizedBox(height: 20),
          Text(
            appName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '短剧 · 漫剧 · AI 剧',
            style: TextStyle(color: Colors.white54, fontSize: 13, letterSpacing: 1),
          ),
          const SizedBox(height: 40),
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(0xFFFF765F),
            ),
          ),
        ],
      ),
    ),
  );
}
