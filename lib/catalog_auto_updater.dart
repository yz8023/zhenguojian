import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';

/// 剧库自适应自动更新器。
///
/// 策略（用户要求）：
/// - 默认每 **30 分钟** 静默更新一次所有已开放站源；
/// - 如果这一轮没有拉到任何新剧，则下次间隔延长到 **6 小时**；
/// - 6 小时后如果拉到了新剧，恢复为 **30 分钟**；
/// - 6 小时后仍然没有新剧，保持 **6 小时**。
///
/// 设计约束：
/// - 只做“触发更新 + 等待结果”，不新增站源能力；
/// - 静默执行，不弹窗、不打断播放；
/// - 用户切换（`profileEpoch` 变化）或配置锁定时立即停止；
/// - 站源任务本身在原生层有串行保护，重复触发不会重复启动。
class CatalogAutoUpdater extends ChangeNotifier {
  CatalogAutoUpdater(this.repository, this.store)
    : _epoch = store.profileEpoch;

  /// 常规间隔：30 分钟。
  static const Duration frequentInterval = Duration(minutes: 30);

  /// 降级间隔：6 小时（连续拉不到新剧时）。
  static const Duration idleInterval = Duration(hours: 6);

  /// 单轮最长等待时间（站源任务自身 3 分钟超时，留足余量）。
  static const Duration _roundTimeout = Duration(minutes: 12);

  /// 轮询间隔。
  static const Duration _pollInterval = Duration(seconds: 3);

  final AppRepository repository;
  final LocalStore store;
  final int _epoch;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  Duration _interval = frequentInterval;
  DateTime? _lastRun;
  bool _lastFoundNew = false;
  String _lastMessage = '';

  Duration get interval => _interval;
  DateTime? get lastRun => _lastRun;
  bool get lastFoundNew => _lastFoundNew;
  String get lastMessage => _lastMessage;
  bool get running => _running;

  bool get _valid =>
      !_disposed && !store.locked && _epoch == store.profileEpoch;

  /// 开始自动更新：先跑一轮，然后按当前间隔循环。
  void start() {
    if (_timer != null || _disposed) return;
    if (!repository.supportsSourceManagement) return;
    unawaited(runNow());
  }

  /// 立即执行一轮（定时或手动触发）。
  Future<void> runNow() async {
    if (!_valid || _running || !repository.supportsSourceManagement) return;
    final sources = store.sources;
    if (sources.isEmpty) {
      _schedule(_interval);
      return;
    }
    _running = true;
    try {
      final started = <String>[];
      for (final source in sources) {
        if (!_valid) return;
        try {
          await repository.startSourceJob(source.id, 'update');
          started.add(source.id);
        } catch (_) {
          // 单个站源启动失败不影响其他站源。
        }
      }
      if (!_valid) return;
      if (started.isEmpty) {
        _finish(found: false, message: '站源更新未能启动，稍后重试');
        return;
      }
      final found = await _awaitCompletion(started);
      if (!_valid) return;
      _finish(found: found);
    } finally {
      _running = false;
      if (_valid) _schedule(_interval);
    }
  }

  /// 轮询等待所有已启动的站源任务结束，返回是否拉到了新剧。
  Future<bool> _awaitCompletion(List<String> ids) async {
    final pending = ids.toSet();
    var found = false;
    final deadline = DateTime.now().add(_roundTimeout);
    while (pending.isNotEmpty && _valid) {
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(_pollInterval);
      if (!_valid) break;
      for (final id in pending.toList()) {
        try {
          final status = await repository.sourceStatus(id);
          if (!status.running) {
            if (status.added > 0) found = true;
            pending.remove(id);
          }
        } catch (_) {
          pending.remove(id);
        }
      }
    }
    return found;
  }

  void _finish({required bool found, String message = ''}) {
    _lastRun = DateTime.now();
    _lastFoundNew = found;
    // 拉到新剧 → 回到 30 分钟；没有新剧 → 延长到 6 小时。
    _interval = found ? frequentInterval : idleInterval;
    _lastMessage = message.isNotEmpty
        ? message
        : found
        ? '发现新剧，恢复 ${_interval.inMinutes} 分钟更新'
        : '暂无新剧，${_interval.inHours} 小时后再试';
    notifyListeners();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(runNow());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
