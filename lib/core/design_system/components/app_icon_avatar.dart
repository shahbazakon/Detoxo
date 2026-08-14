import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:detoxo/core/design_system/components/cards.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';

/// Directory prefix for the bundled app-icon pack.
const String _iconPackDir = 'assets/images/social_icon_pack/';

/// A rounded app/platform icon.
///
/// Resolution order:
/// 1. [iconBytes] → in-memory icon (device apps, from the native engine);
/// 2. empty `iconUrl` → letter-tile fallback;
/// 3. `http…` → remote icon via [CachedNetworkImage] (remote config);
/// 4. bundled asset path (`assets/…`) → [Image.asset].
///
/// When no icon is available it shows the grey letter tile for the app's initial
/// (`a.png`…`z.png`), and finally [ultimateFallback] (a neutral badge) for names
/// that don't start with a–z.
class AppIconAvatar extends StatelessWidget {
  const AppIconAvatar({
    required this.iconUrl,
    required this.appName,
    this.iconBytes,
    this.size = 34,
    this.borderRadius,
    this.dimmed = false,
    this.ultimateFallback,
    super.key,
  });

  final String iconUrl;
  final String appName;

  /// Raw PNG bytes from the device (takes precedence over [iconUrl]).
  final Uint8List? iconBytes;
  final double size;
  final BorderRadius? borderRadius;

  /// Dims the icon (e.g. an app that isn't installed).
  final bool dimmed;

  /// Shown when there's no icon and no usable letter tile (a non a–z initial).
  /// Defaults to a neutral smartphone badge.
  final Widget? ultimateFallback;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? AppRadius.brMd;
    final fallback = _letterOrBadge(radius);
    final child = _icon(radius, fallback);
    return dimmed ? Opacity(opacity: 0.4, child: child) : child;
  }

  Widget _icon(BorderRadius radius, Widget fallback) {
    final bytes = iconBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }

    if (iconUrl.isEmpty) return fallback;

    if (iconUrl.startsWith('http')) {
      return ClipRRect(
        borderRadius: radius,
        child: CachedNetworkImage(
          imageUrl: iconUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => fallback,
          errorWidget: (_, _, _) => fallback,
        ),
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: Image.asset(
        iconUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  Widget _letterOrBadge(BorderRadius radius) {
    final badge =
        ultimateFallback ??
        IconBadge(size: size, icon: Icons.smartphone_rounded);
    final letter = appName.isEmpty ? '' : appName[0].toLowerCase();
    final isAz =
        letter.length == 1 &&
        letter.codeUnitAt(0) >= 0x61 &&
        letter.codeUnitAt(0) <= 0x7a;
    if (!isAz) return badge;
    return ClipRRect(
      borderRadius: radius,
      child: Image.asset(
        '$_iconPackDir$letter.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => badge,
      ),
    );
  }
}
