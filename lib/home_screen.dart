import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app_layout.dart';
import 'app_updater.dart';
import 'about_credit.dart';
import 'app_bottom_navigation.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'catalog_auto_updater.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
import 'recommendations_screen.dart';
import 'vertical_feed_screen.dart';
import 'rankings_screen.dart';
import 'detail_screen.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'lan_screen.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'vip_icon.dart';
import 'settings_screen.dart';
import 'profiles_screen.dart';
import 'search_input.dart';
import 'sources_screen.dart';
import 'batch_download_screen.dart';
import 'batch_downloads.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'saved_library.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialTab,
    this.feedPlayerFactory,
    this.onFeedReady,
  });
  final AppRepository repository;
  final LocalStore store;

  /// 初始标签下标。为空时默认打开「首页」（竖滑视频流）。
  final int? initialTab;

  /// 测试用：注入首页假播放器。
  final Player Function()? feedPlayerFactory;

  /// 首页竖滑流拿到第一批可播放视频后回调（用于关闭开屏页）。
  final VoidCallback? onFeedReady;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _recommendationCategory = 'app:recommendations';
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  late SourceSite _source;
  bool _allSources = false;

  /// 多选站源（非空时优先于单源/全部，作为当前浏览范围）。
  List<String> _multiSources = const [];
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _tab = 0;
  String _submittedQuery = '';
  bool _failedMore = false;
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _searchVisible = false;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  late final CatalogAutoUpdater _autoUpdater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _updateNotice = false;
  bool _selectionMode = false;
  bool _showRecommendations = false;

  /// 双击「首页」标签时自增，通知竖滑流重新随机。
  final _feedRefresh = ValueNotifier<int>(0);

  List<SourceGroup> get _sourceGroups {
    final groups = SourceGroup.fromSources(widget.store.sources);
    return groups;
  }

  /// 多选模式下自定义的站源分组。
  SourceGroup? get _multiGroup {
    if (_multiSources.isEmpty) return null;
    final sites = widget.store.sources
        .where((site) => _multiSources.contains(site.id))
        .toList();
    if (sites.isEmpty) return null;
    final name = sites.length == widget.store.sources.length
        ? '全部站源'
        : sites.map((site) => site.entryName).join('+');
    return SourceGroup('multi', name, sites);
  }

  SourceGroup get _group {
    final multi = _multiGroup;
    if (multi != null) return multi;
    return _sourceGroups
            .where((group) => group.id == _source.groupId)
            .firstOrNull ??
        SourceGroup(_source.groupId, _source.groupName, [_source]);
  }

  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);
  String get _searchHint {
    final online = _group.sources
        .where((source) => source.onlineSearch)
        .toList();
    if (online.isEmpty) {
      return '筛选本机已更新剧库';
    }
    final names = online.map((source) => source.name).join('、');
    return online.length == _group.sources.length
        ? '搜索${names}短剧'
        : '搜索${names}及本机剧库';
  }

  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories => [
    CatalogCategory.all,
    if (_group.id == 'hongguo')
      const CatalogCategory(_recommendationCategory, '推荐'),
    ..._categories.where((entry) => entry.id.isNotEmpty),
  ];

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (!_showRecommendations &&
        _category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      _pauseCatalog();
      setState(() => _updateNotice = true);
      await _updater.update(_group.sources);
      return;
    }
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _autoUpdateChanged() {
    if (mounted) setState(() {});
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  /// AppBar 的站源菜单：**多选勾选**。
  ///
  /// 用户明确要求「勾选」= 可多选，因此这里不使用 PopupMenuButton 的
  /// 单选 onSelected 语义，而是自己维护选中集合，点击后立即生效。
  /// 再次点击已勾选项即取消勾选。
  Widget _sourceMenu() {
    final groups = _sourceGroups;
    final enabled = widget.store.sources.isNotEmpty;
    // 当前选中的 group id 集合：多选时是 _multiSources 对应的分组，
    // 单选时是当前源所在分组。
    final selected = <String>{
      if (_multiSources.isNotEmpty)
        for (final site in widget.store.sources)
          if (_multiSources.contains(site.id)) site.groupId,
      if (_multiSources.isEmpty) _source.groupId,
    };
    return PopupMenuButton<String>(
      key: const ValueKey('source-switch'),
      tooltip: '选择站源（可多选）',
      enabled: enabled,
      onSelected: (value) {
        if (value == _multiMenuClear) {
          if (_multiSources.isNotEmpty) {
            unawaited(_applyMultiSources(const []));
          } else {
            _changeSource(SourceSite.byId(_source.id));
          }
          return;
        }
        final group = groups.where((group) => group.id == value).firstOrNull;
        if (group == null) return;
        // 多选：基于当前集合做增删。
        final current = _multiSources.isNotEmpty
            ? <String>{..._multiSources}
            : <String>{
                for (final site in widget.store.sources)
                  if (site.groupId == _source.groupId) site.id,
              };
        final ids = group.sources.map((site) => site.id).toSet();
        if (current.containsAll(ids) && ids.isNotEmpty) {
          current.removeAll(ids);
        } else {
          current.addAll(ids);
        }
        unawaited(
          _applyMultiSources(
            widget.store.sources
                .where((site) => current.contains(site.id))
                .map((site) => site.id)
                .toList(),
          ),
        );
      },
      itemBuilder: (_) => [
        for (final group in groups)
          PopupMenuItem(
            value: group.id,
            child: Row(
              children: [
                // 多选勾选框：勾中表示该源参与聚合。
                SizedBox(
                  width: 28,
                  child: Icon(
                    selected.contains(group.id)
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 20,
                    color: selected.contains(group.id)
                        ? const Color(0xFFFF765F)
                        : null,
                  ),
                ),
                Expanded(child: Text(group.name)),
              ],
            ),
          ),
        if (_multiSources.isNotEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: _multiMenuClear,
            child: Row(
              children: [
                SizedBox(width: 28, child: Icon(Icons.close_rounded, size: 20)),
                Expanded(child: Text('恢复单选')),
              ],
            ),
          ),
        ],
      ],
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _group.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (enabled) const Icon(Icons.expand_more_rounded),
          ],
        ),
      ),
    );
  }

  /// 「恢复单选」菜单项的哨兵值（不会与真实 group id 冲突）。
  static const _multiMenuClear = '__single__';

  /// 切换到「多选站源」状态：同时聚合勾选的若干个源。
  ///
  /// 勾选数量语义：
  /// - 0 个：回到单选（使用 [_source]）。
  /// - 1 个：等价单选，直接切到该源。
  /// - ≥2 个：多选聚合，`_multiSources` 生效。
  Future<void> _applyMultiSources(List<String> ids) async {
    final available = widget.store.sources
        .where((site) => ids.contains(site.id))
        .map((site) => site.id)
        .toList();
    if (available.isEmpty) {
      setState(() {
        _multiSources = const [];
        _allSources = false;
      });
      await widget.store.setMultiSources(const []);
      return;
    }
    if (available.length == 1) {
      setState(() {
        _multiSources = const [];
        _allSources = false;
      });
      await widget.store.setMultiSources(const []);
      _changeSource(SourceSite.byId(available.first));
      return;
    }
    setState(() {
      _multiSources = available;
      _allSources = false;
      _selectionMode = false;
      _selectedDramas.clear();
    });
    await widget.store.setMultiSources(available);
    if (!mounted) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
    _loadCategories();
  }

  void _changeCategory(String category) {
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _searchVisible = false;
        _submittedQuery = '';
      });
      return;
    }
    if (_category == category && !_showRecommendations) return;
    _debounce?.cancel();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_group.id] = category;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _displayCategories;
    final index = categories.indexWhere(
      (entry) => entry.id == _displayCategory,
    );
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    }
  }

  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    if (_showRecommendations) _changeCategory('');
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  void _openRankings() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
        ),
      ),
    );
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted) return;
    await _loadCategories();
    if (mounted && (!_onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
    }
  }

  Future<void> _chooseDisplayMode() async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('界面模式'),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.displayMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in const {
                  'auto': '自动识别设备',
                  'television': '电视 / 遥控器',
                  'standard': '手机 / 电脑',
                }.entries)
                  RadioListTile<String>(
                    value: mode.key,
                    autofocus: mode.key == widget.store.displayMode,
                    title: Text(mode.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setDisplayMode(selection),
      );
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _multiSources.isNotEmpty
            ? '搜索已选站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != _feedIndex) {
      setState(() => _tab = _feedIndex);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    // 监听前后台切换：从后台返回时刷新首页竖滑流一次（用户要求）。
    WidgetsBinding.instance.addObserver(this);
    _source = SourceSite.byId(widget.store.source);
    _allSources = widget.store.catalogView.allSources;
    _multiSources = widget.store.multiSources;
    if (_allSources &&
        _multiSources.isEmpty &&
        widget.store.sources.length > 1) {
      // 旧版「全部站源」在单选模型下没有对应状态，但我们已恢复多选，
      // 这里保持多选语义：若历史配置是 allSources，不强制改写，交给用户再次选择。
    }
    // 进软件优先打开「首页」（竖滑视频流）。
    _tab = widget.initialTab ?? _feedIndex;
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    // 剧库自适应自动更新：默认 30 分钟，连续无新剧后降级为 6 小时。
    _autoUpdater = CatalogAutoUpdater(widget.repository, widget.store)
      ..addListener(_autoUpdateChanged)
      ..start();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _autoUpdater.removeListener(_autoUpdateChanged);
    _autoUpdater.dispose();
    _feedRefresh.dispose();
    _cacheRefreshTimer?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _group;
    final query = _onlineSearch ? _search.text.trim() : '';
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      _failedMore = false;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(CatalogPage result) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        // 只要已经有内容（无论是磁盘缓存还是网络返回），就立刻结束加载态。
        // 之前写成 cached && !result.fresh 会让"缓存命中但待刷新"时
        // 仍然显示加载指示，用户感知就是"一直在转圈"。
        // 新鲜度由后台刷新负责，不再阻塞界面。
        _loading = false;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(result.items)),
      );
    }

    try {
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
        _failedMore = more;
      });
    }
  }

  void _changeSource(SourceSite source, {bool allSources = false}) {
    if (_source.id == source.id &&
        _allSources == allSources &&
        _multiSources.isEmpty) {
      return;
    }
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _updateNotice = false;
      _source = source;
      _allSources = allSources;
      _multiSources = const [];
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
    });
    unawaited(
      saveUserChange(context, () async {
        await widget.store.setMultiSources(const []);
        await widget.store.setCatalogSource(source.id, allSources: allSources);
      }),
    );
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_group.id] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_onlineSearch) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _chooseCatalogView() async {
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(selected),
      );
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          resumeOnOpen: resume,
          downloadOnOpen: download,
        ),
      ),
    );
  }

  void _changeTab(int tab) => setState(() {
    _tab = tab;
    _selectionMode = false;
    _selectedDramas.clear();
  });

  /// 前后台切换（0.2.26 新增；0.2.27 修正）。
  ///
  /// 0.2.27 修正（用户真机反馈第 1 条）：
  /// 用户明确："返回到桌面（应用仍在后台存活）不算退后台，不该触发刷新；
  /// 只有应用被**彻底退出进程后重新冷启动**才算重新启动、才正常刷新"。
  ///
  /// 原实现在 `resumed && _wentToBackground` 时 `_feedRefresh.value++`，
  /// 但真机上"从桌面切回应用"会经历 `inactive/paused → resumed`，
  /// 于是每次从桌面回来都会误刷新一次首页。
  ///
  /// 现在**彻底移除生命周期驱动的刷新**：
  /// - 从桌面切回（进程存活）→ 不刷新；
  /// - 应用被杀后冷启动 → 走 `main` 初始化，首页自然首次加载（属正常刷新）。
  /// - 手动刷新入口保留：**双击「首页」标签**（`_onTabDoubleTap`）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 0.2.27：不再根据前后台状态刷新首页。
    // 保留该方法以免影响 `WidgetsBindingObserver` 的注册/注销；
    // 若日后需要"真正退后台才刷新"，可在此处判断 `detached`（进程结束）再处理。
  }

  /// 双击标签：目前只对「首页」生效——重新随机一批视频。
  void _onTabDoubleTap(int tab) {
    if (tab != _feedIndex) return;
    _changeTab(_feedIndex);
    _feedRefresh.value++;
  }

  /// 「首页」标签在所有标签中固定排第一位。
  static const _feedIndex = 0;

  /// 各功能标签在导航中的下标（「首页」占 0，其余依次后移）。
  int get _discoverIndex => 1;
  int get _followIndex => 2;
  int get _historyIndex => 3;
  int get _downloadIndex => 4;

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _selectDrama(Drama drama) {
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多选择 50 部短剧，请分批下载')));
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _downloadSelected() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          repository: widget.repository,
          store: widget.store,
          dramas: _selectedDramas.values.toList(),
        ),
      ),
    );
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onContinue: () => _openDrama(drama, resume: true),
    onDownload: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    final canSelect =
        widget.store.canDownload && widget.repository.supportsDownloads;
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _dramaActions(drama),
      ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.newEpisodes > 0 ? ' · 更新 ${following.newEpisodes} 集' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  List<Drama> get _visible {
    final query = _search.text.trim().toLowerCase();
    return sortCatalog(
      _items.where((drama) {
        if (!widget.store.allowsSource(drama.source)) return false;
        if (_category.startsWith('local:') &&
            categoryName(drama.category) != _category.substring(6)) {
          return false;
        }
        if (_hideVip && drama.source == 'huangdou' && drama.vip) {
          return false;
        }
        return _onlineSearch ||
            query.isEmpty ||
            matchesDramaQuery(drama, query);
      }),
      widget.store.catalogView,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final television = AppLayout.isTelevision(context);
        final desktop = constraints.maxWidth >= 840;
        final scaffold = Scaffold(
          appBar: AppBar(
            toolbarHeight: television ? 64 : null,
            titleSpacing: 12,
            title: _selectionMode
                ? const Text(
                    '选择短剧',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : _tab == _feedIndex || _tab == _discoverIndex
                ? _sourceMenu()
                : const Text(appName),
            actions: [
              if (_selectionMode) ...[
                TextButton(
                  key: const ValueKey('clear-catalog-selection'),
                  onPressed: _selectedDramas.isEmpty
                      ? null
                      : () => setState(_selectedDramas.clear),
                  child: const Text('清空'),
                ),
                TextButton(
                  key: const ValueKey('cancel-catalog-selection'),
                  onPressed: _cancelSelection,
                  child: const Text('取消'),
                ),
              ] else ...[
                if (_tab == _followIndex)
                  IconButton(
                    key: const ValueKey('follow-lan-sync'),
                    tooltip: '追剧同步',
                    onPressed: () => openLanSync(context),
                    icon: const Icon(Icons.sync_rounded),
                  ),
                if (_tab == _discoverIndex) ...[
                  if (!_showRecommendations)
                    IconButton(
                      tooltip: '排序与筛选 · ${widget.store.catalogView.sort.label}',
                      onPressed: _chooseCatalogView,
                      color:
                          widget.store.catalogView.sort != CatalogSort.source ||
                              widget.store.catalogView.release.isNotEmpty
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      icon: const Icon(Icons.sort_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('open-rankings'),
                    tooltip: '榜单',
                    onPressed: widget.store.sources.isEmpty
                        ? null
                        : _openRankings,
                    icon: const Icon(Icons.leaderboard_outlined),
                  ),
                  if (!_showRecommendations &&
                      widget.store.canDownload &&
                      widget.repository.supportsDownloads)
                    IconButton(
                      key: const ValueKey('select-catalog-dramas'),
                      tooltip: '多选下载',
                      onPressed: () => setState(() => _selectionMode = true),
                      icon: const Icon(Icons.checklist_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('toggle-search'),
                    tooltip: _searchVisible ? '收起搜索' : '搜索',
                    icon: Icon(
                      _searchVisible
                          ? Icons.search_off_rounded
                          : Icons.search_rounded,
                    ),
                    onPressed: _toggleSearch,
                  ),
                ],
                if (_tab == _discoverIndex &&
                    !_showRecommendations &&
                    constraints.maxWidth >= 400)
                  RefreshAction(
                    key: const ValueKey('catalog-refresh'),
                    loading:
                        _loading ||
                        _loadingMore ||
                        _categoriesLoading ||
                        _group.sources.any(
                          (source) => _updater.busy(source.id),
                        ),
                    tooltip: '更新剧库',
                    onPressed: widget.store.sources.isEmpty
                        ? null
                        : _refreshCatalog,
                  ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    if (value == 'update') {
                      _refreshCatalog();
                    } else if (value == 'sources') {
                      _manageSources();
                    } else if (value == 'settings') {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => SettingsScreen(
                            repository: widget.repository,
                            store: widget.store,
                          ),
                        ),
                      );
                    } else if (value == 'users') {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ProfilesScreen(store: widget.store),
                        ),
                      );
                    } else if (value == 'display') {
                      _chooseDisplayMode();
                    } else if (value == 'about') {
                      showAboutDialog(
                        context: context,
                        applicationName: appName,
                        applicationVersion: AppLayout.versionOf(context),
                        applicationIcon: const Icon(
                          Icons.play_circle_filled_rounded,
                          size: 48,
                          color: Color(0xFFFF765F),
                        ),
                        children: [
                          const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'),
                          const SizedBox(height: 12),
                          // 作者信息（0.2.30 新增，用户要求）：
                          // 名字蓝色可点击，跳转各自 GitHub 页面，并标明身份。
                          const AboutCredit(
                            name: 'Topkill',
                            role: '开源项目 guoapp3 原作者',
                            url: 'https://github.com/Topkill/guoapp3',
                          ),
                          const AboutCredit(
                            name: '软萌小正太',
                            role: '本应用改版与维护',
                            url: 'https://github.com/kuoluoss/zhenguojian',
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const ValueKey('about-check-update'),
                              onPressed: () =>
                                  AppUpdater.checkManually(context),
                              icon: const Icon(
                                Icons.system_update_rounded,
                                size: 18,
                              ),
                              label: const Text('检测新版本'),
                            ),
                          ),
                        ],
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    if (_tab == _discoverIndex &&
                        !_showRecommendations &&
                        constraints.maxWidth < 400)
                      PopupMenuItem(
                        value: 'update',
                        enabled:
                            widget.store.sources.isNotEmpty &&
                            !_group.sources.any(
                              (source) => _updater.busy(source.id),
                            ),
                        child: const Text('更新剧库'),
                      ),
                    if (widget.repository.supportsSourceManagement)
                      const PopupMenuItem(
                        value: 'sources',
                        child: Text('站源管理'),
                      ),
                    const PopupMenuItem(value: 'users', child: Text('用户管理')),
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('设置与备份'),
                    ),
                    // 「界面模式」入口已隐藏（0.2.26）。
                    //
                    // 用户要求：下个版本仅保留手机版，暂停 TV 版。
                    // 该入口用于手动在「自动/电视/手机」之间切换显示模式，
                    // 隐藏后应用统一按手机版渲染（相关 TV 代码保留，不删除，
                    // 便于日后恢复；见 JC-0002 与项目决策记录）。
                    const PopupMenuItem(
                      value: 'about',
                      child: Text('关于$appName'),
                    ),
                  ],
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Row(
              children: [
                if (television) ...[
                  SizedBox(
                    width: 164,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in [
                            (Icons.smart_display_rounded, '首页'),
                            (Icons.explore_rounded, '发现'),
                            (Icons.bookmark_rounded, '追剧'),
                            (Icons.history_rounded, '最近观看'),
                            if (widget.store.canDownload)
                              (Icons.download_rounded, '下载'),
                          ].indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: RemoteButton(
                                key: ValueKey('tv-nav-${entry.$1}'),
                                label: entry.$2.$2,
                                icon: entry.$2.$1,
                                selected: _tab == entry.$1,
                                autofocus: entry.$1 == 0,
                                onPressed: () => _changeTab(entry.$1),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ] else if (desktop) ...[
                  NavigationRail(
                    selectedIndex: _tab,
                    onDestinationSelected: _changeTab,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -.8,
                    destinations: [
                      NavigationRailDestination(
                        icon: Icon(Icons.smart_display_outlined),
                        selectedIcon: Icon(Icons.smart_display_rounded),
                        label: Text('首页'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: Text('发现'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.bookmark_border_rounded),
                        selectedIcon: Icon(Icons.bookmark_rounded),
                        label: Text('追剧'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.history_rounded),
                        label: Text('最近观看'),
                      ),
                      if (widget.store.canDownload)
                        NavigationRailDestination(
                          icon: Icon(Icons.download_outlined),
                          selectedIcon: Icon(Icons.download_rounded),
                          label: Text('下载'),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                ],
                Expanded(
                  // 0.2.26 修正（用户反馈"每次回到首页都会重新刷新"）：
                  //
                  // 原先这里用 `_tab == _feedIndex ? A : _tab == B ? ...` 的三元表达式
                  // 直接构建，切换标签时**未选中的页面会被销毁**，切回来时重建，
                  // 于是首页（竖滑流）每次都重新加载、丢失播放进度与滚动位置。
                  //
                  // 改用 `IndexedStack`：所有页面同时存在于树中，只显示当前一个。
                  // 这样首页（含播放器）在切标签时保持存活，不再重建。
                  //
                  // 刷新时机改为（用户明确要求）：
                  // - 手动双击「首页」标签（_onTabDoubleTap → _feedRefresh++）；
                  // - 退到后台再回来（前后台切换时首页会因内存回收自然重载，
                  //   同时 _feedRefresh 由生命周期兜底触发）。
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      // 首页：竖滑流。
                      VerticalFeedScreen(
                        repository: widget.repository,
                        store: widget.store,
                        embedded: true,
                        sources: _group.sources,
                        playerFactory: widget.feedPlayerFactory,
                        refreshSignal: _feedRefresh,
                        onReady: widget.onFeedReady,
                        active: _tab == _feedIndex,
                      ),
                      // 发现页。
                      widget.store.sources.isEmpty
                          ? const StatusPanel(
                              title: '暂无可用站源',
                              message: '请联系管理员为当前用户开放站源。',
                            )
                          : _catalog(selectionInBody: desktop || television),
                      // 追剧页。
                      SavedLibrary(
                        key: const ValueKey('saved-tab-follow'),
                        repository: widget.repository,
                        store: widget.store,
                        history: false,
                        onOpen: _openDrama,
                        onContinue: (drama) => _openDrama(drama, resume: true),
                        onDownload:
                            widget.repository.supportsDownloads &&
                                widget.store.canDownload
                            ? (drama) => _openDrama(drama, download: true)
                            : null,
                      ),
                      // 最近观看。
                      SavedLibrary(
                        key: const ValueKey('saved-tab-history'),
                        repository: widget.repository,
                        store: widget.store,
                        history: true,
                        onOpen: _openDrama,
                        onContinue: (drama) => _openDrama(drama, resume: true),
                        onDownload:
                            widget.repository.supportsDownloads &&
                                widget.store.canDownload
                            ? (drama) => _openDrama(drama, download: true)
                            : null,
                      ),
                      // 下载。
                      if (widget.store.canDownload)
                        DownloadsScreen(
                          repository: widget.repository,
                          store: widget.store,
                          embedded: true,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: desktop || television
              ? null
              : _selectionMode
              ? _selectionBar()
              : AppBottomNavigation(
                  selectedIndex: _tab,
                  onDestinationSelected: _changeTab,
                  onDestinationDoubleTap: _onTabDoubleTap,
                  destinations: [
                    NavigationDestination(
                      icon: Icon(Icons.smart_display_outlined),
                      selectedIcon: Icon(Icons.smart_display_rounded),
                      label: '首页',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore),
                      label: '发现',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.bookmark_border_rounded),
                      selectedIcon: Icon(Icons.bookmark_rounded),
                      label: '追剧',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.history_rounded),
                      label: '最近观看',
                    ),
                    if (widget.store.canDownload)
                      NavigationDestination(
                        icon: Icon(Icons.download_outlined),
                        selectedIcon: Icon(Icons.download_rounded),
                        label: '下载',
                      ),
                  ],
                ),
        );
        if (!television && !_selectionMode) return scaffold;
        return PopScope(
          canPop:
              !_selectionMode &&
              (!television ||
                  _tab == _feedIndex ||
                  _tab == _discoverIndex && _search.text.isEmpty),
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
        );
      },
    ),
  );

  Widget _catalog({required bool selectionInBody}) {
    final items = _visible;
    final television = AppLayout.isTelevision(context);
    return Column(
      children: [
        if (_searchVisible && !television)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: SearchInput(
              key: ValueKey('search-${_group.id}'),
              controller: _search,
              autofocus: true,
              hint: _searchHint,
              suggestions: _searchSuggestions
                  ? widget.repository.suggestions
                  : null,
              onChanged: _searchChanged,
              onCancel: () => unawaited(widget.repository.cancelSuggestions()),
              onSearch: _submitSearch,
            ),
          ),
        if (_searchVisible &&
            _search.text.trim().isEmpty &&
            widget.store.recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final query in widget.store.recentSearches)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
                              label: Text(query),
                              onPressed: () => _submitSearch(query),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '清空最近搜索',
                  onPressed: () =>
                      saveUserChange(context, widget.store.clearRecentSearches),
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
        CatalogFilters(
          key: ValueKey('filters-${_group.id}'),
          categories: _displayCategories,
          category: _displayCategory,
          error: _categoriesError,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_supportsVipFilter)
                IconButton(
                  tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: () => saveUserChange(
                    context,
                    () => widget.store.setHideVip(!widget.store.hideVip),
                  ),
                  icon: VipIcon(hidden: widget.store.hideVip),
                ),
            ],
          ),
        ),
        if (_showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: RecommendationsScreen(
                repository: widget.repository,
                store: widget.store,
                embedded: true,
              ),
            ),
          )
        else ...[
          if (widget.repository.supportsSourceManagement &&
              (_updateNotice ||
                  _group.sources.any((source) => _updater.busy(source.id))))
            _updateStatus(),
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null && _items.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading || _loadingMore
                        ? null
                        : () => _load(more: _failedMore, force: true),
                    child: const Text('重试'),
                  ),
                  if (widget.repository.supportsSourceManagement)
                    IconButton(
                      tooltip: '站源诊断',
                      onPressed: _manageSources,
                      icon: const Icon(Icons.network_check),
                    ),
                ],
              ),
            ),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: _loading && _items.isEmpty
                  ? const DramaGridSkeleton()
                  : _items.isEmpty && _error != null
                  ? StatusPanel(
                      title: '暂时无法加载',
                      message: _error!,
                      onRetry: () => _load(force: true),
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: _manageSources,
                              child: const Text('站源诊断'),
                            )
                          : null,
                      icon: Icons.wifi_off_rounded,
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: '没有找到匹配的短剧',
                      message: _hideVip
                          ? '可以换个搜索词，或显示 VIP 内容。'
                          : widget.store.sources.length > 1
                          ? '可以换个搜索词或切换站源。'
                          : '可以换个搜索词，或刷新后重试。',
                      onRetry:
                          _hasMore &&
                              !_loadingMore &&
                              (!_onlineSearch ||
                                  _search.text.isEmpty ||
                                  _group.sources.any(
                                    (source) => source.pagedSearch,
                                  ))
                          ? () => _load(more: true)
                          : null,
                      action: '加载更多',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        if (television) {
                          return _televisionGrid(
                            items,
                            constraints.maxWidth,
                            key:
                                'catalog-${_group.id}-$_category-$_submittedQuery',
                            controller: _scroll,
                            footer: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                              child: Center(
                                child: _loadingMore
                                    ? const LoadingHint(
                                        message: '正在加载更多剧集…',
                                        compact: true,
                                      )
                                    : _hasMore
                                    ? RemoteButton(
                                        label: '加载更多',
                                        icon: Icons.expand_more,
                                        onPressed: () => _load(more: true),
                                      )
                                    : const Text('已经看到这里的全部剧集'),
                              ),
                            ),
                          );
                        }
                        final padding = constraints.maxWidth < 600
                            ? 16.0
                            : 24.0;
                        return RefreshIndicator(
                          onRefresh: _refreshCatalog,
                          child: CustomScrollView(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  padding,
                                  0,
                                  padding,
                                  16,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate: dramaGridDelegate(
                                    context,
                                    constraints.maxWidth - 2 * padding,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (_, index) => _catalogTile(items[index]),
                                    childCount: items.length,
                                  ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: Center(
                                    child: _loadingMore
                                        ? const LoadingHint(
                                            message: '正在加载更多剧集…',
                                            compact: true,
                                          )
                                        : _hasMore
                                        ? OutlinedButton.icon(
                                            onPressed: () => _load(more: true),
                                            icon: const Icon(
                                              Icons.expand_more_rounded,
                                            ),
                                            label: const Text('加载更多'),
                                          )
                                        : Text(
                                            '已经看到这里的全部剧集',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_selectionMode && selectionInBody)
            _selectionBar(safeBottom: false),
        ],
      ],
    );
  }

  Widget _selectionBar({bool safeBottom = true}) {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: safeBottom,
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final summary = Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      count == 0
                          ? '最多 ${BatchDownloads.maxDramas} 部'
                          : '下一步选择分集和画质',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
              final next = FilledButton(
                key: const ValueKey('download-selected-dramas'),
                onPressed: count == 0 ? null : _downloadSelected,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(96, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: const Text('下一步'),
              );
              if (constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [summary, const SizedBox(height: 12), next],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 16),
                  next,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _updateStatus() {
    final sources = _group.sources;
    final busy = sources.any((source) => _updater.busy(source.id));
    final messages = <String>[];
    var failed = false;
    for (final source in sources) {
      final status = _updater.status(source.id);
      final error = [
        _updater.error(source.id),
        status?.error ?? '',
        status?.storageError ?? '',
      ].where((value) => value.isNotEmpty).toSet().join('；');
      if (error.isNotEmpty) {
        failed = true;
        messages.add('${source.name}：$error');
      } else if (status != null) {
        messages.add(
          '${source.name}：${status.stage.isEmpty ? '准备更新' : status.stage}'
          '${status.total > 0 ? ' ${status.completed}/${status.total}' : ''}'
          '${!status.running && status.added > 0 ? ' · 新增 ${status.added} 部' : ''}',
        );
      } else if (busy) {
        messages.add('${source.name}：正在启动');
      }
    }
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: failed ? colors.errorContainer : colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                messages.isEmpty ? '准备更新剧库' : messages.join('；'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: failed ? colors.onErrorContainer : colors.onSurface,
                ),
              ),
            ),
            if (busy)
              TextButton(
                onPressed: () => _updater.stop(sources),
                child: const Text('停止'),
              ),
            IconButton(
              tooltip: '查看更新详情',
              onPressed: _manageSources,
              icon: const Icon(Icons.info_outline_rounded, size: 20),
            ),
            if (!busy)
              IconButton(
                tooltip: '收起更新提示',
                onPressed: () => setState(() => _updateNotice = false),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    required String key,
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: ValueKey('tv-grid-$key'),
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}
