import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core_bridge.dart';
import 'detail_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_preferences.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'player_interactions.dart';
import 'widgets.dart';

/// 首页：竖滑视频流（短视频式沉浸浏览）。
///
/// 数据来源跟随首页当前站源：
/// - 红果 → 官方推荐流（真正的随机推荐）；
/// - 其他站源 → 目录列表 + 本地随机打乱；
/// - 全部站源 → 各源混合后再打乱。
///
/// 播放行为：
/// - 默认「连播下一部」：当前这一集播完自动滑到下一部剧；
/// - 点击底部「连播本剧」后改为自动播放本剧下一集；
/// - 再点一次即回到「连播下一部」。
///
/// 播放器能力：进度拖动、单击显隐控件、双击暂停、长按 3 倍速、
/// 倍速切换、清晰度切换、选集、跳详情。
class VerticalFeedScreen extends StatefulWidget {
  const VerticalFeedScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.active = true,
    this.sources = const [],
    this.playerFactory,
    this.videoBuilder,
    this.refreshSignal,
    this.onReady,
    this.singleDrama,
    this.initialEpisodeIndex = 0,
    this.initialPosition = 0,
    this.localOnly = false,
    this.mediaId,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 测试用：替换视频渲染层。
  ///
  /// 非空时不再创建 `VideoController`（它会走原生 platform channel，
  /// 在测试环境里必然失败并污染用例结果），改用注入的组件，
  /// 与旧播放器 `player_screen.dart` 的 `videoBuilder` 同一做法。
  final Widget Function(Widget controls)? videoBuilder;

  /// 单剧模式（0.2.29 新增）：
  ///
  /// 非空时只播放这一部剧，不拉取首页推荐流。
  /// 用于「详情页点播放」「下载页点播放」——用户是从某部剧进来的，
  /// 期望的滑动语义是"上滑下一集 / 下滑上一集"（只在本剧内滑动），
  /// 而不是首页那种"上滑换一部剧"的无限流。
  final Drama? singleDrama;

  /// 单剧模式的起始集索引（详情页/下载页点的是第几集）。
  final int initialEpisodeIndex;

  /// 单剧模式的起始播放位置（秒），用于续播。
  final double initialPosition;

  /// 本地文件模式（0.2.29 新增）：
  ///
  /// true 时用 `repository.localPlayback` 取**已下载的本地文件**，
  /// 而不是 `repository.resolve` 拉在线流。供下载页使用。
  final bool localOnly;

  /// 本地媒体 ID（0.6.0 新增，迁移自老播放器）。
  ///
  /// 非空表示本次播放的是「本地媒体库」里的成品文件（下载页的合并视频等），
  /// 此时观看进度写入**独立存储** `store.saveMediaWatch`，
  /// 而不是普通观看记录 `store.saveWatch`。
  ///
  /// 为什么必须分开：老播放器（`player_screen.dart`）就是这么做的——
  /// 本地媒体的进度用 `mediaWatched` 单独读取，混进普通观看记录会污染「最近观看」。
  final String? mediaId;

  /// 嵌入首页标签页时为 true：不渲染自己的 Scaffold 与返回按钮。
  final bool embedded;

  /// 当前是否可见（切到其他标签时为 false，暂停播放但不销毁）。
  final bool active;

  /// 当前生效的站源集合（由首页传入，随站源切换变化）。
  final List<SourceSite> sources;

  /// 测试用：注入假播放器，避免依赖原生库。
  @visibleForTesting
  final Player Function()? playerFactory;

  /// 外部触发的"重新随机"信号（双击首页标签时自增）。
  final ValueNotifier<int>? refreshSignal;

  /// 首次拿到可播放视频后回调一次（用于关闭开屏页）。
  final VoidCallback? onReady;

  @override
  State<VerticalFeedScreen> createState() => _VerticalFeedScreenState();
}

class _VerticalFeedScreenState extends State<VerticalFeedScreen> {
  /// 红果官方推荐流支持的分类（三类混合随机）。
  static const _hongguoGenres = ['short_play', 'comic_series', 'ai_series'];

  final _controller = PageController();
  final _focus = FocusNode(debugLabel: 'vertical-feed');
  final _random = math.Random();

  List<Drama> _items = [];
  final _seen = <String>{};
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _index = 0;
  int _page = 1;
  int _generation = 0;
  bool _closed = false;

  /// 连播模式：true = 连播本剧下一集，false = 连播下一部（默认）。
  bool _autoNextEpisode = false;

  /// 当前页「切到下一集」的执行入口（由子页上报）。
  ///
  /// 注意：这里**不能**用 GlobalKey 去访问当前页 State。
  /// 同一个 Widget 树里 GlobalKey 只能存在一份，若随着"当前页"来回换 key，
  /// Flutter 会把上一个 State（含播放器实例）整体搬移到新位置，
  /// 导致"标题已换成新剧、视频却还是上一部"的严重错乱。
  Future<void> Function()? _pagePlayNextEpisode;

  /// 当前页「切到上一集」的执行入口（由子页上报）。
  Future<void> Function()? _pagePlayPrevEpisode;

  /// 是否已上报过就绪（只回调一次）。
  bool _reportedReady = false;

  /// 正在切换站源（用于在屏幕上给出"正在切换到 XX…"提示）。
  ///
  /// 0.2.27 新增（用户反馈"切换了源后有很大概率一直卡在为你挑选好剧位置卡很久"）：
  /// 切源属于一次全新的拉取，可能因镜像竞速耗时较久。
  /// 若界面只有"正在为你挑选短剧…"这一句，用户会以为"切了却没反应"。
  /// 因此记录本次切源的目标站源名与开始时间，在加载页展示带站源名和
  /// 已等待秒数的提示，明确告知"正在切换、没有卡死"。
  String? _switchingTo;
  DateTime? _switchStartedAt;
  Timer? _switchTicker;

  /// 切源提示的超时上限（0.2.27：用户确认 60 秒太短，改为 2 分钟）。
  ///
  /// 到达后停止"继续等待"的暗示，转为"可重试"的兜底提示，
  /// 避免用户无限等待一个实际上已经失败的请求。
  static const _switchTimeout = Duration(minutes: 2);

