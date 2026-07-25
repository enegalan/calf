import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Kind of leading icon shown on build dependency / result rows.
enum BuildRowIconKind {
  /// Generic unknown artifact or image.
  placeholder,

  /// Provenance / attestation artifact.
  provenance,

  /// Image dependency link (custom two-tone SVG).
  dependency,
}

/// Picks the icon kind for a build dependency source reference.
BuildRowIconKind buildDependencyIconKind(String source) {
  // Brand-specific SVGs can be added later; until then image deps use placeholder.
  return BuildRowIconKind.placeholder;
}

/// Picks the icon kind for a build result artifact name.
BuildRowIconKind buildResultIconKind(String name) {
  final lower = name.trim().toLowerCase();
  if (lower.isEmpty) {
    return BuildRowIconKind.placeholder;
  }
  if (lower.contains('provenance') || lower.contains('slsa')) {
    return BuildRowIconKind.provenance;
  }
  if (lower.contains('sbom') ||
      lower.contains('spdx') ||
      lower.contains('cyclonedx')) {
    return BuildRowIconKind.provenance;
  }
  return BuildRowIconKind.placeholder;
}

/// Asset path for the shared images / unknown-artifact placeholder SVG.
const String buildPlaceholderIconAsset = 'assets/icons/build/placeholder.svg';

/// Asset path for the custom dependency chain SVG.
const String buildDependencyIconAsset = 'assets/icons/build/dependency.svg';

/// Renders a build-row leading icon for [kind] (Lucide or custom SVG).
class BuildRowIcon extends StatelessWidget {
  /// Creates a [BuildRowIcon] for [kind].
  const BuildRowIcon({super.key, required this.kind, this.size = 22});

  final BuildRowIconKind kind;
  final double size;

  /// Builds the Lucide or SVG icon for [kind].
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (kind) {
      case BuildRowIconKind.placeholder:
        return SvgPicture.asset(
          buildPlaceholderIconAsset,
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(
            theme.colorScheme.onSurfaceVariant,
            BlendMode.srcIn,
          ),
        );
      case BuildRowIconKind.provenance:
        return Icon(
          LucideIcons.telescope,
          size: size,
          color: theme.colorScheme.onSurfaceVariant,
        );
      case BuildRowIconKind.dependency:
        return SvgPicture.asset(
          buildDependencyIconAsset,
          width: size,
          height: size,
        );
    }
  }
}
