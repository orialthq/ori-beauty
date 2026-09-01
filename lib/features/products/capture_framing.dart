import 'package:flutter/painting.dart';

/// Where the picture starts in a phone screenshot, as a fraction of its
/// height: below the status bar and below the app's own back arrow and search.
///
/// Set by looking at real captures rather than derived. That chrome is a fixed
/// height and the photo underneath it is not, so no ratio computes this.
const pictureStartsAt = 0.1;

/// A tall screenshot's aspect, used to place a crop when the file has not
/// reported its own size. Nearly every capture this app receives is a phone
/// screen; anything wider falls back to a centred crop.
const _screenshotAspect = 9 / 19.5;

/// Where to anchor [BoxFit.cover] so the crop begins at [pictureStartsAt].
///
/// A wide frame shows a thin band of a tall screenshot and a tall frame shows
/// most of it, so one anchor lands in two different places. Rather than keep a
/// number per frame and tune each, the anchor is worked back from the one
/// thing that is fixed: where the picture begins.
Alignment captureCrop(double frameAspect) {
  final visible = _screenshotAspect / frameAspect;
  if (visible >= 1) return Alignment.center;
  final y = 2 * pictureStartsAt / (1 - visible) - 1;
  return Alignment(0, y.clamp(-1.0, 1.0));
}