  /// 站源切换提示的刷新计时器（每秒刷新已等待秒数）。
  void _startSwitchTicker(String target) {
    _switchTicker?.cancel();
    _switchingTo = target;
    _switchStartedAt = DateTime.now();
    _switchTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || !mounted) return;
      setState(() {});
    });
  }

  /// 结束切源提示。
  void _stopSwitchTicker() {
    _switchTicker?.cancel();
    _switchTicker = null;
    _switchingTo = null;
    _switchStartedAt = null;
  }

  /// 当前切源已等待的秒数（未在切源时为 0）。
  int get _switchElapsed => _switchStartedAt == null
      ? 0
      : DateTime.now().difference(_switchStartedAt!).inSeconds;

  /// 切源是否已超过兜底时间上限。
  bool get _switchTimedOut => _switchElapsed >= _switchTimeout.inSeconds;

  /// 首批视频到手后通知外部（关闭开屏页）。
  void _reportReady() {
    if (_reportedReady) return;
    _reportedReady = true;
    widget.onReady?.call();
  }

  /// 当前生效的站源集合。
  List<SourceSite> get _sources {
    final list = widget.sources.isNotEmpty
        ? widget.sources
        : widget.store.sources;
    return list
        .where((source) => widget.store.allowsSource(source.id))
        .toList();
  }

  String _signatureOf(List<SourceSite> sources) =>
      sources.map((source) => source.id).join(',');

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onRefreshSignal);
    // 单剧模式（0.2.29）：详情页/下载页进入时只播指定的一部剧，
    // 直接构造单元素列表，跳过推荐流拉取。
    final single = widget.singleDrama;
    if (single != null) {
      _items = [single];
      _loading = false;
      _hasMore = false;
      // 单剧模式下默认「连播本剧」：
      // 这样上滑=下一集、下滑=上一集，符合用户"看这部剧"的直觉，
      // 不必先点「连播本剧」按钮。
      _autoNextEpisode = true;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant VerticalFeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      oldWidget.refreshSignal?.removeListener(_onRefreshSignal);
      widget.refreshSignal?.addListener(_onRefreshSignal);
    }
    if (_signatureOf(oldWidget.sources) != _signatureOf(widget.sources)) {
      // 0.2.27：切源时带上目标站源名，让加载页显示"正在切换到 XX…"，
      // 避免用户产生"切了却没反应"的错觉（用户真机反馈第 5 条）。
      final names = widget.sources.isEmpty
          ? widget.store.sources
          : widget.sources;
      final label = names.length > 1
          ? '全部站源'
          : (names.isEmpty ? '' : names.first.name);
      _reset(switchTo: label.isEmpty ? null : label);
    }
  }

  /// 双击首页标签：换一批新的随机内容。
  void _onRefreshSignal() {
    if (_closed) return;
    _reset(force: true);
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _switchTicker?.cancel();
    widget.refreshSignal?.removeListener(_onRefreshSignal);
    unawaited(widget.repository.cancelRecommendations());
    unawaited(widget.repository.cancelFeedCatalog());
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 站源切换后重新开始随机。
  ///
  /// [switchTo]：本次切源的目标站源名（用于给出"正在切换到 XX…"提示）。
  /// 双击首页标签换一批时不传，保持原有"正在为你挑选短剧…"文案。
  void _reset({bool force = false, String? switchTo}) {
    if (_closed) return;
    _generation++;
    if (_controller.hasClients) _controller.jumpToPage(0);
    setState(() {
      _items = [];
      _seen.clear();
      _index = 0;
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    if (switchTo != null && switchTo.isNotEmpty) {
      _startSwitchTicker(switchTo);
    } else {
      _stopSwitchTicker();
    }
    _load(force: force);
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    if (_closed) return;
    // 单剧模式（0.2.29）：不拉推荐流，列表固定为指定的一部剧。
    if (widget.singleDrama != null) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final sources = _sources;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    if (sources.isEmpty) {
      _stopSwitchTicker();
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _hasMore = false;
        });
      }
      return;
    }
    final page = more ? _page + 1 : 1;
    try {
      final batch = await _fetch(sources, page, more: more, force: force);
      if (_closed || generation != _generation) return;
      final known = more ? _seen : <String>{};
      final accepted = <String>{};
      final fresh = <Drama>[];
      for (final drama in batch.items) {
        if (drama.id.isEmpty || !known.add(drama.id)) continue;
        accepted.add(drama.id);
        fresh.add(drama);
      }
      setState(() {
        if (!more) _seen.clear();
        _seen.addAll(accepted);
        _items = more ? [..._items, ...fresh] : fresh;
        _page = page;
        _hasMore = batch.hasMore;
        _error = batch.warning.isEmpty ? null : batch.warning;
        _loading = false;
        _loadingMore = false;
      });
      _stopSwitchTicker();
      if (_items.isNotEmpty) _reportReady();
    } catch (error) {
      if (_closed || generation != _generation) return;
      _stopSwitchTicker();
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
      });
    }
  }

  /// 拉取一批剧集。
  ///
  /// 单源红果走官方推荐流（真随机）；其余情况读取目录分页，
  /// 多源交错合并后再本地打乱。
  ///
  /// 注意：多个站源**并行**请求。原先是 `for` 循环里逐个 await，
  /// 4 个源就要等 4 次往返，这是"其他源比红果慢很多"的主因。
  Future<_FeedBatch> _fetch(
    List<SourceSite> sources,
    int page, {
    required bool more,
    bool force = false,
  }) async {
    if (sources.length == 1 && sources.first.id == 'hongguo') {
      return _fetchHongguo(more: more, force: force);
    }
    final results = await Future.wait(
      sources.map((source) async {
        if (_closed) return null;
        try {
          return await widget.repository.feedCatalog(
            source.id,
            page: page,
            force: force,
          );
        } catch (error) {
          return _SourceFeedFailure('${source.name}：$error');
        }
      }),
    );
    final rows = <List<Drama>>[];
    final warnings = <String>[];
    var hasMore = false;
    for (final result in results) {
      if (result is _SourceFeedFailure) {
        warnings.add(result.message);
        continue;
      }
      if (result is! CatalogPage) continue;
      rows.add(
        result.items
            .where((drama) => widget.store.allowsSource(drama.source))
            .toList(),
      );
      if (result.hasMore) hasMore = true;
      if (result.warning.isNotEmpty) warnings.add(result.warning);
    }
    final merged = <Drama>[];
    final longest = rows.fold<int>(
      0,
      (best, row) => math.max(best, row.length),
    );
    for (var index = 0; index < longest; index++) {
      for (final row in rows) {
        if (index < row.length) merged.add(row[index]);
      }
    }
    merged.shuffle(_random);
    return _FeedBatch(
      merged,
      hasMore: hasMore,
      warning: warnings.isEmpty ? '' : warnings.join('；'),
    );
  }

  /// 红果：真人剧 / 漫剧 / AI 剧 三类混合后随机。
  ///
  /// 每次打开软件首次进入时强制拉新（游标归零），避免每次都是同一批；
  /// 三类**并行**请求后再交错打乱——原先是顺序请求，等于把延迟乘以 3。
  Future<_FeedBatch> _fetchHongguo({
    required bool more,
    bool force = false,
  }) async {
    final warnings = <String>[];
    var hasMore = false;
    final rows = <List<Drama>>[];
    final results = await Future.wait(
      _hongguoGenres.map((genre) async {
        if (_closed) return null;
        try {
          return await widget.repository.recommendations(
            genre,
            more: more,
            force: force || !more,
          );
        } catch (error) {
          // 单个分类失败不影响其它分类。
          return _SourceFeedFailure('$error');
        }
      }),
    );
    for (final result in results) {
      if (result is _SourceFeedFailure) {
        warnings.add(result.message);
        continue;
      }
      if (result is! CatalogPage) continue;
      rows.add(
        result.items
            .where((drama) => widget.store.allowsSource(drama.source))
            .toList(),
      );
      if (result.hasMore) hasMore = true;
      if (result.warning.isNotEmpty) warnings.add(result.warning);
    }
    final merged = <Drama>[];
    final longest = rows.fold<int>(
      0,
      (best, row) => math.max(best, row.length),
    );
    for (var index = 0; index < longest; index++) {
      for (final row in rows) {
        if (index < row.length) merged.add(row[index]);
      }
    }
    merged.shuffle(_random);
    return _FeedBatch(
      merged,
      hasMore: hasMore,
      warning: warnings.isEmpty ? '' : warnings.join('；'),
    );
  }

  void _onPageChanged(int index) {
    if (_closed) return;
    setState(() => _index = index);
    // 单剧模式（0.2.29）：只有一部剧，不存在"加载更多"。
    if (widget.singleDrama != null) return;
    // 接近末尾时自动加载下一批。
    if (_hasMore && !_loadingMore && index >= _items.length - 2) {
      unawaited(_load(more: true));
    }
  }

  /// 子页上报"能否切集"，并同时提供切集入口。
  ///
  /// [hasNext]：本页是否还有下一集；[playNext]：切到下一集的执行函数。
  /// [hasPrev]：本页是否还有上一集；[playPrev]：切到上一集的执行函数。
  ///
  /// 之所以用回调而不是 GlobalKey：GlobalKey 在同一 Widget 树中必须唯一，
  /// 若随"当前页"来回更换，Flutter 会搬移 State（含播放器）导致画面错乱。
  ///
  /// 0.2.26 变更：不再用上报结果决定 `PageView.physics` 与手势接管
  /// （那会导致首帧不一致的 bug，见 `_onVerticalDrag` 注释）。
  /// 因此这里只保存切集入口，**不需要 setState 重建**，
  /// 顺带消除了"每次上报都重建整棵竖滑树"的额外开销。
  void _onPageEpisodeStateChanged(
    bool hasNext, {
    Future<void> Function()? playNext,
    bool hasPrev = false,
    Future<void> Function()? playPrev,
  }) {
    if (_closed) return;
    _pagePlayNextEpisode = hasNext ? playNext : null;
    _pagePlayPrevEpisode = hasPrev ? playPrev : null;
  }

  /// 处理竖向拖拽结束时的滑动判定（仅在 PageView 被禁用滚动时生效）。
  ///
  /// 说明：当「连播本剧」开启且当前剧还有下一集时，PageView 会被设为
  /// `NeverScrollableScrollPhysics`，避免它抢占手势；此时由这里统一处理。
  ///
  /// 滑动语义（0.2.26 修正，用户确认方案 A）：
  /// - **向上滑 = 下一集**（符合短视频"往下看内容"的直觉：手指上推看后面的）。
  /// - **向下滑 = 上一集**。
  /// - 已到第一集/最后一集时，回落为"切上一部 / 下一部剧"。
  ///
  /// 0.2.27 新增（用户反馈第 4 条）：
  /// 在「连播本剧」模式下，若已到**第一集**仍继续下滑、或已到**最后一集**
  /// 仍继续上滑，会落到"切上一部 / 下一部剧"分支。此时当前剧已看尽，
  /// 再保持"连播本剧"毫无意义，因此**自动复位为「连播下一部」**并给出轻提示，
  /// 否则用户会以为模式没变、不知道为何不再连播本剧。
  ///
  /// 历史问题（0.2.25 真机反馈）：
  /// 1. 方向写反——原实现把 `velocity > 0`（向下滑）当成"下一集"。
  /// 2. 首帧未上报时误判——`_pageHasNextEpisode` 初始为 false，
  ///    第一页进入后若 episode 状态还没上报，`_currentPageCanPlayNext`
  ///    为 false 会走"切部"分支；而第二页上报后就变成"切集"，
  ///    因此表现为"第一部要下滑才切下集、第二部上滑却回上一部剧"。
  ///    修法：只要处于「连播本剧」模式，就一律由本方法接管并优先切集，
  ///    不再依赖"是否上报了下一集"来做分支（切集函数内部自身会判断边界）。
  void _onVerticalDrag(DragEndDetails details) {
    if (_closed) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity == 0) return;
    // 单剧模式（0.2.29，用户方案 C）：
    // 只在本剧内滑动。到边界（第一集/最后一集）时**不切剧**，
    // 只给一句提示，避免用户莫名其妙地跳到别的剧去。
    final single = widget.singleDrama != null;
    if (velocity < 0) {
      // 向上滑 = 下一集。
      if (_autoNextEpisode) {
        final playNext = _pagePlayNextEpisode;
        if (playNext != null) {
          unawaited(playNext());
          return;
        }
        if (single) {
          _toast('已经是最后一集了');
          return;
        }
        // 已到最后一集：回落为切下一部剧，并复位连播模式（0.2.27）。
        _resetAutoNextAtBoundary('本剧已看完，已切换为连播下一部');
      }
      _jump(1);
    } else {
      // 向下滑 = 上一集。
      if (_autoNextEpisode) {
        final playPrev = _pagePlayPrevEpisode;
        if (playPrev != null) {
          unawaited(playPrev());
          return;
        }
        if (single) {
          _toast('已经是第一集了');
          return;
        }
        // 已到第一集：回落为切上一部剧，并复位连播模式（0.2.27）。
        _resetAutoNextAtBoundary('已是第一集，已切换为连播下一部');
      }
      _jump(-1);
    }
  }

  /// 在连播本剧模式下因到达首/尾集而切部时，自动复位为「连播下一部」。
  ///
  /// 0.2.27 新增（用户反馈第 4 条，方案 A + 轻提示）：
  /// 只在"因边界切部"时调用，不会在正常切集时误触发。
  void _resetAutoNextAtBoundary(String message) {
    if (!_autoNextEpisode) return;
    setState(() => _autoNextEpisode = false);
    _toast(message);
  }

  /// 轻提示（底部 SnackBar）。
  void _toast(String message) {
    if (_closed || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 遥控器 / 键盘上下键切换。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _jump(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _jump(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _jump(int delta) {
    if (_closed) return;
    final target = _index + delta;
    if (target < 0) return;
    if (target >= _items.length) {
      // 单剧模式（0.2.29）：只有一部剧，不拉取、不跳转。
      if (widget.singleDrama != null) return;
      // 已到末尾：继续拉取下一批，拉不到就停在当前页。
      if (_hasMore && !_loadingMore && !_loading) {
        unawaited(_load(more: true));
      }
      return;
    }
    if (_controller.hasClients) {
      _controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(color: Colors.black, child: _body()),
    );
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  Widget _header() => Container(
    color: Colors.black,
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    child: Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          tooltip: '返回',
        ),
        Expanded(child: _sourceLabel()),
      ],
    ),
  );

  Widget _sourceLabel() => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        _sources.isEmpty
            ? '暂无可用站源'
            : _sources.length > 1
            ? '全部站源'
            : _sources.first.name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Widget _body() {
    if (_sources.isEmpty) {
      return const Center(
        child: Text('暂无可用站源', style: TextStyle(color: Colors.white70)),
      );
    }
    if (_loading && _items.isEmpty) {
      // 首次拉流可能较慢（要经镜像域名抓取），给出明确文案而不是干转圈，
      // 让用户知道在加载、以及为什么慢。
      //
      // 0.2.27：切源时进一步显示"正在切换到「XX」站源…（已等待 N 秒）"，
      // 并给出 2 分钟兜底提示，避免用户以为卡死（真机反馈第 5 条）。
      final target = _switchingTo;
      if (target == null) {
        return const LoadingHint(message: '正在为你挑选短剧…', dark: true);
      }
      final seconds = _switchElapsed;
      if (_switchTimedOut) {
        return _SwitchHint(
          message: '切换到「$target」已等待 ${seconds}s，仍无响应',
          detail: '可下点下方按钮重试，或先切回其他站源',
          actionLabel: '重新加载',
          onAction: () => _reset(force: true, switchTo: target),
        );
      }
      return _SwitchHint(
        message: '正在切换到「$target」站源…',
        detail: '已等待 ${seconds}s，网络较慢时可能要等一会儿',
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error ?? '暂无视频',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => _load(), child: const Text('重试')),
          ],
        ),
      );
    }
    final pageView = PageView.builder(
      controller: _controller,
      scrollDirection: Axis.vertical,
      onPageChanged: _onPageChanged,
      // 「连播本剧」开启时禁用 PageView 自带翻页，改由外层手势统一处理
      // （向上滑 = 下一集，向下滑 = 上一集）。
      //
      // 注意：这里的条件必须与下面 `onVerticalDragEnd` 是否接管**完全一致**，
      // 否则会出现"禁用了自带翻页、却没人接管手势"的死锁——表现为滑不动。
      //
      // 0.2.26 修正：原先用 `_currentPageCanPlayNext`（依赖子页异步上报
      // "是否有下一集"）作为条件，导致首帧未上报时条件与手势接管不一致，
      // 出现"第一部要下滑才切下集、第二部上滑却回上一部剧"的错乱。
      // 改为只看 `_autoNextEpisode`，进入连播模式即稳定接管，不再随上报抖动。
      physics: _autoNextEpisode
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final drama = _items[index];
        final isCurrent = index == _index;
        return _FeedPage(
          // 统一使用值 key。
          // 注意：这里**不能**按"是否当前页"切换成 GlobalKey——
          // GlobalKey 在同一树中唯一，来回换 key 会让 Flutter 把上一个
          // State（含播放器）整体搬移过去，造成"标题变了视频没变"。
          key: ValueKey('feed-${drama.source}-${drama.id}'),
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          active: widget.active && isCurrent,
          autoNextEpisode: _autoNextEpisode,
          playerFactory: widget.playerFactory,
          videoBuilder: widget.videoBuilder,
          onToggleAutoNext: _toggleAutoNext,
          onFinished: () => _jump(1),
          onOpenDetail: () => _openDetail(drama),
          onEpisodeStateChanged: isCurrent ? _onPageEpisodeStateChanged : null,
          // 单剧模式（0.2.29）：起始集 / 本地文件模式 / 续播位置。
          // 只在单剧模式（第一页）生效；首页无限流保持原行为。
          initialEpisodeIndex: widget.singleDrama != null
              ? widget.initialEpisodeIndex
              : 0,
          initialPosition: widget.singleDrama != null
              ? widget.initialPosition
              : 0,
          localOnly: widget.singleDrama != null && widget.localOnly,
          mediaId: widget.singleDrama != null ? widget.mediaId : null,
          singleDrama: widget.singleDrama != null,
          // 预载（0.2.31）：把"下一部剧"传给当前页，供"连播下一部"模式预载。
          // 只在首页无限流、且当前页有下一部时有效（单剧模式无下一部）。
          nextDrama:
              widget.singleDrama == null &&
                  isCurrent &&
                  index + 1 < _items.length
              ? _items[index + 1]
              : null,
          autoNextDramaEnabled: widget.singleDrama == null && !_autoNextEpisode,
        );
      },
    );
    // 手势层**必须始终存在**，只切换是否接管滑动。
    //
    // 历史教训（对应问题 2、3）：这里曾经写成
    //   if (!_currentPageCanPlayNext) return pageView;
    //   return GestureDetector(child: pageView);
    // 即"需要接管时才套一层 GestureDetector"。
    // 后果是：点「连播本剧」后树的**层数发生变化**，Flutter 认为这是另一棵树，
    // 于是把 PageView 及其下所有 _FeedPage 的 State（含播放器）**全部销毁重建**——
    // 表现为"重新开始加载视频、加载不成功、无法上下滑动"，
    // 同时 PageView 位置归零，表现为"跳回列表第一部"。
    // 正确做法：树形结构恒定，只改 physics 与是否响应手势。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 只有「连播本剧」模式才接管手势（与上面 physics 条件保持一致）。
      onVerticalDragEnd: _autoNextEpisode ? _onVerticalDrag : null,
      child: pageView,
    );
  }

  void _toggleAutoNext() {
    if (_closed) return;
    setState(() => _autoNextEpisode = !_autoNextEpisode);
  }

  Future<void> _openDetail(Drama drama) async {
    if (!mounted) return;
    // 复用现有详情页（不修改其实现）。
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }
}

