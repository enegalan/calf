import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/widgets/error_text.dart';
import 'package:ui/theme/calf_theme.dart';

class ResourceListScaffold extends StatelessWidget {
  /// Lays out a searchable resource list with loading, error, and empty states.
  const ResourceListScaffold({
    super.key,
    required this.title,
    required this.searchController,
    required this.loading,
    required this.error,
    required this.empty,
    required this.emptyMessage,
    required this.itemCount,
    required this.itemBuilder,
    this.subtitle,
    this.filter,
    this.headerActions,
    this.emptyAction,
    this.errorAllowsList = false,
  });

  final String title;
  final String? subtitle;
  final TextEditingController searchController;
  final bool loading;
  final Object? error;
  final bool empty;
  final String emptyMessage;
  final int itemCount;
  final Widget? Function(BuildContext context, int index) itemBuilder;
  final Widget? filter;
  final Widget? headerActions;
  final Widget? emptyAction;
  final bool errorAllowsList;

  /// Builds the list scaffold with search, filter, and content area.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.headlineSmall)),
            ?headerActions,
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: CalfTheme.muted(theme)),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: searchController,
          decoration: const InputDecoration(
            hintText: 'Search',
            prefixIcon: Icon(LucideIcons.search, size: 16),
          ),
        ),
        if (filter != null) ...[const SizedBox(height: 12), filter!],
        const SizedBox(height: 16),
        if (loading)
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Text('Loading...', style: CalfTheme.muted(theme)),
            ],
          )
        else if (error != null && !errorAllowsList)
          ErrorText(error: error!)
        else if (empty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    emptyMessage,
                    textAlign: TextAlign.center,
                    style: CalfTheme.muted(theme),
                  ),
                  if (emptyAction != null) ...[
                    const SizedBox(height: 16),
                    emptyAction!,
                  ],
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: itemCount,
              itemBuilder: itemBuilder,
            ),
          ),
        if (error != null && errorAllowsList) ...[
          const SizedBox(height: 12),
          ErrorText(error: error!),
        ],
      ],
    );
  }
}
