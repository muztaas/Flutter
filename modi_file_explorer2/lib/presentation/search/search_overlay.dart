import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/search_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/utils/format_bytes.dart';
import '../../core/utils/display_file_name.dart';
import '../../core/utils/font_scaled_spacing.dart';
import '../../core/utils/time_format.dart';
import '../../core/utils/extension_parser.dart';
import '../../core/providers/file_type_categories_provider.dart';
import '../../domain/entities/file_type_category.dart';
import '../../domain/entities/search_folder_candidate.dart';
import '../../domain/entities/search_query.dart';
import '../../domain/entities/search_scope.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/utils/shared_storage_scan_scope.dart';
import '../image_viewer/image_file_preview.dart';
import '../common/file_type_icon.dart';
import '../common/marquee_text.dart';
import '../common/storage_entry_row.dart';

class SearchOverlay extends ConsumerStatefulWidget {
  const SearchOverlay({
    super.key,
    required this.sessionId,
    required this.isActive,
  });

  final String sessionId;
  final bool isActive;

  @override
  ConsumerState<SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends ConsumerState<SearchOverlay> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _extensionsController = TextEditingController();
  final TextEditingController _minimumSizeController = TextEditingController();
  final TextEditingController _maximumSizeController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _resultsScrollController = ScrollController();
  final ScrollController _searchResultsScrollController = ScrollController();
  final ScrollController _filterScrollController = ScrollController();
  int _sizeUnitIndex = 0;

  static const _sizeUnits = ['B', 'KB', 'MB', 'GB'];
  static const _filterSectionMaxHeightFactor = 0.5;
  static const _folderListVisibleRows = 4;
  static const _folderListRowHeight = 50.0;
  static const _filterDefinitions = [
    _SearchFilterDefinition.type,
    _SearchFilterDefinition.extensions,
    _SearchFilterDefinition.modified,
    _SearchFilterDefinition.caseSensitive,
    _SearchFilterDefinition.size,
    _SearchFilterDefinition.sort,
  ];