/// 站源切换加载提示（0.2.27 新增）。
///
/// 与通用 `LoadingHint` 的区别：带上站源名、已等待秒数，
/// 并在超时后提供「重新加载」按钮，避免用户以为卡死。
class _SwitchHint extends StatelessWidget {
  const _SwitchHint({
    required this.message,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _FeedBatch {
  const _FeedBatch(this.items, {this.hasMore = false, this.warning = ''});
  final List<Drama> items;
  final bool hasMore;
  final String warning;
}

/// 单个站源拉取失败的占位结果。
///
/// 并行请求时 `Future.wait` 只要有一个抛异常就会整体失败，
/// 因此把「失败」也当成一种正常返回值，让其他源的数据仍能显示。
class _SourceFeedFailure {
  const _SourceFeedFailure(this.message);
  final String message;
}

/// 子页向父级上报播放状态的签名。
///
/// [hasNext]：本页是否还有下一集（决定滑动是"切集"还是"翻下一部"）。
/// [playNext]：切到下一集的执行入口；没有下一集时为 null。
/// [hasPrev]：本页是否还有上一集（决定向上滑是"回上一集"还是"翻上一部"）。
/// [playPrev]：切到上一集的执行入口；没有上一集时为 null。
///
/// 之所以用回调而不是 GlobalKey：GlobalKey 在同一 Widget 树中必须唯一，
/// 若随"当前页"来回更换，Flutter 会搬移 State（含播放器）导致画面错乱。
typedef EpisodeStateReporter =
    void Function(
      bool hasNext, {
      Future<void> Function()? playNext,
      bool hasPrev,
      Future<void> Function()? playPrev,
    });

/// 单页：一个视频 + 播放控件 + 信息栏。
class _FeedPage extends StatefulWidget {
  const _FeedPage({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    required this.active,
    required this.autoNextEpisode,
    required this.onToggleAutoNext,
    required this.onFinished,
    required this.onOpenDetail,
    this.playerFactory,
    this.onEpisodeStateChanged,
    this.videoBuilder,
    this.initialEpisodeIndex = 0,
    this.initialPosition = 0,
    this.localOnly = false,
    this.mediaId,
    this.singleDrama = false,
    this.nextDrama,
    this.autoNextDramaEnabled = false,
  });

  final Drama drama;

  /// 上报"本页还能否切到下一集"，并附上切集入口，用于父级决定滑动语义。
  final EpisodeStateReporter? onEpisodeStateChanged;
  final AppRepository repository;
  final LocalStore store;
  final bool active;

  /// true = 播完自动播本剧下一集；false = 播完跳到下一部。
  final bool autoNextEpisode;
  final VoidCallback onToggleAutoNext;

  /// 当前剧播完且不需要连播本剧时回调（由父级滑到下一部）。
  final VoidCallback onFinished;
  final VoidCallback onOpenDetail;

  /// 测试用：注入假播放器。
  final Player Function()? playerFactory;

  /// 测试用：替换视频渲染层（见 [VerticalFeedScreen.videoBuilder]）。
  final Widget Function(Widget controls)? videoBuilder;

  /// 单剧模式（0.2.29）：起始集索引。
  final int initialEpisodeIndex;

  /// 单剧模式（0.2.29）：起始播放位置（秒），用于续播。
  final double initialPosition;

  /// 单剧模式（0.2.29）：true 时播放已下载的本地文件。
  final bool localOnly;

  /// 本地媒体 ID（0.6.0）：非空时进度写入 `store.saveMediaWatch`。
  final String? mediaId;

  /// 单剧模式（0.2.29）：true 时隐藏"连播本剧"开关（只有一部剧，无意义）。
  final bool singleDrama;

  /// 预载（0.2.31）：下一部剧（由父级传入，仅首页无限流有值）。
  /// "连播下一部"模式下用它预载下一部的第 1 集。
  final Drama? nextDrama;

  /// 预载（0.2.31）：当前是否处于"连播下一部"模式。
  /// true 时预载 [nextDrama] 第 1 集，false 时预载本剧下一集。
  final bool autoNextDramaEnabled;

  @override
  State<_FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<_FeedPage> with WidgetsBindingObserver {
  Player? _player;
  VideoController? _video;
  PlayerInteractions? _interactions;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  DramaDetail? _detail;
  PlaybackPlan? _plan;
  String? _error;
  bool _loading = true;
  bool _ready = false;
  bool _panelOpen = false;
  bool _controlsVisible = true;
  int _generation = 0;
  int _episodeIndex = 0;
  int _quality = 0;
  double _speed = 1;
  double? _seekValue;
  Timer? _hideTimer;
  bool _closed = false;

  /// 当前剧是否已追剧（0.2.26 新增）。
  ///
  /// 与 `store.isFavorite` 同步；在 initState / didUpdateWidget / 点击后刷新。
  bool _followed = false;

  /// 预载器（0.2.31 新增，用户要求）。
  ///
  /// 复用旧播放器同一套 `PlaybackPreloader`（JC-0002：不重复造轮子）。
  /// 两种模式：
  /// - 「连播本剧」→ 预载本剧下一集；
  /// - 「连播下一部」→ 预载下一部剧的第 1 集（需父级传入 `nextDrama`）。
  /// 默认常开（用户 Q3：不加开关，不提供关闭入口）。
  late final PlaybackPreloader _preloader;

  /// 观看记录保存定时器。
  ///
  /// 旧播放器（`player_screen.dart`）用 5 秒定时 + 暂停/退出时强制保存，
  /// 让首页竖滑流播放的剧也能进入「最近观看」。这里沿用同一策略，
  /// 保证两套播放器的观看记录行为一致。
  Timer? _saveTimer;

  /// 上一次已保存的进度指纹，用于去重，避免频繁写盘。
  String? _savedProgressKey;

  /// 观看记录保存失败提示（与旧播放器一致的容错）。
  String? _saveWarning;

  /// 播放健康检查（0.6.0，迁移自老播放器 `player_screen.dart`）。
  ///
  /// 老播放器每秒检测一次"是否卡住"（位置 20 秒不前进且处于播放中），
  /// 卡住则自动恢复（切备用线路 / 重新解析地址）。
  /// 新播放器此前**完全没有**这个能力，网络抖动时会一直黑屏等下去，
  /// 用户只能手动切集绕过。这里补齐同一套能力。
  final _health = PlaybackHealth();

  /// 健康检查定时器（每秒一次）。
  Timer? _healthTimer;

  /// 自动恢复尝试计数与"是否已刷新过地址"（与老播放器同一套策略）。
  final _recovery = PlaybackRecovery();

  /// 应用是否在前台。后台时不判定"卡住"，否则会被误判。
  bool _foreground = true;

  /// 横屏/全屏模式：用独立的全屏层铺满整个屏幕（含状态栏区域），
  /// 并隐藏竖滑流的所有非播放界面（AppBar、剧名、简介、底栏等）。
  /// 注意：这里不是"把系统屏幕转一下"，而是真正进入全屏观看。
  bool _landscape = false;

  /// 全屏层是否已作为**路由**打开（0.2.28 方案 D）。
  ///
  /// 0.2.27 及之前用 `Overlay.insert(OverlayEntry)` 实现全屏层，
  /// 但 `OverlayEntry` **不属于任何 Navigator 路由**，其中的 `PopScope`
  /// 收不到系统返回键事件 → 真机表现为"全屏按返回直接回桌面"（修复无效）。
  ///
  /// 0.2.28 改为 `Navigator.push` 一个透明全屏路由：
  /// 它位于 Navigator 路由栈中，`PopScope` 能正常拦截返回键，
  /// 实现"返回键 / 右上角按钮 / 手势"三种方式都能退出全屏。
  bool _fullscreenRouteOpen = false;

  /// 打开全屏路由所用的 Navigator 引用。
  ///
  /// 进入全屏时保存，便于 `dispose` 中安全关闭路由
  /// （dispose 阶段 `context` 已失效，不能再用 `Navigator.maybeOf(context)`）。
  NavigatorState? _fullscreenNavigator;

  /// 全屏层的重建入口（路由内内容通过它同步最新状态）。
  final _fullscreenRevision = ValueNotifier<int>(0);

  /// 竖屏主界面进度条的轻量重建入口（0.3.1）。
  ///
  /// 进度每秒变化多次，若整页 `setState` 会把整个手势层 + 按钮 + 选集网格
  /// 全部重建，代价很高。改用这个 `ValueNotifier` 只让进度条本身重建。
  final _tick = ValueNotifier<int>(0);

  /// 上次刷新全屏层的时间，用于节流（0.3.1）。
  DateTime _lastFullscreenRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放器操作串行队列（0.3.1 性能修复）。
  ///
  /// 与旧播放器 `player_screen.dart` 的 `_serialize` 语义一致：
  /// `player.open` / `setRate` / `setProperty` 等原生调用若并发执行，
  /// 会在 media_kit 内部互相打断（表现为卡顿、音画不同步、切集闪回）。
  /// 全部排进同一条 Future 链，保证同一时刻只有一个原生操作在跑。
  Future<void> _operations = Future<void>.value();

  /// 视频宽高比（宽/高）。0 表示尚未探测到。
  /// 只有横屏视频（宽>高）才显示「横屏」切换按钮，竖屏视频本身就不需要。
  double _aspectRatio = 0;

  /// 是否为横屏视频（16:9 之类）。宽高比未探到时按竖屏处理（不显示按钮）。
  bool get _wideVideo => _aspectRatio > 1.05;

  /// 首次打开时的续播位置（秒），用一次后清空（0.2.29）。
  ///
  /// 只有在单剧模式、且调用方传入了非零位置时才有值。
  /// 消费一次即置空，避免换集 / 重试时反复跳到同一位置。
  double _pendingStart = 0;

  /// 滑走时记下的播放位置，滑回来重建播放器时据此续播（0.3.1）。
  ///
  /// 因为滑走的页面现在会**释放播放器**，重建时若不带上位置就会从头播。
  Duration _resumeFrom = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _quality = preferences.quality;
    // 单剧模式（0.2.29）：从指定集开始播放（详情页/下载页点的是第几集）。
    _episodeIndex = widget.initialEpisodeIndex;
    _pendingStart = widget.initialPosition;
    // 追剧按钮初始状态（0.2.26 新增）。
    _followed = widget.store.isFavorite(widget.drama.id);
    // 预载器（0.2.31）：默认常开（用户 Q3）。
    _preloader = PlaybackPreloader(widget.repository);
    if (widget.active) _prepare();
  }

  /// 播放器操作串行队列（0.3.1）。
  ///
  /// 把操作挂到同一条 Future 链上，前一个失败也不影响后续执行
  /// （`catchError` 吞掉异常，与旧播放器 `player_screen.dart` 一致）。
  ///
  /// 0.3.5 修正：如果播放器已被释放，队列里还没执行的操作直接作废。
  /// 原因是"滑走页面即释放播放器"（0.3.1 性能修复）与"换集加载"会撞车：
  /// 已经排队的 `player.open()` 手里拿的是**已被释放的播放器**，
  /// 而 media_kit 对已释放实例调用 `open` 走的是 `assert`
  /// （release 包中断言被移除），于是既不报错也不播放，
  /// 真机表现为**全黑、无声、也没有加载提示**。
  Future<void> _serialize(Future<void> Function() operation) {
    final released = _playerReleased;
    Future<void> run() async {
      if (_closed || _playerReleased != released) return;
      await operation();
    }

    final next = _operations.catchError((Object _) {}).then((_) => run());
    _operations = next;
    return next;
  }

  /// 是否已进入"释放播放器"流程（页面被滑走或销毁）。
  ///
  /// 与 [_closed] 的区别：[_closed] 只在 `dispose` 时置位，
  /// 而本标记在 `didUpdateWidget` 被滑走时就置位，
  /// 用于阻止已滑走的页面继续加载、也就不会在已释放实例上操作。
  bool _playerReleased = false;

  /// 判断某次异步加载是否仍然有效：页面未销毁、播放器未被释放，
  /// 且捕获到的播放器实例仍是当前实例。
  ///
  /// ⚠️ 0.3.5 事故教训：**绝不要把"加载任务代次"（[_generation]）与播放器状态混在一起判断**。
  /// 0.3.5 首次实现里它和另一个"播放器代次"计数器做了相等比较，
  /// 两个计数器互不相关（首次加载 1 != 0），于是**每一次加载都被误判为过期**、
  /// 静默返回且不置 `_loading`，导致所有视频永久卡在"正在加载视频…"。
  bool _attemptAlive(Player player) =>
      !_closed && !_playerReleased && identical(_player, player);

  /// 给"曾被滑走"的页面一次自愈机会：重新创建播放器后再加载。
  ///
  /// 不做这一步的话，页面被滑走时放弃的加载会永久停住，
  /// 用户只能靠"切到别的集再切回来"绕过（0.3.5 前的真机现象）。
  Future<void> _resumeAfterRelease() async {
    if (_closed || !_playerReleased) return;
    _playerReleased = false;
    _ready = false;
    await _prepare(force: true);
  }

  /// 自动恢复（0.6.0，迁移自老播放器）。
  ///
  /// 触发条件：健康检查判定"播放中但位置长时间不前进"。
  /// 策略与老播放器一致（`PlaybackRecovery`）：
  /// 1. 有计划且有备用线路 → 切备用线路；
  /// 2. 否则首次 → 重新解析播放地址（刷新）；
  /// 3. 累计超过 3 次 → 停止，展示错误让用户手动重试。
  ///
  /// 恢复后从**当前进度**续播，不让用户回到片头。
  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        _playerReleased ||
        !widget.active ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    final position = _player?.state.position ?? Duration.zero;
    // 本地文件没有备用线路可切，直接停止，避免无意义地反复重试。
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    if (action == PlaybackRecoveryAction.stop) {
      if (!mounted || _closed) return;
      setState(() {
        _error = current.local
            ? '本地视频播放中断，请返回重试。'
            : '播放已中断，请点击重试。';
      });
      _refreshFullscreen(immediate: true);
      return;
    }
    // 记录续播点，`_prepare` 会通过 `_takeStartPosition` 取用。
    _resumeFrom = position;
    _health.reset();
    final message = switch (action) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      PlaybackRecoveryAction.stop => '',
    };
    if (mounted && !_closed && message.isNotEmpty) _toast(message);
    await _prepare(force: true);
  }

  /// 应用前后台切换（0.6.0）。
  ///
  /// 后台时不判定"卡住"（`_health.reset()`），否则回到前台会被误判为卡死并触发恢复。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _health.reset();
  }

