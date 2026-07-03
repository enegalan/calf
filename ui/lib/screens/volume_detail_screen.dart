import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/files_panel.dart';

enum _VolumeDetailTab { storedData, containersInUse }

class VolumeDetailView extends StatefulWidget {
  const VolumeDetailView({
    super.key,
    required this.volumeName,
    required this.apiClient,
    required this.onBack,
    required this.onRemoved,
  });

  final String volumeName;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final Future<void> Function() onRemoved;

  @override
  State<VolumeDetailView> createState() => _VolumeDetailViewState();
}

class _VolumeDetailViewState extends State<VolumeDetailView> {
  _VolumeDetailTab _tab = _VolumeDetailTab.storedData;
  VolumeDetail? _detail;
  List<VolumeContainerUsage> _containers = [];
  bool _detailLoading = true;
  bool _containersLoading = false;
  String? _detailError;
  String? _containersError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
    _loadContainers();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _detailLoading = true;
      _detailError = null;
    });

    try {
      final detail = await widget.apiClient.fetchVolumeDetail(widget.volumeName);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _detailError = error.toString();
        _detailLoading = false;
      });
    }
  }

  void _selectTab(_VolumeDetailTab tab) {
    if (_tab == tab) {
      return;
    }

    setState(() => _tab = tab);
    if (tab == _VolumeDetailTab.containersInUse) {
      _loadContainers();
    }
  }

  Future<void> _loadContainers() async {
    setState(() {
      _containersLoading = true;
      _containersError = null;
    });

    try {
      final containers = await widget.apiClient.fetchVolumeContainers(widget.volumeName);
      if (!mounted) {
        return;
      }
      setState(() {
        _containers = containers;
        _containersLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _containersError = error.toString();
        _containersLoading = false;
      });
    }
  }

  Future<void> _removeVolume() async {
    setState(() {
      _busy = true;
    });

    try {
      await widget.apiClient.removeVolume(widget.volumeName);
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      await widget.onRemoved();
      widget.onBack();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _detailError = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final detail = _detail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CalfButton.ghost(
              onPressed: widget.onBack,
              child: Icon(LucideIcons.chevronLeft, size: 18, color: theme.colorScheme.foreground),
            ),
            const SizedBox(width: 4),
            Text('Volumes', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Expanded(
              child: Text(
                widget.volumeName,
                style: theme.textTheme.muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.hardDrive, size: 20, color: theme.colorScheme.foreground),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.volumeName,
                          style: theme.textTheme.h3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_detailLoading)
                    Text('Loading...', style: theme.textTheme.muted)
                  else if (_detailError != null)
                    Text(_detailError!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive))
                  else if (detail != null) ...[
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: detail.inUse ? const Color(0xFF22C55E) : theme.colorScheme.mutedForeground,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          detail.inUse ? 'In use' : 'Not in use',
                          style: theme.textTheme.large,
                        ),
                      ],
                    ),
                    if (detail.created.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('Created ${detail.created}', style: theme.textTheme.muted),
                    ],
                  ],
                ],
              ),
            ),
            CalfButton.destructive(
              enabled: !_busy,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: _removeVolume,
              child: Icon(LucideIcons.trash2, size: 16, color: theme.colorScheme.destructiveForeground),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _VolumeTabBar(
          theme: theme,
          selected: _tab,
          onSelected: _selectTab,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: switch (_tab) {
            _VolumeDetailTab.storedData => FilesPanel(
                theme: theme,
                loadDirectory: (path) => widget.apiClient.fetchVolumeFiles(widget.volumeName, path: path),
              ),
            _VolumeDetailTab.containersInUse => _ContainersInUseTab(
                theme: theme,
                loading: _containersLoading,
                error: _containersError,
                containers: _containers,
              ),
          },
        ),
      ],
    );
  }
}

class _VolumeTabBar extends StatelessWidget {
  const _VolumeTabBar({
    required this.theme,
    required this.selected,
    required this.onSelected,
  });

  final ShadThemeData theme;
  final _VolumeDetailTab selected;
  final ValueChanged<_VolumeDetailTab> onSelected;

  @override
  Widget build(BuildContext context) {
    const tabs = _VolumeDetailTab.values;
    const labels = ['Stored data', 'Container in-use'];

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < tabs.length; index++) ...[
            if (index > 0) const SizedBox(width: 20),
            _VolumeTabButton(
              theme: theme,
              label: labels[index],
              selected: selected == tabs[index],
              onTap: () => onSelected(tabs[index]),
            ),
          ],
        ],
      ),
    );
  }
}

class _VolumeTabButton extends StatelessWidget {
  const _VolumeTabButton({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ShadThemeData theme;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.colorScheme.primary : const Color(0x00000000),
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.small.copyWith(
            color: selected ? theme.colorScheme.foreground : theme.colorScheme.mutedForeground,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _ContainersInUseTab extends StatelessWidget {
  const _ContainersInUseTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.containers,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final List<VolumeContainerUsage> containers;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Text('Loading containers...', style: theme.textTheme.muted);
    }

    if (error != null) {
      return Text(error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive));
    }

    if (containers.isEmpty) {
      return Text('No containers are using this volume.', style: theme.textTheme.muted);
    }

    final labelStyle = theme.textTheme.small.copyWith(
      color: theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text('Container name', style: labelStyle)),
              Expanded(flex: 3, child: Text('Image', style: labelStyle)),
              Expanded(child: Text('Port', style: labelStyle)),
              Expanded(flex: 2, child: Text('Target', style: labelStyle)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: containers.length,
            separatorBuilder: (_, _) => Container(height: 1, color: theme.colorScheme.border),
            itemBuilder: (context, index) {
              final container = containers[index];

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(
                  children: [
                    Icon(LucideIcons.box, size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: Text(
                        container.name,
                        style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(container.image, style: theme.textTheme.muted, overflow: TextOverflow.ellipsis),
                    ),
                    Expanded(
                      child: Text(
                        container.port,
                        style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(container.target, style: theme.textTheme.muted, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
