import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import 'place_map_links.dart';
import '../domain/portable_tip_package.dart';

final class ContentShareService {
  const ContentShareService();

  Future<ShareResult> shareCard({
    required GlobalKey previewKey,
    required String title,
    String? placeName,
    String? placeAddress,
    String? placeSearchArea,
    Rect? sharePositionOrigin,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        previewKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('Share card preview is not ready.');
    }
    // The preview is 360×450 logical pixels; 3× produces a social-ready
    // 1080×1350 (4:5) card consistently across devices.
    final image = await boundary.toImage(pixelRatio: 3);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Share card could not be rendered.');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return SharePlus.instance.share(
        ShareParams(
          title: 'luffi 정보 카드',
          subject: title,
          text: buildCardShareText(
            placeName: placeName,
            placeAddress: placeAddress,
            placeSearchArea: placeSearchArea,
          ),
          files: [
            XFile.fromData(Uint8List.fromList(bytes), mimeType: 'image/png'),
          ],
          fileNameOverrides: ['${_safeFileName(title)}-card.png'],
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
    } finally {
      image.dispose();
    }
  }

  Future<ShareResult> sharePortableTip({
    required PortableTipPackage tip,
    Rect? sharePositionOrigin,
  }) {
    final bytes = PortableTipPackageCodec.encodeUtf8(tip);
    return SharePlus.instance.share(
      ShareParams(
        title: 'luffi로 보내기',
        subject: tip.title,
        files: [
          XFile.fromData(bytes, mimeType: PortableTipPackageCodec.mimeType),
        ],
        fileNameOverrides: [
          '${_safeFileName(tip.title)}.${PortableTipPackageCodec.fileExtension}',
        ],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  /// Shares only the clickable map URLs.
  ///
  /// Some chat clients (notably KakaoTalk) intentionally keep only the image
  /// when an Android `ACTION_SEND` contains both `EXTRA_STREAM` and
  /// `EXTRA_TEXT`. Sending the URLs as a text-only follow-up makes them usable
  /// without requiring a Kakao SDK key or a hosted landing page.
  Future<ShareResult> shareMapLinks({
    String? placeName,
    String? placeAddress,
    String? placeSearchArea,
    Rect? sharePositionOrigin,
  }) {
    final text = buildCardShareText(
      placeName: placeName,
      placeAddress: placeAddress,
      placeSearchArea: placeSearchArea,
    );
    if (text == null) {
      throw StateError('A place is required to share map links.');
    }
    return SharePlus.instance.share(
      ShareParams(
        title: 'luffi 지도 링크',
        text: text,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}

/// Extra text sent alongside the social image card.
///
/// Share targets detect the three HTTPS URLs as tappable links. A place-free
/// card stays image-only instead of adding irrelevant copy.
String? buildCardShareText({
  String? placeName,
  String? placeAddress,
  String? placeSearchArea,
}) {
  final links = PlaceMapLinks.fromPlace(
    name: placeName,
    address: placeAddress,
    searchArea: placeSearchArea,
  );
  if (links == null) return null;
  return links.shareText;
}

/// Whether to offer the map URLs as a second, text-only message.
///
/// Some share targets omit text attached to an image, and Android direct-share
/// shortcuts do not always report which app was selected. Offer the follow-up
/// after every successful place-card share so the links are never silently
/// lost.
bool shouldOfferMapLinkFollowUp({
  required ShareResult result,
  required String? mapShareText,
}) {
  return mapShareText != null && result.status == ShareResultStatus.success;
}

String _safeFileName(String value) {
  final normalized = value
      .replaceAll(RegExp(r'[^0-9A-Za-z가-힣 _-]'), '')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  final shortened = String.fromCharCodes(normalized.runes.take(40));
  return shortened.isEmpty ? 'luffi-tip' : shortened;
}