  /// 取出并清空待续播位置（只在首次打开时返回非零值）。
  ///
  /// 优先取 [ _resumeFrom ]（滑走再滑回时记录的位置，0.3.1），
  /// 其次取 [ _pendingStart ]（单剧模式调用方传入的续播位置，0.2.29）。
  Duration? _takeStartPosition() {
    final resume = _resumeFrom;
    _resumeFrom = Duration.zero;
    if (resume > Duration.zero) return resume;
    final seconds = _pendingStart;
    _pendingStart = 0;
    if (seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// 取本地已下载文件（0.2.29，下载页单剧模式）。
  ///
  /// 与旧播放器 `PlaybackLoader(localOnly: true)` 语义一致：
  /// 找不到本地文件时抛 `AppFailure`，由调用方展示错误与重试。
  Future<PlaybackPlan> _resolveLocal(DramaDetail detail, int index) async {
    final plan = await widget.repository.localPlayback(
      detail.drama,
      detail.episodes[index],
    );
    if (plan == null || !plan.local) {
      throw AppFailure('本地视频不可用，请重新下载。', code: 'local_media');
    }
    return plan;
  }

  /// 同步预载目标（0.2.31，用户要求：默认常开，两种模式）。
  ///
  /// 触发条件（与旧播放器一致的时机策略）：
  /// - 当前页可见、已就绪、正在播放且缓冲充足；
  /// - 播放位置过半或距结束不足 45 秒（说明快看完了，值得提前准备）。
  ///
  /// 预载目标：
  /// - 「连播本剧」→ 本剧下一集；
  /// - 「连播下一部」→ 下一部剧的第 1 集（需父级传入 `nextDrama`）。
  ///
  /// 不预载的情况：本地文件模式、单剧模式、加载中/出错、当前不在播放。
  void _syncPreload() {
    if (_closed) return;
    // 本地文件、单剧模式不预载（本地文件无网络解析成本，单剧无下一部）。
    if (widget.localOnly) {
      _preloader.clear();
      return;
    }
    final player = _player;
    final detail = _detail;
    if (player == null ||
        detail == null ||
        !_ready ||
        _loading ||
        _error != null ||
        !widget.active) {
      _preloader.clear();
      return;
    }
    final state = player.state;
    if (!state.playing || state.buffering) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    // 缓冲不足 / 刚开始播放时不预载，避免与当前播放抢带宽。
    if (duration <= 0 ||
        position < 2000 ||
        (position < duration ~/ 2 && duration - position > 45000)) {
      return;
    }
    // 弱网保护（0.5.0）：缓冲余量偏低时**暂停预载**，把带宽让给当前播放。
    //
    // 背景：用户实测"开 VPN 就卡"。视频请求经系统代理绕道节点（见
    // `native/core/proxy_system.go`），带宽与稳定性都不如直连；而预载一次
    // 最多会拉 4 MB（`native/core/app_preload.go` 的 `nativePreloadLimit`），
    // 与正在播放的流争抢同一条代理通道，会把缓冲打空 → 抽帧卡顿。
    // 因此这里以"缓冲余量"为准：余量不足就先不预载，等缓过来再预载。
    // 阈值取 30 秒（远低于播放器 32 MB 前向缓存能撑的时长），
    // 只在真正吃紧时生效，正常网络下行为不变。
    final buffered = state.buffer.inMilliseconds;
    if (buffered > 0 && buffered < 30000) {
      _preloader.pause();
      return;
    }
    // 「连播本剧」优先：还有下一集就预载下一集。
    if (widget.autoNextEpisode || !widget.autoNextDramaEnabled) {
      if (_episodeIndex + 1 < detail.episodes.length) {
        _preloader.prepare(
          detail.drama,
          detail.episodes[_episodeIndex + 1],
          quality: _quality,
        );
        return;
      }
    }
    // 「连播下一部」：预载下一部剧的第 1 集。
    final next = widget.nextDrama;
    if (next != null) {
      unawaited(_preloadNextDrama(next));
      return;
    }
    _preloader.clear();
  }

  /// 预载下一部剧的第 1 集（需要先拿到其剧集列表）。
  Future<void> _preloadNextDrama(Drama next) async {
    try {
      final detail = await widget.repository.detail(next);
      if (_closed || detail.episodes.isEmpty) return;
      _preloader.prepare(
        detail.drama,
        detail.episodes.first,
        quality: _quality,
      );
    } catch (_) {
      // 预载失败不影响主流程（切过去时会重新解析）。
    }
  }

  /// 只为当前页创建播放器，避免同时持有多个实例。
  bool _ensurePlayer() {
    if (_player != null) return true;
    // 0.3.5：只有当页面**当前可见**、且没有处于"已释放等待重建"状态时才建。
    // `_playerReleased` 由 `_releasePlayer` 置位；页面重新可见时
    // `didUpdateWidget` 会先调用 `_resumeAfterRelease()` 把它清掉再加载，
    // 这样"滑走时放弃的加载"不会永久停住。
    if (!widget.active || _closed || _playerReleased) return false;
    final player =
        widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
          ),
        );
    _player = player;
    // 测试环境注入视频层时不去创建 VideoController：
    // 它会调用原生 platform channel，在测试里必然失败并污染用例结果。
    _video = widget.videoBuilder == null ? VideoController(player) : null;
    final interactions = PlayerInteractions(
      player: player,
      available: () =>
          !_closed &&
          !_loading &&
          _error == null &&
          widget.active &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onFullscreen: () {},
      // 上下滑动切集（0.2.31，用户方案 B：只切集、不切剧）。
      //
      // 说明：这里原先返回空字符串，等于「上下滑切集」从未接通。
      // 竖滑主界面靠外层 PageView 切集，全屏是独立路由、不受 PageView 影响，
      // 因此全屏里上下滑必须由本回调承担（用户反馈第 1 条）。
      // [direction] 1 = 上滑（下一集），-1 = 下滑（上一集）。
      onEpisode: _swipeEpisode,
      onSeek: _seekTo,
    )..addListener(_interactionChanged);
    _interactions = interactions;
    // 观看记录：定时保存（5 秒一次，与旧播放器一致）。
    // 暂停、切集、切页、退出时另有强制保存，保证进度不丢。
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_saveProgress()),
    );
    // 健康检查（0.6.0）：每秒检测是否卡住，卡住则自动恢复。
    // 只在"播放中 + 前台 + 无错误"时判定，避免把暂停/缓冲误判为卡死。
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed ||
          _playerReleased ||
          !widget.active ||
          _loading ||
          _error != null) {
        return;
      }
      final current = _player;
      if (current == null) return;
      if (_health.stalled(
        position: current.state.position,
        playing: current.state.playing,
        foreground: _foreground,
        now: DateTime.now(),
      )) {
        unawaited(_recover());
      }
    });
    for (final stream in [
      player.stream.position,
      player.stream.duration,
      player.stream.buffer,
      player.stream.playing,
      player.stream.buffering,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          // 进度 tick 不再整体 setState（0.3.1 性能修复）。
          //
          // 这里每秒会触发多次，而真正需要跟着走的只有：
          // - 全屏层（独立 Overlay，走 revision 通知，见 _refreshFullscreen）；
          // - 竖屏主界面的进度条（走 _tick 轻量通知，只重建进度条本身）。
          // 此前无条件 `setState(() {})` 会重建整页（含手势层、选集按钮、
          // 选集网格等），是卡顿的直接来源之一。
          _refreshFullscreen();
          _tick.value++;
          // 预载（0.2.31）：位置/缓冲变化时评估是否需要提前准备下一集/下一部。
          _syncPreload();
        }),
      );
    }
    // 探测视频真实分辨率，决定是否提供「横屏」按钮。
    // 优先用 aspect（显示宽高比，最可靠），其次 dw/dh、w/h。
    // 注意：很多流在首帧前这些值都是 null，属于正常情况，
    // 不影响横屏按钮使用（按钮常显，未知比例时直接切换）。
    _subscriptions.add(
      player.stream.videoParams.listen((parameters) {
        _applyVideoParams(parameters);
      }),
    );
    _subscriptions.add(
      player.stream.playing.listen((playing) {
        if (playing) _scheduleHide();
      }),
    );
    _subscriptions.add(
      player.stream.completed.listen((completed) {
        if (!completed || _closed || _loading || _error != null) return;
        final detail = _detail;
        // 默认连播下一部；开启后连播本剧下一集，没有下一集再跳下一部。
        if (widget.autoNextEpisode &&
            detail != null &&
            _episodeIndex + 1 < detail.episodes.length) {
          unawaited(_playEpisode(_episodeIndex + 1));
        } else {
          widget.onFinished();
        }
      }),
    );
    return true;
  }

  /// 记录视频真实宽高比。
  ///
  /// 依次尝试：aspect（显示比例）→ dw/dh → w/h。
  /// 全部拿不到时保持 0（未知），此时横屏按钮仍然可用。
  void _applyVideoParams(VideoParams parameters) {
    if (!mounted || _closed) return;
    double ratio = parameters.aspect ?? 0;
    if (ratio <= 0) {
      final width = parameters.dw ?? parameters.w ?? 0;
      final height = parameters.dh ?? parameters.h ?? 0;
      if (width > 0 && height > 0) ratio = width / height;
    }
    if (ratio <= 0) return;
    if (ratio > 100 || ratio < 0.01) return; // 明显异常，忽略
    if ((ratio - _aspectRatio).abs() < 0.01) return;
    setState(() => _aspectRatio = ratio);
    _refreshFullscreen();
  }

  /// 播放开始后主动读一次分辨率。
  ///
  /// `videoParams` 流在某些平台只在参数“变化”时推送一次，
  /// 可能早于本组件订阅，因此这里补一次主动读取。
  void _refreshAspectRatio() {
    final parameters = _player?.state.videoParams;
    if (parameters != null) _applyVideoParams(parameters);
  }

  @override
  void didUpdateWidget(covariant _FeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      // 成为当前页：重新上报能否切下一集，避免沿用上一页的状态。
      _reportEpisodeState();
      if (_ready && _error == null) {
        _playerReleased = false;
        unawaited(_player?.play());
        _showControls();
      } else if (_playerReleased) {
        // 0.3.5：本页曾经被滑走并放弃了一次加载，这里重新建播放器接着加载，
        // 不需要用户"切到别的集再切回来"来绕过。
        unawaited(_resumeAfterRelease());
      } else {
        _prepare();
      }
    } else if (!widget.active && oldWidget.active) {
      // 被滑走：先把观看进度落盘，再**彻底释放播放器**（0.3.1 性能修复）。
      //
      // 为什么必须释放（用户反馈"播放卡顿，尤其开倍速后"）：
      // `PageView` 会保留已滑过的页面，而播放器此前只在 `dispose` 才释放，
      // 于是每滑过一个视频就多留一个原生解码器 + 网络缓冲。滑十几个后，
      // 内存与 CPU 被十几个播放器瓜分，表现为越来越卡（倍速时更明显）。
      unawaited(_saveProgress());
      _interactions?.cancel();
      // 清掉挂起的预载任务，避免和别的页面抢带宽（0.3.1）。
      _preloader.clear();
      // 先记下当前播放位置，回来时据此续播（否则会从第 0 秒重新开始）。
      _resumeFrom = _player?.state.position ?? Duration.zero;
      _releasePlayer();
    }
  }

  /// 释放当前播放器与相关资源（切页 / 销毁共用）。
  ///
  /// 释放后可再次通过 `_ensurePlayer()` 重建；[ _resumeFrom ] 已记录位置。
  ///
  /// 0.3.5：释放时置位 [_playerReleased] 并换掉操作队列，
  /// 让**已经排队但还没执行**的操作全部作废 —— 这是"黑屏卡住"的根因修复：
  /// 旧实现只 `dispose` 播放器，队列里的 `player.open()` 仍会执行，
  /// 而 media_kit 对已释放实例的操作在 release 包中静默失败。
  void _releasePlayer() {
    _playerReleased = true;
    // 丢弃旧队列：仍排队的操作会因 [_playerReleased] 已变而跳过。
    _operations = Future<void>.value();
    _saveTimer?.cancel();
    _saveTimer = null;
    // 取消所有播放器流订阅，避免释放后回调访问已失效对象。
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _interactions?.removeListener(_interactionChanged);
    _interactions?.dispose();
    _interactions = null;
    // 播放器已释放：健康检查定时器必须一并停掉，
    // 否则它会继续读取已释放实例的 state（0.6.0）。
    _healthTimer?.cancel();
    _healthTimer = null;
    _health.reset();
    final player = _player;
    _player = null;
    _video = null;
    // 重置就绪/加载态：下次 `_prepare()` 会重新走一遍。
    _ready = false;
    _plan = null;
    _loading = true;
    if (player != null) unawaited(player.dispose());
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    _healthTimer = null;
    // 退出前先把观看进度落盘（与旧播放器 dispose 行为一致）。
    unawaited(_saveProgress());
    _saveTimer?.cancel();
    _saveTimer = null;
    _generation++;
    _hideTimer?.cancel();
    // 必须先关闭全屏路由，否则其 builder 会在本 State 销毁后继续访问已释放字段。
    if (_fullscreenRouteOpen) {
      _fullscreenRouteOpen = false;
      // 不能在 dispose 里用 `Navigator.maybeOf(context)`（context 已失效），
      // 因此这里关闭时用进入全屏时保存的 navigator 引用。
      final navigator = _fullscreenNavigator;
      if (navigator != null && navigator.canPop()) {
        navigator.pop();
      }
    }
    _fullscreenNavigator = null;
    _fullscreenRevision.dispose();
    _tick.dispose();
    // 若离开时还锁着横屏，必须恢复竖屏并显示系统栏，否则整个应用会一直横着。
    if (_landscape) {
      _landscape = false;
      unawaited(
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _releasePlayer();
    // 预载器释放（0.2.31）：取消挂起请求并释放已预取的会话，避免会话泄漏。
    _preloader.dispose();
    super.dispose();
  }

  void _interactionChanged() {
    if (!mounted) return;
    final boosting = _interactions?.boosting ?? false;
    if (boosting) {
      // 加速中：立刻把完整控件层收起来，只留中央的「3 倍速 · 松开恢复」提示。
      // 注意：中央提示本身是**独立层**（不受控件显隐影响），
      // 所以这里隐藏控件层不会连带把提示藏掉。
      _hideTimer?.cancel();
      if (_controlsVisible) {
        setState(() => _controlsVisible = false);
        _refreshFullscreen();
      }
      return;
    }
    // 松开加速后：**不再弹出整套控件**。
    //
    // 0.2.26 修正（用户反馈）：原先这里只要 feedback 非空就 `_showControls()`，
    // 导致"松手后所有控件都显示出来"（进度条、剧名、简介全部弹出）。
    // 用户期望：松手后只恢复正常倍速，控件保持原状（不主动弹出）。
    // 因此这里不再调用 `_showControls()`，只刷新一次全屏层（让倍速显示恢复）。
    _refreshFullscreen();
  }

  /// 本页是否还能切到下一集。
  ///
  /// 供父级在「连播本剧」模式下判断滑动语义：
  /// 还有下一集时，向下滑动应切集而非翻到下一部剧。
  bool get canPlayNextEpisode {
    if (_closed) return false;
    final detail = _detail;
    if (detail == null) return false;
    return _episodeIndex + 1 < detail.episodes.length;
  }

  /// 本页是否还能切到上一集。
  ///
  /// 供父级判断向上滑动的语义：还有上一集时应回到本剧上一集，
  /// 而不是直接跳到上一部剧（对应问题 3）。
  bool get canPlayPrevEpisode {
    if (_closed) return false;
    final detail = _detail;
    if (detail == null) return false;
    return _episodeIndex > 0;
  }

  /// 播放本剧下一集（供父级滑动调用）。
  Future<void> playNextEpisode() async {
    if (!canPlayNextEpisode) return;
    await _playEpisode(_episodeIndex + 1);
  }

  /// 播放本剧上一集（供父级向上滑动调用）。
  Future<void> playPrevEpisode() async {
    if (!canPlayPrevEpisode) return;
    await _playEpisode(_episodeIndex - 1);
  }

  /// 上下滑动切集（0.2.31，用户方案 B：只切集、不切剧）。
  ///
  /// [direction] 1 = 上滑（下一集），-1 = 下滑（上一集）。
  ///
  /// 语义（用户确认 Q1=B）：
  /// - 只在本剧内切集，**不切剧**；到边界只给提示。
  /// - 返回值是给 `PlayerInteractions` 的轻提示文案。
  String _swipeEpisode(int direction) {
    if (_closed || !widget.active) return '';
    if (direction > 0) {
      if (canPlayNextEpisode) {
        unawaited(playNextEpisode());
        return '下一集';
      }
      return '已经是最后一集了';
    }
    if (canPlayPrevEpisode) {
      unawaited(playPrevEpisode());
      return '上一集';
    }
    return '已经是第一集了';
  }

  void _showControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
      // 用户操作，跳过节流立即刷新（0.3.1）。
      _refreshFullscreen(immediate: true);
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_closed || _panelOpen) return;
    // 加速中不自动隐藏（松开后由 _interactionChanged 恢复显示与计时）。
    if (_interactions?.boosting ?? false) return;
    if (!(_player?.state.playing ?? false)) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _closed || _panelOpen) return;
      if (_seekValue != null) return;
      if (!(_player?.state.playing ?? false)) return;
      if (_interactions?.boosting ?? false) return;
      setState(() => _controlsVisible = false);
      // 用户操作，跳过节流立即刷新（0.3.1）。
      _refreshFullscreen(immediate: true);
    });
  }

  void _tap() {
    if (_interactions?.suppressTap ?? false) return;
    setState(() => _controlsVisible = !_controlsVisible);
    _refreshFullscreen();
    _scheduleHide();
  }

  void _togglePlayback() {
    final player = _player;
    if (player == null || _closed || _loading || _error != null) return;
    _interactions?.cancel();
    final willPlay = !player.state.playing;
    unawaited(player.playOrPause());
    // 暂停时立刻落盘，避免用户暂停后直接退出导致进度丢失。
    if (!willPlay) unawaited(_saveProgress());
    _showControls();
  }

  Future<void> _seekTo(Duration position) async {
    final player = _player;
    if (player == null || _closed) return;
    await player.seek(position);
    _showControls();
  }

  /// 保存观看记录，使竖滑流播放的剧也进入「最近观看」。
  ///
  /// 旧播放器（`player_screen.dart` 的 `_saveProgress`）是唯一的写入者，
  /// 因此竖滑流此前**完全不会**产生观看记录。这里复用同一套语义：
  /// - 只保存当前页、且已经解析出剧集信息的情况；
  /// - 位置小于 0.1 秒不保存（避免点开即存）；
  /// - 用 [position] + [duration] + 集号 组成指纹去重，避免频繁写盘；
  /// - 失败时给出提示，但不打断播放。
  Future<void> _saveProgress() async {
    if (_closed) return;
    final detail = _detail;
    final player = _player;
    if (detail == null || player == null) return;
    if (!widget.active) return;
    final index = _episodeIndex.clamp(0, detail.episodes.length - 1);
    final position = player.state.position.inMilliseconds / 1000;
    final duration = player.state.duration.inMilliseconds / 1000;
    if (position < .1) return;
    final key = '${detail.drama.id}:$index:$position:$duration';
    if (_savedProgressKey == key && _saveWarning == null) return;
    final epoch = widget.store.profileEpoch;
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(detail.drama),
      episode: detail.episodes[index].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      // 0.6.0：本地媒体（mediaId 非空）写入**独立**的本地媒体进度存储，
      // 与老播放器 `player_screen.dart` 的 `saveMediaWatch` 语义一致。
      // 混入普通观看记录会污染「最近观看」，因此必须分开。
      final mediaId = widget.mediaId;
      if (mediaId != null) {
        await widget.store.saveMediaWatch(mediaId, entry);
      } else {
        await widget.store.saveWatch(entry);
      }
      if (widget.store.profileEpoch != epoch) return;
      _savedProgressKey = key;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看记录尚未保存，请检查存储空间后重试。');
      }
    }
  }

  /// 上报"本页还能否切到下一集"给父级，并附上切集入口。
  ///
  /// 只在当前页（active）时上报，避免预加载的非当前页覆盖状态。
  void _reportEpisodeState() {
    if (!widget.active) return;
    final hasNext = canPlayNextEpisode;
    final hasPrev = canPlayPrevEpisode;
    widget.onEpisodeStateChanged?.call(
      hasNext,
      playNext: hasNext ? playNextEpisode : null,
      hasPrev: hasPrev,
      playPrev: hasPrev ? playPrevEpisode : null,
    );
  }

  Future<void> _playEpisode(int index) async {
    final detail = _detail;
    if (_closed || detail == null) return;
    if (index < 0 || index >= detail.episodes.length) return;
    // 换集前先把当前集的进度存下来，否则切走就丢。
    await _saveProgress();
    // 0.3.5：等待落盘期间页面可能已被滑走（播放器已释放）。
    // 此时若继续按老流程走，会在已释放的播放器上加载，最终黑屏；
    // 这里改为把状态复位，交给 `_resumeAfterRelease()`（滑回来时）重新加载。
    if (_closed || _playerReleased) return;
    _episodeIndex = index;
    _ready = false;
    // 预载（0.2.31）：换集时 `_prepare` 里会先 `take()` 取走目标集的预载结果，
    // 命中则直接复用；未命中则正常解析。此处无需额外 clear。
    await _prepare(force: true);
  }

  Future<void> _prepare({bool force = false}) async {
    if (_closed) return;
    if (!_ensurePlayer()) {
      // 0.3.5：拿不到播放器时不能静默退出，否则页面会停在"既不加载也不报错"。
      // 只有"页面已被滑走/销毁"属于正常停止，此时不动状态，等滑回来重试。
      if (!_closed && !_playerReleased && mounted) {
        setState(() {
          _loading = false;
          _error = '播放器未能启动，请返回上一集重试';
        });
      }
      return;
    }
    final player = _player;
    if (player == null) return;
    if (_ready && !force) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = _detail ?? await widget.repository.detail(widget.drama);
      // 0.3.5：除代次外还要确认播放器实例没被替换/释放
      // （滑走页面会释放播放器，此时继续加载就是在操作已释放的实例）。
      if (!_attemptAlive(player)) return;
      if (detail.episodes.isEmpty) {
        throw AppFailure('该剧暂无可用剧集');
      }
      final index = _episodeIndex.clamp(0, detail.episodes.length - 1);
      final previous = _plan;
      // 预载命中（0.2.31）：若之前已提前解析好这一集，直接复用，省一次网络解析。
      // 匹配失败时返回 null，走正常解析路径。
      final prepared = widget.localOnly
          ? null
          : _preloader.take(
              detail.drama,
              detail.episodes[index],
              quality: _quality,
            );
      // 单剧模式的本地文件模式（0.2.29，下载页）：
      // 用 `localPlayback` 取已下载的本地文件，而不是拉在线流。
      // 两者返回的都是 `PlaybackPlan`，后续处理完全一致
      // （`plan.local` 为 true 时下面会走 file/crypto/data 协议白名单）。
      final plan =
          prepared ??
          (widget.localOnly
              ? await _resolveLocal(detail, index)
              : await widget.repository.resolve(
                  detail.drama,
                  detail.episodes[index],
                  quality: _quality,
                ));
      if (!_attemptAlive(player)) {
        // 页面已不可用：把刚解析出来的会话还回去，避免会话泄漏。
        unawaited(widget.repository.release(plan.session));
        return;
      }
      if (plan.url.isEmpty) {
        throw AppFailure(widget.localOnly ? '本地视频不可用，请重新下载。' : '站源未返回播放地址，请重试');
      }
      // 与现有播放器保持一致：设置协议白名单、解密密钥与重试参数。
      // 所有原生调用串行执行（0.3.1），避免并发打断导致卡顿。
      await _serialize(() async {
        final platform = player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
          // 弱网缓冲策略（0.5.0）。
          //
          // 背景：用户实测"开 VPN 就卡"，根因是视频请求全部绕道代理节点
          // （Go 原生核心会读系统代理，见 `native/core/proxy_system.go`），
          // 多一跳且节点质量不稳定 → 缓冲容易被抖动打空 → 表现为抽帧卡顿。
          // 这里做两件事，都不改变解码/渲染方式、也不影响音调：
          // 1. 关闭磁盘缓存，改用内存缓存：弱网下避免额外磁盘 IO 拖慢取流；
          // 2. 加大流层缓冲：对代理带来的抖动更有容忍度。
          // 属性不受支持时静默忽略，绝不影响播放。
          for (final entry in const {
            'cache-on-disk': 'no',
            'stream-buffer-size': '524288',
          }.entries) {
            try {
              await platform.setProperty(entry.key, entry.value);
            } catch (_) {
              // 忽略：仅属调优，失败不构成错误。
            }
          }
        }
      });
      if (!_attemptAlive(player)) return;
      _detail = detail;
      _plan = plan;
      _episodeIndex = index;
      // 详情就绪后上报，让父级知道本页还能否切下一集（决定滑动语义）。
      _reportEpisodeState();
      // 续播位置（0.2.29）：只有首次打开、且传入了非零位置时才生效；
      // 换集时 `_playEpisode` 会把 `_pendingStart` 清空，避免每集都跳。
      final start = _takeStartPosition();
      await _openMedia(player, plan, start);
      // 0.3.5：open 之后再次确认播放器仍然有效
      // （用户可能在加载中滑走页面，此时播放器已被释放）。
      if (!_attemptAlive(player)) return;
      await _interactions?.applySpeed();
      if (!_attemptAlive(player)) return;
      if (previous != null && previous.session != plan.session) {
        unawaited(widget.repository.release(previous.session));
      }
      setState(() {
        _loading = false;
        _ready = true;
        _controlsVisible = true;
      });
      // 加载成功：复位健康检查与恢复计数（0.6.0）。
      // 不复位的话，上一次的失败计数会累计，导致本次偶发卡顿直接判为"停止"。
      _health.reset();
      _recovery.reset();
      // 就绪是重要状态切换，跳过节流立即刷新（0.3.1）。
      _refreshFullscreen(immediate: true);
      _scheduleHide();
      // 兜底：某些平台 videoParams 流不会补发，这里主动读一次分辨率。
      _refreshAspectRatio();
    } catch (error) {
      if (_closed || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error is AppFailure ? error.message : error.toString();
      });
      _refreshFullscreen(immediate: true);
    }
  }

  /// 真正把媒体交给播放器（0.3.5 独立成方法，便于加"释放护栏"）。
  ///
  /// 关键点：`open()` 前**再确认一次**播放器实例仍然有效。
  /// 因为 `_serialize()` 是排队执行的，从入队到真正执行可能已经过了几百毫秒，
  /// 期间用户可能已经滑走页面、播放器已被释放；此时若继续调用
  /// `open()`，media_kit 在 release 包中断言被移除，会**静默什么都不做**，
  /// 页面就永久黑屏。
  Future<void> _openMedia(Player player, PlaybackPlan plan, Duration? start) {
    return _serialize(() async {
      if (!_attemptAlive(player)) return;
      await player.open(
        Media(plan.url, httpHeaders: plan.headers, start: start),
        play: widget.active,
      );
    });
  }

  String get _qualityLabel {
    if (_plan?.local == true) return '本地原画';
    return _quality == 0 ? '自动' : '${_quality}P';
  }

  Future<void> _setSpeed(double value) async {
    if (_closed) return;
    setState(() => _speed = value);
    await _interactions?.applySpeed();
    await widget.store.setPlaybackPreferences(
      widget.store.playbackPreferences.copyWith(speed: value),
    );
  }

  Future<void> _setQuality(int value) async {
    if (_closed || value == _quality) return;
    _quality = value;
    await widget.store.setPlaybackPreferences(
      widget.store.playbackPreferences.copyWith(quality: value),
    );
    _ready = false;
    await _prepare(force: true);
  }

  /// 打开倍速 / 清晰度 / 选集弹窗。
  ///
  /// 0.2.28（方案 D）：全屏层已改为**真正的 Navigator 路由**，
  /// 不再是挂在 root Overlay 上的 `OverlayEntry`。
  /// 因此这里的层级问题自然消失——弹窗统一走 root Navigator，
  /// 会正确显示在全屏路由之上；且不再有"退出全屏后层级错乱"的风险。
  bool get _sheetUsesRootNavigator => true;

  Future<void> _openPanel(Future<void> Function() show) async {
    _hideTimer?.cancel();
    _interactions?.cancel();
    setState(() {
      _panelOpen = true;
      _controlsVisible = true;
    });
    await show();
    if (mounted && !_closed) {
      setState(() => _panelOpen = false);
      _showControls();
    }
  }

  /// 弹窗统一深色底 + 白色文字。
  ///
  /// 用 `Theme` 强制覆盖，而不是只包 `DefaultTextStyle`：
  /// `showModalBottomSheet` 的 builder 挂在 `MaterialApp` 主题上，
  /// 浅色主题下 `ListTile` 的 textColor/iconColor/tileColor 会从主题解析，
  /// 只包 DefaultTextStyle 会被覆盖，导致深色底配深色字看不清。
  Widget _sheetShell({required String title, required Widget child, Key? key}) {
    const background = Color(0xFF191A20);
    const foreground = Colors.white;
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF765F),
          surface: background,
          onSurface: foreground,
          onSurfaceVariant: Color(0xFFB9B6C2),
        ),
        // 覆盖 ListTile / 文本 / 图标 的所有颜色解析入口。
        listTileTheme: const ListTileThemeData(
          textColor: foreground,
          iconColor: foreground,
          titleTextStyle: TextStyle(
            color: foreground,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          subtitleTextStyle: TextStyle(color: Color(0xFFB9B6C2), fontSize: 12),
          selectedColor: Color(0xFFFF765F),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: foreground),
          bodyLarge: TextStyle(color: foreground),
          bodyMedium: TextStyle(color: foreground),
        ),
        iconTheme: const IconThemeData(color: foreground),
        dividerTheme: const DividerThemeData(color: Color(0xFF3A3B44)),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: foreground),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: foreground),
        child: IconTheme(
          data: const IconThemeData(color: foreground),
          child: Material(
            key: key,
            color: background,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: foreground,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF3A3B44)),
                  Flexible(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 选中项胶囊（chip）样式（0.2.31 菜单 UI 改版，用户方案 A）。
  ///
  /// 为什么用 chip 而不是 `ListTile`：
  /// - 倍速/清晰度项数少，竖列列表显得空旷、层次弱；
  /// - chip 能一眼看出"有哪些选项、当前选的是哪个"（选中项主题色填充）；
  /// - 横屏时可用 `Wrap` 自动折行铺满宽度，不再受"底部弹窗太扁"影响。
  Widget _optionChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Key? key,
  }) {
    const accent = Color(0xFFFF765F);
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent : const Color(0xFF26272F),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? accent : const Color(0xFF3A3B44),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFFB9B6C2),
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 自适应列宽：横屏用更大最小宽度，一屏摆更多 chip。
  double get _optionMinWidth {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height ? 104 : 84;
  }

  /// 选项区：`Wrap` 自动折行，横竖屏均自适应（0.2.31）。
  Widget _optionWrap({required List<Widget> children, double spacing = 10}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Wrap(spacing: spacing, runSpacing: spacing, children: children),
      );

  Future<void> _openSpeedMenu() => _openPanel(() async {
    final value = await showModalBottomSheet<double>(
      context: context,
      useRootNavigator: _sheetUsesRootNavigator,
      backgroundColor: const Color(0xFF191A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _sheetShell(
        title: '播放倍速',
        // 0.2.31 改版：竖列列表改为 chip 胶囊组，选中项主题色填充。
        child: SingleChildScrollView(
          child: _optionWrap(
            children: [
              for (final speed in playbackSpeeds)
                SizedBox(
                  width: _optionMinWidth,
                  child: _optionChip(
                    key: ValueKey('speed-${speed}x'),
                    label: '${speed}x',
                    selected: speed == _speed,
                    onTap: () => Navigator.pop(context, speed),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (value != null && mounted) await _setSpeed(value);
  });

  Future<void> _openQualityMenu() => _openPanel(() async {
    final options = <int>[0, ...?_plan?.qualities];
    final value = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: _sheetUsesRootNavigator,
      backgroundColor: const Color(0xFF191A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _sheetShell(
        title: '清晰度',
        // 0.2.31 改版：竖列 → chip 胶囊组。
        child: SingleChildScrollView(
          child: _optionWrap(
            children: [
              for (final option in options)
                SizedBox(
                  width: _optionMinWidth,
                  child: _optionChip(
                    key: ValueKey('quality-$option'),
                    label: option == 0 ? '自动' : '${option}P',
                    selected: option == _quality,
                    onTap: () => Navigator.pop(context, option),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (value != null && mounted) await _setQuality(value);
  });

  /// 加入 / 取消追剧（0.2.26 新增，用户要求）。
  ///
  /// 复用 `store.toggleFavorite`（与详情页、追剧页共用同一份数据），
  /// 不改写现有收藏逻辑（JC-0002）。
  Future<void> _toggleFollow() async {
    final drama = widget.drama;
    final epoch = widget.store.profileEpoch;
    final wasFollowed = _followed;
    // 先本地乐观更新，保证按钮即时响应。
    setState(() => _followed = !wasFollowed);
    _toast(wasFollowed ? '已取消追剧' : '已加入追剧');
    try {
      await widget.store.toggleFavorite(drama);
      if (!mounted) return;
      // 以 store 的真实状态为准（防止并发或未授权站源导致的不一致）。
      final actual = widget.store.isFavorite(drama.id);
      if (actual != _followed) setState(() => _followed = actual);
    } catch (_) {
      if (!mounted) return;
      // 失败时回滚，并给出提示（例如站源未授权）。
      setState(() => _followed = wasFollowed);
      _toast('操作失败，请稍后重试');
    }
    if (epoch != widget.store.profileEpoch) return;
    _refreshFullscreen();
  }

  Future<void> _openEpisodes() => _openPanel(() async {
    // 剧集信息可能尚未就绪（正在解析播放地址），此时给出明确提示而不是静默无反应。
    final detail = _detail;
    if (detail == null || detail.episodes.isEmpty) {
      _toast('剧集信息加载中，请稍候再试');
      return;
    }
    // 打开选集时自动定位到当前正在播放的那一集，
    // 否则长剧每次都要从第 1 集手动往下滚。
    final currentIndex = _episodeIndex.clamp(0, detail.episodes.length - 1);
    // 0.2.31 改版：从"标题列表"改为"数字网格"（每集一个方块，选中项高亮）。
    // 好处：一屏能看更多集、定位当前集更直观；横屏时列数更多、不浪费横向空间。
    final episodes = detail.episodes;
    final columns = _episodeGridColumns;
    // 让网格滚动到当前集附近（网格高度固定，先按行号估算偏移）。
    final gridController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!gridController.hasClients) return;
      final row = currentIndex ~/ columns;
      const rowExtent = 76.0;
      final target = (row * rowExtent - rowExtent).clamp(
        0.0,
        gridController.position.maxScrollExtent,
      );
      gridController.jumpTo(target);
    });
    final value = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: _sheetUsesRootNavigator,
      backgroundColor: const Color(0xFF191A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _sheetShell(
        title: '选集 · 共 ${episodes.length} 集',
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: GridView.builder(
            controller: gridController,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.5,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final selected = index == _episodeIndex;
              const accent = Color(0xFFFF765F);
              return InkWell(
                key: ValueKey('episode-$index'),
                onTap: () => Navigator.pop(context, index),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? accent : const Color(0xFF26272F),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? accent : const Color(0xFF3A3B44),
                    ),
                  ),
                  child: Text(
                    // 方块内只显示集号，避免长标题把方块撑变形。
                    '${episodes[index].number}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : const Color(0xFFB9B6C2),
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    gridController.dispose();
    if (value != null && mounted) await _playEpisode(value);
  });

  /// 选集网格列数：竖屏 4 列、横屏 8 列（横屏横向空间更大）。
  int get _episodeGridColumns {
    final size = MediaQuery.sizeOf(context);
    if (size.width > size.height) return 8;
    return size.width >= 400 ? 5 : 4;
  }

  void _toast(String message) {
    if (!mounted || _closed) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 切换横屏 / 竖屏。
  ///
  /// 注意：很多 m3u8 流在首帧前拿不到真实分辨率（videoParams 为空），
  /// 因此这里**不能**因为比例未知就拒绝执行——那样用户会觉得“点了没反应”。
  /// 比例为未知时直接按当前状态切换，拿到比例后再由监听器微调。
  Future<void> _toggleLandscape() async {
    if (_closed) return;
    final next = !_landscape;
    setState(() {
      _landscape = next;
      _controlsVisible = true;
    });
    _showControls();
    if (next) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!mobile) return;
    try {
      // 横屏视频在全屏时切到横向；竖屏视频保持竖向，仅隐藏系统栏。
      final wide = _aspectRatio <= 0 || _wideVideo;
      await SystemChrome.setPreferredOrientations(
        next && wide
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [DeviceOrientation.portraitUp],
      );
      // 全屏时隐藏状态栏与导航栏（沉浸式），退出时恢复。
      await SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } catch (_) {
      // 个别设备不支持锁定方向，忽略即可。
    }
  }

  /// 进入全屏：push 一个覆盖整个屏幕的全屏**路由**（0.2.28 方案 D）。
  ///
  /// 为什么用路由而不是 `Overlay.insert(OverlayEntry)`：
  /// - 竖滑流外面还套着首页的 AppBar 与 SafeArea，原地改布局无法盖住它们；
  /// - 但 `OverlayEntry` **不属于任何 Navigator 路由**，其中的 `PopScope`
  ///   收不到系统返回键事件 → 0.2.27 的返回键修复**无效**（真机仍回桌面）。
  /// - 改用 `Navigator.push` 一个透明全屏路由后，它位于路由栈中，
  ///   `PopScope` 能正常拦截返回键，实现"返回键 / 按钮 / 手势"都能退出全屏。
  void _enterFullscreen() {
    if (_fullscreenRouteOpen) return;
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return;
    _fullscreenRouteOpen = true;
    _fullscreenNavigator = navigator;
    navigator
        .push<void>(
          PageRouteBuilder<void>(
            opaque: false,
            barrierDismissible: false,
            barrierColor: Colors.black,
            transitionDuration: const Duration(milliseconds: 150),
            reverseTransitionDuration: const Duration(milliseconds: 150),
            pageBuilder: (_, _, _) => _buildFullscreenLayer(),
            transitionsBuilder: (_, animation, _, child) =>
                FadeTransition(opacity: animation, child: child),
          ),
        )
        .whenComplete(() {
          // 路由被任何方式关闭后统一复位（含返回键、手势返回）。
          _fullscreenNavigator = null;
          if (!mounted || _closed) return;
          if (!_fullscreenRouteOpen) return;
          _fullscreenRouteOpen = false;
          if (_landscape) {
            // 返回键关闭时，状态位还没复位（因为没走 _toggleLandscape），
            // 这里统一收尾：恢复竖屏与系统栏。
            setState(() {
              _landscape = false;
              _controlsVisible = true;
            });
            unawaited(_restorePortraitSystemUi());
          }
        });
  }

  /// 退出全屏：关闭全屏路由。
  void _exitFullscreen() {
    if (!_fullscreenRouteOpen) return;
    _fullscreenRouteOpen = false;
    final navigator = _fullscreenNavigator ?? Navigator.maybeOf(context);
    if (navigator != null && navigator.canPop()) navigator.pop();
  }

  /// 恢复竖屏方向与系统栏（退出全屏收尾）。
  Future<void> _restorePortraitSystemUi() async {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!mobile) return;
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {
      // 个别设备不支持锁定方向，忽略即可。
    }
  }

  /// 全屏层内容：视频铺满 + 手势 + 可自动隐藏的简洁控件。
  ///
  /// 0.2.28（方案 D）：本层现在是**全屏路由的内容**（不是 OverlayEntry），
  /// 位于 Navigator 路由栈中，因此 `PopScope` 能正常拦截系统返回键。
  /// 按住返回键时：`canPop: true` → 由 `onPopInvokedWithResult` 里
  /// 调用 `_exitFullscreen()` 关闭路由，并复位方向与系统栏。
  Widget _buildFullscreenLayer() {
    return PopScope<void>(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        // 系统返回键关闭全屏路由：同步复位状态位与方向/系统栏。
        _fullscreenRouteOpen = false;
        if (_landscape && mounted && !_closed) {
          setState(() {
            _landscape = false;
            _controlsVisible = true;
          });
          unawaited(_restorePortraitSystemUi());
        }
      },
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<int>(
          valueListenable: _fullscreenRevision,
          builder: (context, _, _) {
            final video = _video;
            final state = _player?.state;
            final duration = state?.duration.inMilliseconds ?? 0;
            final position = state?.position.inMilliseconds ?? 0;
            final buffered = state?.buffer.inMilliseconds ?? 0;
            final total = duration > 0 ? duration / 1000 : 1.0;
            // 加速中只留中央提示，隐藏整套控件（与竖滑流主层保持一致）。
            final boosting = _interactions?.boosting ?? false;
            final controlsVisible =
                !boosting &&
                (_controlsVisible || !(state?.playing ?? false) || _loading);
            return Material(
              // 全屏路由已脱离竖滑页所在的主题树（push 到 Navigator 之上），
              // 因此这里必须显式给出深色主题，否则滑块会退回默认样式
              // （横杆变成居中圆盘，表现为"进度条跑到中间"）。
              color: Colors.black,
              child: Theme(
                data: _fullscreenTheme,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (video != null)
                      Video(
                        controller: video,
                        controls: (_) => const SizedBox.shrink(),
                        // 全屏时铺满整个屏幕。
                        fit: BoxFit.contain,
                      )
                    else
                      const ColoredBox(color: Colors.black),
                    // 手势层：单击显隐控件，双击播放/暂停，上下滑切集。
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) => _interactions?.pointerDown(
                          event,
                          // 0.2.31：启用上下滑切集（全屏是独立路由，必须由本层承担）。
                          swipeEnabled: true,
                          height: MediaQuery.sizeOf(context).height,
                        ),
                        onPointerMove: (event) =>
                            _interactions?.pointerMove(event),
                        onPointerUp: (event) => _interactions?.pointerUp(event),
                        onPointerCancel: (event) =>
                            _interactions?.pointerCancel(event),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _tap,
                          onDoubleTap: _togglePlayback,
                        ),
                      ),
                    ),
                    if (_loading)
                      const IgnorePointer(
                        child: LoadingHint(message: '正在加载视频…', dark: true),
                      )
                    else if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: () {
                                  _ready = false;
                                  // 0.3.5：播放器已释放时先重建再加载，避免在已释放实例上操作。
                                  unawaited(
                                    _playerReleased
                                        ? _resumeAfterRelease()
                                        : _prepare(force: true),
                                  );
                                },
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // 控件层：自动隐藏。
                    IgnorePointer(
                      ignoring: !controlsVisible,
                      child: AnimatedOpacity(
                        opacity: controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x99000000),
                                      Colors.transparent,
                                      Color(0xDD000000),
                                    ],
                                    stops: [0, .45, 1],
                                  ),
                                ),
                              ),
                            ),
                            // 中央：播放/暂停。
                            if (!(state?.playing ?? false) &&
                                !_loading &&
                                _error == null)
                              Center(
                                child: IconButton.filledTonal(
                                  tooltip: '播放',
                                  iconSize: 52,
                                  onPressed: _togglePlayback,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                ),
                              ),
                            // 底部：进度条 + 时间。
                            //
                            // 0.2.26 修正：原先用 `Align(bottomCenter)`，
                            // 在实际全屏 Overlay 环境下受 `SafeArea`/`MediaQuery`
                            // 影响，进度条会被错误地居中/铺满，且触摸热区异常扩大，
                            // 表现为"屏幕任何位置都只能调节进度条"。
                            // 改为 `Positioned` 明确固定在底部，并限定高度，
                            // 让进度条只占底部一条，其余区域照常响应单击/长按/双击。
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    8,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          IconButton(
                                            key: const ValueKey(
                                              'fullscreen-play-toggle',
                                            ),
                                            tooltip: (state?.playing ?? false)
                                                ? '暂停'
                                                : '播放',
                                            onPressed: _togglePlayback,
                                            icon: Icon(
                                              (state?.playing ?? false)
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              color: Colors.white,
                                            ),
                                          ),
                                          Text(
                                            '${formatPosition((_seekValue ?? position / 1000))} / ${formatPosition(duration / 1000)}',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                          Expanded(
                                            child: SizedBox(
                                              height: 32,
                                              child: SliderTheme(
                                                data: fullscreenSliderTheme,
                                                child: Slider(
                                                  key: const ValueKey(
                                                    'fullscreen-progress',
                                                  ),
                                                  value:
                                                      (_seekValue ??
                                                              position / 1000)
                                                          .clamp(0, total),
                                                  max: total,
                                                  secondaryTrackValue:
                                                      (buffered / 1000).clamp(
                                                        0,
                                                        total,
                                                      ),
                                                  onChangeStart: duration > 0
                                                      ? (_) {
                                                          _interactions
                                                              ?.cancel();
                                                          _hideTimer?.cancel();
                                                        }
                                                      : null,
                                                  onChanged: duration <= 0
                                                      ? null
                                                      : (value) {
                                                          _hideTimer?.cancel();
                                                          setState(
                                                            () => _seekValue =
                                                                value,
                                                          );
                                                        },
                                                  onChangeEnd: (value) {
                                                    if (duration > 0) {
                                                      unawaited(
                                                        _seekTo(
                                                          Duration(
                                                            milliseconds:
                                                                (value * 1000)
                                                                    .round(),
                                                          ),
                                                        ),
                                                      );
                                                    }
                                                    setState(
                                                      () => _seekValue = null,
                                                    );
                                                    _showControls();
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            key: const ValueKey(
                                              'fullscreen-exit',
                                            ),
                                            tooltip: '退出全屏',
                                            onPressed: _toggleLandscape,
                                            icon: const Icon(
                                              Icons.fullscreen_exit_rounded,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: [
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-speed',
                                            ),
                                            icon: Icons.speed_rounded,
                                            label: '${_speed}x',
                                            onPressed: _openSpeedMenu,
                                          ),
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-quality',
                                            ),
                                            icon: Icons.hd_rounded,
                                            label: _qualityLabel,
                                            onPressed: _openQualityMenu,
                                          ),
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-episodes',
                                            ),
                                            icon: Icons.grid_view_rounded,
                                            label: '选集',
                                            onPressed: _openEpisodes,
                                          ),
                                          _sideButton(
                                            key: const ValueKey(
                                              'fullscreen-follow',
                                            ),
                                            icon: _followed
                                                ? Icons.bookmark_rounded
                                                : Icons.bookmark_border_rounded,
                                            label: _followed ? '已追剧' : '追剧',
                                            onPressed: _toggleFollow,
                                          ),
                                          if (!widget.singleDrama)
                                            _sideButton(
                                              key: const ValueKey(
                                                'fullscreen-auto-next',
                                              ),
                                              icon: widget.autoNextEpisode
                                                  ? Icons.repeat_one_rounded
                                                  : Icons.skip_next_rounded,
                                              label: widget.autoNextEpisode
                                                  ? '连播本剧'
                                                  : '连播下一部',
                                              color: widget.autoNextEpisode
                                                  ? const Color(0xFFFF765F)
                                                  : Colors.white,
                                              onPressed:
                                                  widget.onToggleAutoNext,
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 全屏层专用主题。
  ///
  /// 全屏层挂在 **root Overlay** 上，已脱离竖滑页所在的 Widget 树，
  /// `Theme.of(context)` / `SliderTheme.of(context)` 拿不到页面主题，
  /// 滑块会退回 Flutter 默认样式（横杆 + 大圆盘），表现为"进度条跑到中间"。
  /// 这里显式给一份深色主题，保证样式与竖滑流一致。
  static final ThemeData _fullscreenTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF765F),
      surface: Colors.black,
      onSurface: Colors.white,
      onSurfaceVariant: Color(0xFFB9B6C2),
    ),
    iconTheme: const IconThemeData(color: Colors.white),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white),
    ),
    sliderTheme: fullscreenSliderTheme,
  );

  /// 全屏进度条样式：细横杆 + 小圆点，不用默认的大圆盘。
  static final SliderThemeData fullscreenSliderTheme = SliderThemeData(
    trackHeight: 3,
    activeTrackColor: const Color(0xFFFF765F),
    inactiveTrackColor: Colors.white24,
    secondaryActiveTrackColor: Colors.white38,
    thumbColor: const Color(0xFFFF765F),
    overlayColor: const Color(0x33FF765F),
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    trackShape: const RectangularSliderTrackShape(),
  );

  /// 让全屏层重建（状态变化时调用）。
  ///
  /// 节流到 250ms（0.3.1 性能修复）：全屏层内容较重（进度条 + 选集），
  /// 而 position 流每秒推送多次，每次都整层重建会造成明显掉帧。
  /// [immediate] 为 true 时跳过节流，用于用户操作（切集、暂停等）需要立刻反馈的场景。
  void _refreshFullscreen({bool immediate = false}) {
    if (!_fullscreenRouteOpen) return;
    final now = DateTime.now();
    if (!immediate &&
        now.difference(_lastFullscreenRefresh) <
            const Duration(milliseconds: 250)) {
      return;
    }
    _lastFullscreenRefresh = now;
    _fullscreenRevision.value++;
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final state = _player?.state;
    final duration = state?.duration.inMilliseconds ?? 0;
    final position = state?.position.inMilliseconds ?? 0;
    final buffered = state?.buffer.inMilliseconds ?? 0;
    final total = duration > 0 ? duration / 1000 : 1.0;
    // 长按加速（3 倍速）期间只保留中央的加速提示，
    // 必须把完整控件层（进度条 + 剧名 + 简介 + 按钮）整体隐藏，
    // 否则加速时这些信息会盖住画面。
    final boosting = _interactions?.boosting ?? false;
    final visible =
        !boosting &&
        (_controlsVisible ||
            _panelOpen ||
            _loading ||
            _error != null ||
            !(state?.playing ?? false));
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.videoBuilder != null)
          // 测试注入的视频层：不依赖原生视频控制器。
          widget.videoBuilder!(const SizedBox.shrink())
        else if (video != null && !_landscape)
          Video(
            controller: video,
            controls: (_) => const SizedBox.shrink(),
            fit: BoxFit.contain,
          )
        else if (_landscape)
          // 全屏时画面由全屏层渲染，这里留黑避免同一路视频被渲染两次。
          const ColoredBox(color: Colors.black)
        else
          const ColoredBox(color: Colors.black),
        // 手势层：单击显隐控件，双击暂停，长按 3 倍速，上下滑切集。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _interactions?.pointerDown(
              event,
              // 0.2.31：启用上下滑切集（方案 B：只切集、不切剧）。
              swipeEnabled: true,
              height: MediaQuery.sizeOf(context).height,
            ),
            onPointerMove: (event) => _interactions?.pointerMove(event),
            onPointerUp: (event) => _interactions?.pointerUp(event),
            onPointerCancel: (event) => _interactions?.pointerCancel(event),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _tap,
              onDoubleTap: _togglePlayback,
            ),
          ),
        ),
        if (_loading)
          const IgnorePointer(
            child: LoadingHint(message: '正在加载视频…', dark: true),
          )
        else if (_error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {
                      _ready = false;
                      // 0.3.5：播放器已释放时先重建再加载，避免在已释放实例上操作。
                      unawaited(
                        _playerReleased
                            ? _resumeAfterRelease()
                            : _prepare(force: true),
                      );
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        // 长按加速提示（独立层）。
        //
        // 0.2.26 修正：原先该提示位于控件层内部，受 `IgnorePointer(ignoring: !visible)`
        // 与 `AnimatedOpacity(opacity: visible ? 1 : 0)` 控制；而加速时 `visible`
        // 恰好为 false（正是为了隐藏进度条/剧名/简介），结果连「3 倍速 · 松开恢复」
        // 也被一并隐藏，用户看到的是"按住后啥也不显示"。
        //
        // 现把它移出控件层、独立渲染，不受控件显隐影响：
        // - 加速中：显示「3 倍速 · 松开恢复」；
        // - 松开后：短暂显示「恢复 X 倍速」（由 PlayerInteractions 的 hint 控制）。
        if (_interactions != null)
          AnimatedBuilder(
            animation: _interactions!,
            builder: (context, _) {
              final feedback = _interactions!.feedback;
              if (feedback.isEmpty) return const SizedBox.shrink();
              return IgnorePointer(
                child: Align(
                  alignment: const Alignment(0, -.5),
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(feedback, textAlign: TextAlign.center),
                  ),
                ),
              );
            },
          ),
        // 控件层。
        IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            // 进度条 / 时间 / 暂停按钮跟随 `_tick` 轻量重建（0.3.1）。
            //
            // 整页 setState 已移除（见 _ensurePlayer 的流监听），
            // 这里只重建底部控件子树，避免每秒多次重建整个手势层与选集按钮。
            child: ValueListenableBuilder<int>(
              valueListenable: _tick,
              builder: (context, _, _) => Stack(
                fit: StackFit.expand,
                children: [
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x99000000),
                            Colors.transparent,
                            Color(0xDD000000),
                          ],
                          stops: [0, .45, 1],
                        ),
                      ),
                    ),
                  ),
                  // 暂停时显示中央播放按钮。
                  if (!(state?.playing ?? false) &&
                      !_loading &&
                      _error == null &&
                      !_panelOpen)
                    Center(
                      child: IconButton.filledTonal(
                        tooltip: '播放',
                        iconSize: 42,
                        onPressed: _togglePlayback,
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ),
                  // 长按加速提示。
                  //
                  // 0.2.26 修正：【已移除】，改到控件层外独立渲染。
                  // 原因：该提示原先在控件层内部，受 `IgnorePointer(ignoring: !visible)`
                  // 控制；而加速时 `visible` 恰好为 false，导致长按加速时
                  // 连「3 倍速 · 松开恢复」都不显示（用户：“按住后啥也不显示”）。
                  // 详见文件下方“长按加速提示（独立层）”块。
                  // 底部区域：左侧信息面板 + 右侧功能按钮。
                  //
                  // 修复「横屏按钮点了没反应」的根因：原先底部面板与右侧按钮组
                  // 是两个独立的 Positioned / Align，面板内容多时（剧名 + 两行简介
                  // + 热度行）会向上撑高，把位于 right:8, bottom:190 的按钮组盖住，
                  // 导致按钮收不到点击（表现为"完全没反应"，连按钮文字都不变）。
                  // 改为同一个 Column 布局后，两者在结构上永不重叠。
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black87],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.drama.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    key: const ValueKey('feed-play-toggle'),
                                    tooltip: (state?.playing ?? false)
                                        ? '暂停'
                                        : '播放',
                                    onPressed: _togglePlayback,
                                    icon: Icon(
                                      (state?.playing ?? false)
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    '${formatPosition((_seekValue ?? position / 1000))} / ${formatPosition(duration / 1000)}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(
                                        context,
                                      ).copyWith(trackHeight: 3),
                                      child: Slider(
                                        key: const ValueKey('feed-progress'),
                                        value:
                                            (_seekValue ?? position / 1000)
                                                .clamp(0, total),
                                        max: total,
                                        secondaryTrackValue:
                                            (buffered / 1000).clamp(0, total),
                                        semanticFormatterCallback:
                                            formatPosition,
                                        onChangeStart: duration > 0
                                            ? (_) {
                                                _interactions?.cancel();
                                                _hideTimer?.cancel();
                                              }
                                            : null,
                                        onChanged: duration <= 0
                                            ? null
                                            : (value) {
                                                _hideTimer?.cancel();
                                                setState(
                                                  () => _seekValue = value,
                                                );
                                              },
                                        onChangeEnd: (value) {
                                          if (duration > 0) {
                                            unawaited(
                                              _seekTo(
                                                Duration(
                                                  milliseconds: (value * 1000)
                                                      .round(),
                                                ),
                                              ),
                                            );
                                          }
                                          setState(() => _seekValue = null);
                                          _showControls();
                                        },
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    key: const ValueKey('feed-landscape'),
                                    tooltip: _landscape ? '退出全屏' : '全屏',
                                    onPressed: _toggleLandscape,
                                    icon: Icon(
                                      _landscape
                                          ? Icons.fullscreen_exit_rounded
                                          : Icons.fullscreen_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  _sideButton(
                                    key: const ValueKey('feed-speed'),
                                    icon: Icons.speed_rounded,
                                    label: '${_speed}x',
                                    onPressed: _openSpeedMenu,
                                  ),
                                  _sideButton(
                                    key: const ValueKey('feed-quality'),
                                    icon: Icons.hd_rounded,
                                    label: _qualityLabel,
                                    onPressed: _openQualityMenu,
                                  ),
                                  _sideButton(
                                    key: const ValueKey('feed-episodes'),
                                    icon: Icons.grid_view_rounded,
                                    label: '选集',
                                    onPressed: _openEpisodes,
                                  ),
                                  _sideButton(
                                    key: const ValueKey('feed-follow'),
                                    icon: _followed
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    label: _followed ? '已追剧' : '追剧',
                                    onPressed: _toggleFollow,
                                  ),
                                  if (!widget.singleDrama)
                                    _sideButton(
                                      key: const ValueKey('feed-auto-next'),
                                      icon: widget.autoNextEpisode
                                          ? Icons.repeat_one_rounded
                                          : Icons.skip_next_rounded,
                                      label: widget.autoNextEpisode
                                          ? '连播本剧'
                                          : '连播下一部',
                                      color: widget.autoNextEpisode
                                          ? const Color(0xFFFF765F)
                                          : Colors.white,
                                      onPressed: widget.onToggleAutoNext,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sideButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color color = Colors.white,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: key,
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon, color: color, size: 24),
        ),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}
