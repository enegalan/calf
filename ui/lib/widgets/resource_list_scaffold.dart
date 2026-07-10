import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/widgets/error_text.dart';

class ResourceListScaffold extends StatelessWidget {
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
  final bool errorAllowsList;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.h3)),
            if (headerActions != null) headerActions!,
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: theme.textTheme.muted),
        ],
        const SizedBox(height: 16),
        ShadInput(
          controller: searchController,
          placeholder: const Text('Search'),
        ),
        if (filter != null) ...[
          const SizedBox(height: 12),
          filter!,
        ],
        const SizedBox(height: 16),
        if (loading)
          Text('Loading...', style: theme.textTheme.muted)
        else if (error != null && !errorAllowsList)
          ErrorText(error: error!)
        else if (empty)
          Text(emptyMessage, style: theme.textTheme.muted)
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