  @override
  void dispose() {
    _textController.dispose();
    _extensionsController.dispose();
    _minimumSizeController.dispose();
    _maximumSizeController.dispose();
    _focusNode.dispose();
    _resultsScrollController.dispose();
    _searchResultsScrollController.dispose();
    _filterScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SearchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _focusNode.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(foldersFirstProvider, (previous, next) {
      ref
          .read(fileSearchProvider(widget.sessionId).notifier)
          .updateFoldersFirst(next);
    });
    ref.listen<SearchOverlayState>(fileSearchProvider(widget.sessionId), (
      previous,
      next,
    ) {
      if (previous?.isOpen != true && next.isOpen) {
        _textController.text = next.query;
        _syncFilterControllers(next.searchQuery);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.isActive &&
              ref.read(fileSearchProvider(widget.sessionId)).isOpen) {
            _focusNode.requestFocus();
          }
        });
      } else if (previous?.isOpen == true && !next.isOpen) {
        _focusNode.unfocus();
        _textController.clear();
      }
    });
    final search = ref.watch(fileSearchProvider(widget.sessionId));
    final scope = search.scope;
    final settings = ref.watch(appSettingsProvider);
    final visibleResults =
        scope != null &&
            scope.category != null &&
            settings.hideAndroidFoldersInCategoryPages
        ? search.results
              .where(
                (result) =>
                    !SharedStorageScanScope.isInsideAndroidFolder(result.path),
              )
              .toList(growable: false)
        : search.results;
    final categories = ref.watch(fileTypeCategoriesProvider);
    final surface = Theme.of(context).colorScheme.surface;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final visible = search.isOpen && widget.isActive;
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final filterSectionMaxHeight =
              constraints.maxHeight * _filterSectionMaxHeightFactor;
          return IgnorePointer(
            ignoring: !visible,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) {},
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: widget.isActive
                    ? const Duration(milliseconds: 180)
                    : Duration.zero,
                child: Material(
                  color: surface.withValues(alpha: visible ? 0.9 : 0),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Exit search',
                              onPressed: () => ref
                                  .read(
                                    fileSearchProvider(
                                      widget.sessionId,
                                    ).notifier,
                                  )
                                  .close(),
                              icon: const Icon(Icons.arrow_back),
                            ),
                            Expanded(
                              child: Stack(
                                alignment: Alignment.centerLeft,
                                children: [
                                  TextField(
                                    controller: _textController,
                                    focusNode: _focusNode,
                                    textInputAction: TextInputAction.search,
                                    onChanged: ref
                                        .read(
                                          fileSearchProvider(
                                            widget.sessionId,
                                          ).notifier,
                                        )
                                        .onTextChanged,
                                    onSubmitted: (_) => ref
                                        .read(
                                          fileSearchProvider(
                                            widget.sessionId,
                                          ).notifier,
                                        )
                                        .submit(),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                    ),
                                  ),
                                  if (search.query.isEmpty && scope != null)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: MarqueeText(
                                              scope.hintText,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyLarge
                                                  ?.copyWith(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                              styleMode:
                                                  MarqueeStyle.pauseAndLoop,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (search.query.isNotEmpty)
                              IconButton(
                                tooltip: 'Clear search text',
                                onPressed: () {
                                  ref
                                      .read(
                                        fileSearchProvider(
                                          widget.sessionId,
                                        ).notifier,
                                      )
                                      .clearText();
                                  _textController.clear();
                                },
                                icon: const Icon(Icons.close),
                              ),
                            IconButton(
                              tooltip: 'Submit search',
                              onPressed: () => ref
                                  .read(
                                    fileSearchProvider(
                                      widget.sessionId,
                                    ).notifier,
                                  )
                                  .submit(),
                              icon: const Icon(Icons.search),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 40,
                        child: Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Row(
                                  children: [
                                    if (search.isSearching) ...[
                                      const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Expanded(
                                      child: Text(
                                        search.statusText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Filters',
                              onPressed: () => ref
                                  .read(
                                    fileSearchProvider(
                                      widget.sessionId,
                                    ).notifier,
                                  )
                                  .toggleFilters(),
                              icon: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Icon(
                                    Icons.filter_list,
                                    color: search.activeFilterCount > 0
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  if (search.activeFilterCount > 0)
                                    Positioned(
                                      right: -9,
                                      top: -7,
                                      child: Container(
                                        padding: const EdgeInsets.all(3),
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          shape: BoxShape.circle,
                                        ),
                                        constraints: const BoxConstraints(
                                          minWidth: 17,
                                          minHeight: 17,
                                        ),
                                        child: Text(
                                          '${search.activeFilterCount}',
                                          textAlign: TextAlign.center,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onPrimary,
                                                fontSize: 10,
                                              ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        child: search.filtersExpanded
                            ? ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: filterSectionMaxHeight,
                                ),
                                child: Scrollbar(
                                  controller: _filterScrollController,
                                  thumbVisibility: true,
                                  interactive: true,
                                  child: SingleChildScrollView(
                                    controller: _filterScrollController,
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        4,
                                        16,
                                        12,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          for (final definition
                                              in _filterDefinitions)
                                            _buildFilter(
                                              context,
                                              search,
                                              definition,
                                              categories,
                                            ),
                                          _buildFolderSelectionSection(
                                            context,
                                            search,
                                            blacklist: true,
                                          ),
                                          _buildFolderSelectionSection(
                                            context,
                                            search,
                                            blacklist: false,
                                          ),
                                          if (search.validationMessage != null)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 6,
                                              ),
                                              child: Text(
                                                search.validationMessage!,
                                                style: TextStyle(
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.error,
                                                ),
                                              ),
                                            ),
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: TextButton(
                                              onPressed: () {
                                                _sizeUnitIndex = 0;
                                                _minimumSizeController.clear();
                                                _maximumSizeController.clear();
                                                _extensionsController.clear();
                                                ref
                                                    .read(
                                                      fileSearchProvider(
                                                        widget.sessionId,
                                                      ).notifier,
                                                    )
                                                    .resetFilters();
                                              },
                                              child: const Text(
                                                'Reset filters',
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                      Expanded(
                        child: visibleResults.isEmpty
                            ? const SizedBox.expand()
                            : Scrollbar(
                                controller: _searchResultsScrollController,
                                thumbVisibility: true,
                                interactive: true,
                                child: ListView.builder(
                                  controller: _searchResultsScrollController,
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemCount: visibleResults.length,
                                  itemBuilder: (context, index) {
                                    final result = visibleResults[index];
                                    return _buildResultRow(
                                      context,
                                      result,
                                      settings,
                                      () => _openResult(result),
                                    );
                                  },
                                ),
                              ),
                      ),
                      if (bottomInset > 0)
                        Container(
                          height: bottomInset,
                          color: surface.withValues(alpha: visible ? 0.9 : 0),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilter(
    BuildContext context,
    SearchOverlayState search,
    _SearchFilterDefinition definition,
    List<FileTypeCategory> categories,
  ) {
    final query = search.searchQuery;
    final controller = ref.read(fileSearchProvider(widget.sessionId).notifier);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelLarge;
    switch (definition) {
      case _SearchFilterDefinition.type:
        final filesOnly =
            query.extensions.isNotEmpty ||
            query.minimumSize != null ||
            query.maximumSize != null;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Type', style: labelStyle),
              const SizedBox(height: 6),
              SegmentedButton<SearchItemType>(
                segments: [
                  if (filesOnly)
                    const ButtonSegment(
                      value: SearchItemType.filesOnly,
                      label: Text('Files'),
                    )
                  else ...[
                    const ButtonSegment(
                      value: SearchItemType.filesOnly,
                      label: Text('Files'),
                    ),
                    const ButtonSegment(
                      value: SearchItemType.foldersOnly,
                      label: Text('Folders'),
                    ),
                    const ButtonSegment(
                      value: SearchItemType.filesAndFolders,
                      label: Text('Both'),
                    ),
                  ],
                ],
                selected: {filesOnly ? SearchItemType.filesOnly : query.type},
                onSelectionChanged: filesOnly
                    ? null
                    : (selection) => controller.updateFilters(
                        query.copyWith(type: selection.first),
                      ),
              ),
              if (filesOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Files only while an extension or size filter is set.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        );
      case _SearchFilterDefinition.extensions:
        final selected = query.extensions;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Extensions', style: labelStyle),
              TextField(
                controller: _extensionsController,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Add extensions (e.g. pdf, md)',
                  suffixIcon: IconButton(
                    tooltip: 'Add extensions',
                    icon: const Icon(Icons.add),
                    onPressed: () => _commitExtensions(query),
                  ),
                ),
                onSubmitted: (_) => _commitExtensions(query),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final name in const [
                    'Image',
                    'Documents',
                    'Audio',
                    'Video',
                    'Archives',
                    'Text',
                  ])
                    ActionChip(
                      label: Text(name == 'Image' ? 'Images' : name),
                      onPressed: () {
                        final extensions =
                            categories
                                .where((category) => category.name == name)
                                .firstOrNull
                                ?.extensions
                                .toSet() ??
                            <String>{};
                        _extensionsController.text = extensions.join(', ');
                        controller.updateFilters(
                          query.copyWith(extensions: extensions),
                        );
                      },
                    ),
                  if (selected.isNotEmpty)
                    ActionChip(
                      label: const Text('Clear extensions'),
                      onPressed: () {
                        _extensionsController.clear();
                        controller.updateFilters(
                          query.copyWith(extensions: const {}),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      case _SearchFilterDefinition.modified:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Date modified', style: labelStyle),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                      query.modifiedFrom == null
                          ? 'From'
                          : 'From ${_dateLabel(query.modifiedFrom!)}',
                    ),
                    onPressed: () => _pickDate(query, isFrom: true),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                      query.modifiedTo == null
                          ? 'To'
                          : 'To ${_dateLabel(query.modifiedTo!)}',
                    ),
                    onPressed: () => _pickDate(query, isFrom: false),
                  ),
                  if (query.modifiedFrom != null)
                    IconButton(
                      tooltip: 'Clear From date',
                      onPressed: () => _clearDate(query, isFrom: true),
                      icon: const Icon(Icons.close),
                    ),
                  if (query.modifiedTo != null)
                    IconButton(
                      tooltip: 'Clear To date',
                      onPressed: () => _clearDate(query, isFrom: false),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ],
          ),
        );
      case _SearchFilterDefinition.caseSensitive:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Case sensitive', style: labelStyle),
          value: query.caseSensitive,
          onChanged: (value) =>
              controller.updateFilters(query.copyWith(caseSensitive: value)),
        );
      case _SearchFilterDefinition.size:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Size range', style: labelStyle),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minimumSizeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Minimum',
                      ),
                      onSubmitted: (_) => _commitSizeRange(query),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _maximumSizeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Maximum',
                      ),
                      onSubmitted: (_) => _commitSizeRange(query),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 78,
                    child: DropdownButtonFormField<int>(
                      initialValue: _sizeUnitIndex,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Unit',
                      ),
                      items: [
                        for (var i = 0; i < _sizeUnits.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(_sizeUnits[i]),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _sizeUnitIndex = value);
                        _commitSizeRange(query);
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Apply size range',
                    onPressed: () => _commitSizeRange(query),
                    icon: const Icon(Icons.check),
                  ),
                  if (query.minimumSize != null || query.maximumSize != null)
                    IconButton(
                      tooltip: 'Clear size range',
                      onPressed: () {
                        _minimumSizeController.clear();
                        _maximumSizeController.clear();
                        controller.updateFilters(
                          query.copyWith(
                            clearMinimumSize: true,
                            clearMaximumSize: true,
                          ),
                        );
                      },
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ],
          ),
        );
      case _SearchFilterDefinition.sort:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Text('Sort', style: labelStyle),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<SearchSortField>(
                  isExpanded: true,
                  value: query.sortField,
                  items: const [
                    DropdownMenuItem(
                      value: SearchSortField.name,
                      child: Text('Name'),
                    ),
                    DropdownMenuItem(
                      value: SearchSortField.modified,
                      child: Text('Date modified'),
                    ),
                    DropdownMenuItem(
                      value: SearchSortField.size,
                      child: Text('Size'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      controller.updateFilters(
                        query.copyWith(sortField: value),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<SearchSortDirection>(
                value: query.sortDirection,
                items: const [
                  DropdownMenuItem(
                    value: SearchSortDirection.ascending,
                    child: Text('Ascending'),
                  ),
                  DropdownMenuItem(
                    value: SearchSortDirection.descending,
                    child: Text('Descending'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.updateFilters(
                      query.copyWith(sortDirection: value),
                    );
                  }
                },
              ),
            ],
          ),
        );
    }
  }

  Widget _buildFolderSelectionSection(
    BuildContext context,
    SearchOverlayState search, {
    required bool blacklist,
  }) {
    final selectedIds = blacklist
        ? search.searchQuery.excludedFolders
        : search.searchQuery.includedFolders;
    final expanded = blacklist
        ? search.blacklistExpanded
        : search.whitelistExpanded;
    final candidates = search.folderCandidates;
    final title = blacklist ? 'Blacklist' : 'Whitelist';
    final theme = Theme.of(context);
    final visibleRows = candidates.length < _folderListVisibleRows
        ? candidates.length
        : _folderListVisibleRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('$title (${selectedIds.length})'),
          trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          onTap: () => ref
              .read(fileSearchProvider(widget.sessionId).notifier)
              .toggleFolderList(blacklist: blacklist),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOut,
          child: expanded
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!blacklist)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Folders also in the Blacklist are excluded.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (search.folderCandidatesLoading)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (search.folderCandidatesError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Could not load folders: ${search.folderCandidatesError}',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      )
                    else if (candidates.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No folders here'),
                      )
                    else
                      SizedBox(
                        height:
                            visibleRows *
                            fontScaledSpacing(context, _folderListRowHeight),
                        child: Scrollbar(
                          controller: _resultsScrollController,
                          thumbVisibility: true,
                          interactive: true,
                          child: ListView.builder(
                            controller: _resultsScrollController,
                            primary: false,
                            itemExtent: fontScaledSpacing(
                              context,
                              _folderListRowHeight,
                            ),
                            itemCount: candidates.length,
                            itemBuilder: (context, index) {
                              final candidate = candidates[index];
                              final selected = selectedIds.contains(
                                candidate.id,
                              );
                              return _buildFolderCandidateRow(
                                context,
                                candidate,
                                selected: selected,
                                onChanged: (_) => ref
                                    .read(
                                      fileSearchProvider(
                                        widget.sessionId,
                                      ).notifier,
                                    )
                                    .toggleFolderSelection(
                                      candidate.id,
                                      blacklist: blacklist,
                                    ),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildFolderCandidateRow(
    BuildContext context,
    SearchFolderCandidate candidate, {
    required bool selected,
    required ValueChanged<bool?> onChanged,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!selected),
      child: Row(
        children: [
          Checkbox(value: selected, onChanged: onChanged),
          FileTypeIcon(extension: '', isFolder: true),
          const SizedBox(width: 8),
          Expanded(
            child: MarqueeText(
              candidate.name,
              style: theme.textTheme.bodyMedium,
              styleMode: MarqueeStyle.pauseAndLoop,
            ),
          ),
        ],
      ),
    );
  }

  void _commitExtensions(SearchQuery query) {
    final parsed = parseExtensions(_extensionsController.text);
    if (parsed.errors.isNotEmpty) {
      ref
          .read(fileSearchProvider(widget.sessionId).notifier)
          .updateFilters(query, validationMessage: parsed.errors.join(' '));
      return;
    }
    _extensionsController.text = parsed.extensions.join(', ');
    ref
        .read(fileSearchProvider(widget.sessionId).notifier)
        .updateFilters(query.copyWith(extensions: parsed.extensions.toSet()));
  }

  Future<void> _pickDate(SearchQuery query, {required bool isFrom}) async {
    final current = isFrom ? query.modifiedFrom : query.modifiedTo;
    final selected = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(1970),
      lastDate: DateTime(2200),
    );
    if (selected == null || !mounted) return;
    final next = isFrom
        ? query.copyWith(
            modifiedFrom: DateTime(selected.year, selected.month, selected.day),
          )
        : query.copyWith(
            modifiedTo: DateTime(selected.year, selected.month, selected.day),
          );
    final invalid =
        next.modifiedFrom != null &&
        next.modifiedTo != null &&
        next.modifiedFrom!.isAfter(next.modifiedTo!);
    ref
        .read(fileSearchProvider(widget.sessionId).notifier)
        .updateFilters(
          next,
          validationMessage: invalid
              ? 'From date must be on or before To date.'
              : null,
        );
  }

  void _clearDate(SearchQuery query, {required bool isFrom}) {
    final next = isFrom
        ? query.copyWith(clearModifiedFrom: true)
        : query.copyWith(clearModifiedTo: true);
    final invalid =
        next.modifiedFrom != null &&
        next.modifiedTo != null &&
        next.modifiedFrom!.isAfter(next.modifiedTo!);
    ref
        .read(fileSearchProvider(widget.sessionId).notifier)
        .updateFilters(
          next,
          validationMessage: invalid
              ? 'From date must be on or before To date.'
              : null,
        );
  }

  void _commitSizeRange(SearchQuery query) {
    int? parseSize(String text) {
      final value = text.trim();
      if (value.isEmpty) return null;
      final number = int.tryParse(value);
      final multiplier = 1 << (10 * _sizeUnitIndex);
      if (number == null ||
          number < 0 ||
          number > 0x7fffffffffffffff ~/ multiplier) {
        return -1;
      }
      return number * multiplier;
    }

    final minimum = parseSize(_minimumSizeController.text);
    final maximum = parseSize(_maximumSizeController.text);
    final invalid = minimum == -1 || maximum == -1;
    final inverted =
        !invalid && minimum != null && maximum != null && minimum > maximum;
    if (invalid || inverted) {
      ref
          .read(fileSearchProvider(widget.sessionId).notifier)
          .updateFilters(
            query,
            validationMessage: invalid
                ? 'Enter a valid non-negative whole-number size.'
                : 'Minimum size must not exceed maximum size.',
          );
      return;
    }
    ref
        .read(fileSearchProvider(widget.sessionId).notifier)
        .updateFilters(
          query.copyWith(
            minimumSize: minimum,
            clearMinimumSize: minimum == null,
            maximumSize: maximum,
            clearMaximumSize: maximum == null,
          ),
        );
  }

  void _syncFilterControllers(SearchQuery query) {
    _extensionsController.text = query.extensions.join(', ');
    _minimumSizeController.text = query.minimumSize == null
        ? ''
        : (query.minimumSize! / (1 << (10 * _sizeUnitIndex))).toStringAsFixed(
            0,
          );
    _maximumSizeController.text = query.maximumSize == null
        ? ''
        : (query.maximumSize! / (1 << (10 * _sizeUnitIndex))).toStringAsFixed(
            0,
          );
  }

  Widget _buildResultRow(
    BuildContext context,
    SearchResult result,
    AppSettings settings,
    VoidCallback onTap,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final nameStyle = textTheme.titleMedium?.copyWith(
      fontSize: (textTheme.titleMedium?.fontSize ?? 16) + 1,
    );
    final pathStyle = textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final showDetails =
        (result.isDirectory && settings.showFolderItemCount) ||
        (!result.isDirectory && settings.showFileSize) ||
        settings.showModifiedDate ||
        settings.showModifiedTime;
    final details = <String>[
      if (result.isDirectory &&
          settings.showFolderItemCount &&
          result.itemCount != null)
        '${result.itemCount} ${result.itemCount == 1 ? 'item' : 'items'}',
      if (!result.isDirectory && settings.showFileSize && result.size != null)
        formatBytes(result.size!),
      if (result.modified != null && settings.showModifiedDate)
        _dateLabel(result.modified!),
      if (result.modified != null && settings.showModifiedTime)
        _timeLabel(result.modified!, settings.use24HourTime),
    ];
    return StorageEntryRow(
      leading: _resultLeading(context, result),
      detailsEnabled: true,
      detailsHeight: showDetails ? 68 : 52,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MarqueeText(
            displayFileName(
              result.name,
              showExtension: ref.watch(appSettingsProvider).showFileExtension,
              isDirectory: result.isDirectory,
            ),
            style: nameStyle,
            styleMode: MarqueeStyle.pauseAndLoop,
          ),
          const SizedBox(height: 2),
          MarqueeText(
            result.containingPath,
            style: pathStyle,
            styleMode: MarqueeStyle.pauseAndLoop,
          ),
          if (details.isNotEmpty)
            Text(
              details.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: pathStyle,
            ),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _resultLeading(BuildContext context, SearchResult result) {
    if (result.isDirectory) {
      return FileTypeIcon(extension: '', isFolder: true);
    }
    final extensionStart = result.name.lastIndexOf('.');
    final extension = extensionStart < 0
        ? ''
        : result.name.substring(extensionStart).toLowerCase();
    if (extension == '.apk') {
      return FileTypeIcon(extension: extension, path: result.path);
    }
    if (ref.read(fileSearchProvider(widget.sessionId)).scope?.category ==
        SearchCategory.documents) {
      return FileTypeIcon(extension: extension);
    }
    if (ref.read(fileSearchProvider(widget.sessionId)).scope?.category ==
        SearchCategory.videos) {
      return FileTypeIcon(extension: extension, path: result.path);
    }
    if (ref.read(fileSearchProvider(widget.sessionId)).scope?.category ==
        SearchCategory.audio) {
      return FileTypeIcon(extension: extension);
    }
    if (ref.read(fileSearchProvider(widget.sessionId)).scope?.category ==
        SearchCategory.archives) {
      return FileTypeIcon(extension: extension);
    }
    final category = FileTypeCategory.categoryForExtension(
      extension,
      categories: ref.read(fileTypeCategoriesProvider),
    );
    if (category == 'Video') {
      return FileTypeIcon(extension: extension, path: result.path);
    }
    if (category == 'Image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 36,
          height: 36,
          child: ImageFilePreview(
            path: result.path,
            fit: BoxFit.cover,
            loadingBuilder: (_) => FileTypeIcon(extension: extension),
            errorBuilder: (_, _, _) => FileTypeIcon(extension: extension),
          ),
        ),
      );
    }
    return FileTypeIcon(extension: extension);
  }

  Future<void> _openResult(SearchResult result) async {
    final available = await ref
        .read(fileSearchProvider(widget.sessionId).notifier)
        .openResult(result);
    if (!mounted || available) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This item is no longer available')),
    );
  }

  String _dateLabel(DateTime modified) =>
      '${modified.year.toString().padLeft(4, '0')}-'
      '${modified.month.toString().padLeft(2, '0')}-'
      '${modified.day.toString().padLeft(2, '0')}';

  String _timeLabel(DateTime modified, bool use24HourTime) =>
      formatClockTime(modified, use24HourTime: use24HourTime);
}

enum _SearchFilterDefinition {
  type,
  extensions,
  modified,
  caseSensitive,
  size,
  sort,
}
