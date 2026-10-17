import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/search_provider.dart';
import '../../domain/entities/search_scope.dart';
import '../../domain/entities/search_result.dart';

class SearchActionButton extends ConsumerWidget {
  const SearchActionButton({
    super.key,
    required this.sessionId,
    this.scope,
    this.onResultSelected,
  });

  final String sessionId;
  final SearchScope? scope;
  final Future<void> Function(SearchResult result)? onResultSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Search',
      onPressed: scope == null
          ? null
          : () => ref
                .read(fileSearchProvider(sessionId).notifier)
                .open(scope!, onResultSelected: onResultSelected),
      icon: const Icon(Icons.search),
    );
  }
}
