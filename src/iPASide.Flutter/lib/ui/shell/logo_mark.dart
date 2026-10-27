import 'package:flutter/material.dart';

/// The brand mark: an app tile side-loading into an iPhone.
///
/// This is the same artwork the executable and the installer ship
/// (`packaging/brand/mark-source.png`, cut by `packaging/make-icon.py` to
/// `app_icon.ico`, to `docs/brand/icon.png` and to the variants below), so the
/// window, the taskbar and the installer can never drift apart. Redrawing it as
/// vector was tried and rejected: an approximation is not the mark.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 26});

  final double size;

  /// Artwork cut at each size the UI draws, smallest first.
  ///
  /// Nothing is scaled at run time. Handing Flutter the 512px master and a
  /// `cacheWidth` did keep memory down, but the decoder's scaler is cruder than
  /// the Lanczos pass in `make-icon.py`, and shrinking 512 to 96 that way left the
  /// hero mark with visibly stair-stepped corners — the kind of thing that is
  /// invisible in a screenshot and obvious on a real screen. Each entry has
  /// `1.5x`, `2.0x` and `3.0x` neighbours that Flutter selects by device pixel
  /// ratio on its own, so the chosen file is already the right number of pixels.
  static const List<({double upTo, String asset})> _variants =
      <({double upTo, String asset})>[
    (upTo: 26, asset: 'assets/brand/mark.png'),
    (upTo: 96, asset: 'assets/brand/mark-hero.png'),
  ];

  /// The smallest cut that is at least [size], or the largest one there is.
  String get _asset {
    for (final ({double upTo, String asset}) variant in _variants) {
      if (size <= variant.upTo) return variant.asset;
    }
    return _variants.last.asset;
  }

  @override
  Widget build(BuildContext context) => Image.asset(
        _asset,
        width: size,
        height: size,
        // Only ever a small correction — the variant is chosen to match — but a
        // bicubic one, so an unusual pixel ratio does not reintroduce hard edges.
        filterQuality: FilterQuality.high,
      );
}
