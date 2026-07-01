import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';

class ContainersScreen extends StatefulWidget {
  const ContainersScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends State<ContainersScreen> {
  List<ContainerItem> _containers = [];
  String? _error;
  bool _loading = true;
  String? _selectedId;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadContainers();
  }

  Future<void> _loadContainers() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final containers = await widget.apiClient.fetchContainers();
      if (!mounted) {
        return;
      }
      setState(() {
        _containers = containers;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
      await _loadContainers();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  void _watchLogs(String id) {
    setState(() {
      _selectedId = id;
      _logs.clear();
    });

    widget.apiClient.streamContainerLogs(id).listen((line) {
      if (!mounted) {
        return;
      }
      setState(() => _logs.add(line));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Containers', style: theme.textTheme.h3),
            const Spacer(),
            ShadButton.outline(
              onPressed: _loading ? null : _loadContainers,
              child: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: _containers.length,
                    itemBuilder: (context, index) {
                      final container = _containers[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(container.name, style: theme.textTheme.large),
                            Text('${container.image} · ${container.status}', style: theme.textTheme.muted),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                ShadButton.outline(
                                  onPressed: () => _runAction(() => widget.apiClient.startContainer(container.id)),
                                  child: const Text('Start'),
                                ),
                                ShadButton.outline(
                                  onPressed: () => _runAction(() => widget.apiClient.stopContainer(container.id)),
                                  child: const Text('Stop'),
                                ),
                                ShadButton.outline(
                                  onPressed: () => _runAction(() => widget.apiClient.removeContainer(container.id)),
                                  child: const Text('Remove'),
                                ),
                                ShadButton.outline(
                                  onPressed: () => _watchLogs(container.id),
                                  child: const Text('Logs'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (_selectedId != null) ...[
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Logs · $_selectedId', style: theme.textTheme.large),
                        const SizedBox(height: 8),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Text(_logs.join('\n'), style: theme.textTheme.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  List<ImageItem> _images = [];
  String? _error;
  bool _loading = true;
  final _referenceController = TextEditingController(text: 'hello-world');

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  @override
  void dispose() {
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _loadImages() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final images = await widget.apiClient.fetchImages();
      if (!mounted) {
        return;
      }
      setState(() {
        _images = images;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pullImage() async {
    try {
      await widget.apiClient.pullImage(_referenceController.text.trim());
      await _loadImages();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Images', style: theme.textTheme.h3),
            const Spacer(),
            ShadButton.outline(
              onPressed: _loading ? null : _loadImages,
              child: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ShadInput(
                controller: _referenceController,
                placeholder: const Text('Image reference'),
              ),
            ),
            const SizedBox(width: 8),
            ShadButton(
              onPressed: _pullImage,
              child: const Text('Pull'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else
          Expanded(
            child: ListView.builder(
              itemCount: _images.length,
              itemBuilder: (context, index) {
                final image = _images[index];
                final reference = '${image.repository}:${image.tag}';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(reference, style: theme.textTheme.large),
                            Text(image.size, style: theme.textTheme.muted),
                          ],
                        ),
                      ),
                      ShadButton.outline(
                        onPressed: () async {
                          await widget.apiClient.removeImage(reference);
                          await _loadImages();
                        },
                        child: const Text('Remove'),
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
