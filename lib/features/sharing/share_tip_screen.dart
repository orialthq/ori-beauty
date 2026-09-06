import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/luffi_brand.dart';
import '../../data/content_share_service.dart';
import '../../domain/models.dart';
import '../../domain/portable_tip_package.dart';

final class ShareTipScreen extends StatefulWidget {
  const ShareTipScreen({required this.capture, super.key});

  final CaptureRecord capture;

  static Future<void> open(BuildContext context, CaptureRecord capture) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ShareTipScreen(capture: capture)),
    );
  }

  @override
  State<ShareTipScreen> createState() => _ShareTipScreenState();
}

final class _ShareTipScreenState extends State<ShareTipScreen> {
  static const _maxSelectedDetails = 6;
  static const _shareService = ContentShareService();

  final _cardKey = GlobalKey();
  final _messageController = TextEditingController();
  late final List<_SelectableTipDetail> _details;
  final Set<String> _selectedIds = {};
  var _sharingCard = false;
  var _sharingLinks = false;
  var _sharingPackage = false;

  StructuredContentAnalysis get _analysis =>
      widget.capture.analysis!.structuredContent!;

  @override
  void initState() {
    super.initState();
    _details = _buildDetails(widget.capture);
    _selectedIds.addAll(_defaultSelection(_details));
    _messageController.addListener(_refreshPreview);
  }

  @override
  void dispose() {
    _messageController
      ..removeListener(_refreshPreview)
      ..dispose();
    super.dispose();
  }

  void _refreshPreview() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final title = _analysis.title.value?.trim().isNotEmpty == true
        ? _analysis.title.value!
        : '제목 없음';
    final selectedDetails = _details
        .where((detail) => _selectedIds.contains(detail.id))
        .toList(growable: false);
    final place = _analysis.place;
    final sendsMapLinks =
        place?.name?.trim().isNotEmpty == true ||
        place?.address?.trim().isNotEmpty == true;

    return Scaffold(
      appBar: AppBar(title: const Text('정보 보내기')),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          36 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '친구에게 건넬 카드',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            Semantics(
              key: const Key('share-card-preview'),
              label: '공유 카드 미리보기',
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.topCenter,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    _GiftTipCard.cornerRadius,
                  ),
                  child: RepaintBoundary(
                    key: _cardKey,
                    child: SizedBox(
                      width: 360,
                      height: 450,
                      child: _GiftTipCard(
                        title: title,
                        summary: _analysis.summary,
                        tags: widget.capture.contentTags,
                        message: _messageController.text,
                        details: selectedDetails,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            _LetterComposer(
              controller: _messageController,
              onSuggestion: _useMessageSuggestion,
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '함께 보낼 내용',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '${_selectedIds.length} / $_maxSelectedDetails',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_details.isEmpty)
              const _NoExtraDetails()
            else
              Material(
                color: AppTheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: AppTheme.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var index = 0; index < _details.length; index++) ...[
                      _DetailChoiceTile(
                        detail: _details[index],
                        selected: _selectedIds.contains(_details[index].id),
                        onChanged: (selected) =>
                            _toggleDetail(_details[index], selected),
                      ),
                      if (index != _details.length - 1)
                        const Divider(indent: 18, endIndent: 18),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 28),
            Builder(
              builder: (buttonContext) => SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _sharingCard || _sharingLinks || _sharingPackage
                      ? null
                      : () => _shareCard(buttonContext, title),
                  icon: _sharingCard
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  label: Text(
                    _sharingCard
                        ? '카드를 만들고 있어요…'
                        : sendsMapLinks
                        ? '카드 보내고 지도 링크 이어 보내기'
                        : 'SNS에 이미지 카드 보내기',
                  ),
                ),
              ),
            ),
            if (sendsMapLinks) ...[
              const SizedBox(height: 10),
              Builder(
                builder: (buttonContext) => SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _sharingCard || _sharingLinks || _sharingPackage
                        ? null
                        : () => _shareMapLinksOnly(buttonContext),
                    icon: _sharingLinks
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_location_alt_outlined),
                    label: Text(
                      _sharingLinks ? '지도 링크를 준비하고 있어요…' : '지도 링크만 보내기',
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Builder(
              builder: (buttonContext) => SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sharingCard || _sharingLinks || _sharingPackage
                      ? null
                      : () => _sharePackage(buttonContext),
                  icon: _sharingPackage
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_to_mobile_rounded),
                  label: Text(_sharingPackage ? '파일을 준비하고 있어요…' : 'luffi로 보내기'),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              sendsMapLinks
                  ? '이미지 카드와 지도 링크는 따로도 보낼 수 있어요.\n'
                        'luffi용 팁 파일은 앱에서 다시 저장하고 활용할 수 있어요.'
                  : '첫 번째는 앱 없이 읽는 이미지 카드,\n'
                        '두 번째는 luffi에서 다시 저장하고 활용하는 팁 파일이에요.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.subtle,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _useMessageSuggestion(String message) {
    _messageController.value = TextEditingValue(
      text: message,
      selection: TextSelection.collapsed(offset: message.length),
    );
  }

  void _toggleDetail(_SelectableTipDetail detail, bool selected) {
    if (selected && _selectedIds.length >= _maxSelectedDetails) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('한 카드에는 핵심 정보 6개까지 담을 수 있어요.')),
        );
      return;
    }
    setState(() {
      if (selected) {
        _selectedIds.add(detail.id);
      } else {
        _selectedIds.remove(detail.id);
      }
    });
  }

  Future<void> _shareCard(BuildContext buttonContext, String title) async {
    setState(() => _sharingCard = true);
    try {
      final placeName = _analysis.place?.name;
      final placeAddress = _analysis.place?.address;
      final placeSearchArea = _analysis.place?.searchArea;
      final result = await _shareService.shareCard(
        previewKey: _cardKey,
        title: title,
        placeName: placeName,
        placeAddress: placeAddress,
        placeSearchArea: placeSearchArea,
        sharePositionOrigin: _shareOrigin(buttonContext),
      );
      final mapShareText = buildCardShareText(
        placeName: placeName,
        placeAddress: placeAddress,
        placeSearchArea: placeSearchArea,
      );
      if (!mounted ||
          !shouldOfferMapLinkFollowUp(
            result: result,
            mapShareText: mapShareText,
          )) {
        return;
      }
      final shouldContinue = await _confirmKakaoMapLinkFollowUp();
      if (!mounted || !buttonContext.mounted || !shouldContinue) return;
      await _shareService.shareMapLinks(
        placeName: placeName,
        placeAddress: placeAddress,
        placeSearchArea: placeSearchArea,
        sharePositionOrigin: _shareOrigin(buttonContext),
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Share card failed: $error\n$stackTrace');
      if (mounted) _showMessage('카드를 공유하지 못했어요. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _sharingCard = false);
    }
  }

  Future<bool> _confirmKakaoMapLinkFollowUp() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.map_outlined, color: AppTheme.primary),
        title: const Text('지도 링크도 이어서 보낼까요?'),
        content: const Text('사진은 먼저 보냈어요. 같은 채팅방에 지도 링크도 이어서 보낼게요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('괜찮아요'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('지도 링크 보내기'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> _shareMapLinksOnly(BuildContext buttonContext) async {
    setState(() => _sharingLinks = true);
    try {
      await _shareService.shareMapLinks(
        placeName: _analysis.place?.name,
        placeAddress: _analysis.place?.address,
        placeSearchArea: _analysis.place?.searchArea,
        sharePositionOrigin: _shareOrigin(buttonContext),
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Share map links failed: $error\n$stackTrace');
      if (mounted) _showMessage('지도 링크를 공유하지 못했어요.');
    } finally {
      if (mounted) setState(() => _sharingLinks = false);
    }
  }

  Future<void> _sharePackage(BuildContext buttonContext) async {
    setState(() => _sharingPackage = true);
    try {
      final package = _createPackage();
      await _shareService.sharePortableTip(
        tip: package,
        sharePositionOrigin: _shareOrigin(buttonContext),
      );
    } on Object {
      if (mounted) _showMessage('팁 파일을 공유하지 못했어요.');
    } finally {
      if (mounted) setState(() => _sharingPackage = false);
    }
  }

  PortableTipPackage _createPackage() {
    final selectedFacts = <AnalysisFact>[];
    final selectedSteps = <RecipeStep>[];
    final selectedIngredientIds = <String>{};
    var includePlace = false;
    var includeSource = false;
    for (final detail in _details) {
      if (!_selectedIds.contains(detail.id)) continue;
      switch (detail.kind) {
        case _TipDetailKind.fact:
          selectedFacts.add(_analysis.facts[detail.primaryIndex]);
        case _TipDetailKind.ingredient:
          selectedIngredientIds.add(detail.id);
        case _TipDetailKind.step:
          selectedSteps.add(_analysis.steps[detail.primaryIndex]);
        case _TipDetailKind.place:
          includePlace = true;
        case _TipDetailKind.source:
          includeSource = true;
      }
    }
    final selectedGroups = <IngredientGroup>[];
    for (
      var groupIndex = 0;
      groupIndex < _analysis.ingredientGroups.length;
      groupIndex++
    ) {
      final group = _analysis.ingredientGroups[groupIndex];
      final ingredients = <RecipeIngredient>[];
      for (
        var itemIndex = 0;
        itemIndex < group.ingredients.length;
        itemIndex++
      ) {
        if (selectedIngredientIds.contains(
          'ingredient-$groupIndex-$itemIndex',
        )) {
          ingredients.add(group.ingredients[itemIndex]);
        }
      }
      if (ingredients.isNotEmpty) {
        selectedGroups.add(
          IngredientGroup(name: group.name, ingredients: ingredients),
        );
      }
    }
    final fingerprint = widget.capture.raw.semanticFingerprint;
    final suffix = String.fromCharCodes(fingerprint.runes.take(10));
    return PortableTipPackage.fromStructuredCapture(
      packageId: 'tip-${DateTime.now().microsecondsSinceEpoch}-$suffix',
      exportedAt: DateTime.now(),
      capture: widget.capture,
      selectedFacts: selectedFacts,
      selectedIngredientGroups: selectedGroups,
      selectedSteps: selectedSteps,
      includePlace: includePlace,
      includeSource: includeSource,
      sourceLabel: '원문 게시물',
      message: _messageController.text,
    );
  }

  Rect? _shareOrigin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _LetterComposer extends StatelessWidget {
  const _LetterComposer({required this.controller, required this.onSuggestion});

  static const _suggestions = <String>[
    '이거 보니 네 생각났어',
    '이번 주말에 같이 가볼래?',
    '우리 이거 해보자!',
  ];

  final TextEditingController controller;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B2518), Color(0xFF1D1C18)],
        ),
        border: Border.all(color: AppTheme.primarySoft),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTheme.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(
                    dimension: 36,
                    child: Icon(
                      Icons.mail_outline_rounded,
                      color: AppTheme.primary,
                      size: 19,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '짧은 편지',
                    style: TextStyle(
                      color: AppTheme.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    child: Text(
                      '선택',
                      style: TextStyle(
                        color: AppTheme.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            TextField(
              key: const Key('share-letter-field'),
              controller: controller,
              maxLength: 80,
              minLines: 3,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '이 정보를 왜 보내고 싶은지 적어보세요.\n예: 이번 주말에 같이 가볼래?',
                hintStyle: const TextStyle(
                  color: AppTheme.subtle,
                  fontSize: 14,
                  height: 1.45,
                ),
                filled: true,
                fillColor: Colors.black.withValues(alpha: 0.18),
                contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.09),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: AppTheme.primary,
                    width: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final suggestion in _suggestions)
                  ActionChip(
                    label: Text(suggestion),
                    labelStyle: const TextStyle(
                      color: AppTheme.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    backgroundColor: Colors.white.withValues(alpha: 0.055),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.09),
                    ),
                    onPressed: () => onSuggestion(suggestion),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _GiftTipCard extends StatelessWidget {
  const _GiftTipCard({
    required this.title,
    required this.summary,
    required this.tags,
    required this.message,
    required this.details,
  });

  final String title;
  final String summary;
  final List<ContentTag> tags;
  final String message;
  final List<_SelectableTipDetail> details;

  static const cornerRadius = 34.0;

  @override
  Widget build(BuildContext context) {
    const dark = Color(0xFF153C35);
    final cleanMessage = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.primary,
          borderRadius: BorderRadius.circular(cornerRadius),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                key: const Key('share-card-export-background'),
                color: AppTheme.primary,
              ),
            ),
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cornerRadius),
                child: Stack(
                  children: [
                    Positioned(
                      right: -34,
                      top: -36,
                      child: Container(
                        width: 132,
                        height: 132,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(25, 24, 25, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        key: const Key('share-card-brand-badge'),
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: const LuffiMark(
                          key: Key('share-card-brand'),
                          size: 48,
                          color: dark,
                        ),
                      ),
                      const SizedBox(width: 11),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LuffiWordmark(fontSize: 24, color: dark),
                            SizedBox(height: 5),
                            Text(
                              '너에게 어울릴 것 같아서',
                              style: TextStyle(
                                color: dark,
                                fontSize: 11,
                                height: 1.3,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: dark.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          tags.isEmpty ? '태그 없음' : tags.first.value,
                          style: const TextStyle(
                            color: dark,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (cleanMessage.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Text(
                        '“$cleanMessage”',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: dark,
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 13),
                  ],
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: dark,
                      fontSize: 29,
                      height: 1.08,
                      letterSpacing: -1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    summary.trim().isEmpty && tags.isNotEmpty
                        ? tags.first.value
                        : summary,
                    maxLines: cleanMessage.isEmpty ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: dark.withValues(alpha: 0.76),
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.fromLTRB(
                        14,
                        details.length > 4 ? 6 : 12,
                        14,
                        details.length > 4 ? 6 : 10,
                      ),
                      decoration: BoxDecoration(
                        color: dark,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: details.isEmpty
                          ? const Center(
                              child: Text(
                                '저장해두고 직접 써봐요.',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                for (
                                  var index = 0;
                                  index < details.length;
                                  index++
                                ) ...[
                                  _GiftDetailRow(
                                    detail: details[index],
                                    dense: details.length > 4,
                                  ),
                                  if (index != details.length - 1)
                                    Divider(
                                      color: const Color(0x33FFFFFF),
                                      height: details.length > 4 ? 4 : 9,
                                    ),
                                ],
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      Text(
                        '보는 데서 끝내지 말고, 직접 해보기',
                        style: TextStyle(
                          color: dark,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Spacer(),
                      Icon(Icons.arrow_forward_rounded, color: dark, size: 17),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _GiftDetailRow extends StatelessWidget {
  const _GiftDetailRow({required this.detail, required this.dense});

  final _SelectableTipDetail detail;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(detail.icon, color: Colors.white70, size: dense ? 11 : 14),
        SizedBox(width: dense ? 6 : 8),
        SizedBox(
          width: dense ? 52 : 58,
          child: Text(
            detail.cardLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white70,
              fontSize: dense ? 8.5 : 10,
              height: 1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        SizedBox(width: dense ? 5 : 7),
        Expanded(
          child: Text(
            detail.cardValue,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: dense ? 9.5 : 11,
              height: 1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

final class _DetailChoiceTile extends StatelessWidget {
  const _DetailChoiceTile({
    required this.detail,
    required this.selected,
    required this.onChanged,
  });

  final _SelectableTipDetail detail;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: selected,
      onChanged: (value) => onChanged(value ?? false),
      controlAffinity: ListTileControlAffinity.trailing,
      secondary: Icon(
        detail.icon,
        color: selected ? AppTheme.primary : AppTheme.subtle,
      ),
      title: Text(
        detail.cardLabel,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        detail.cardValue,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

final class _NoExtraDetails extends StatelessWidget {
  const _NoExtraDetails();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Text(
        '추가로 고를 정보가 없어 제목과 요약만 카드에 담아요.',
        style: TextStyle(color: AppTheme.muted, fontSize: 13),
      ),
    );
  }
}

enum _TipDetailKind { fact, ingredient, step, place, source }

final class _SelectableTipDetail {
  const _SelectableTipDetail({
    required this.id,
    required this.kind,
    required this.cardLabel,
    required this.cardValue,
    required this.icon,
    required this.primaryIndex,
    this.secondaryIndex,
  });

  final String id;
  final _TipDetailKind kind;
  final String cardLabel;
  final String cardValue;
  final IconData icon;
  final int primaryIndex;
  final int? secondaryIndex;
}

List<_SelectableTipDetail> _buildDetails(CaptureRecord capture) {
  final analysis = capture.analysis!.structuredContent!;
  final details = <_SelectableTipDetail>[];
  final place = analysis.place;
  if (place != null &&
      (place.name?.trim().isNotEmpty == true ||
          place.address?.trim().isNotEmpty == true)) {
    details.add(
      _SelectableTipDetail(
        id: 'place',
        kind: _TipDetailKind.place,
        cardLabel: '장소',
        cardValue: [place.name, place.address]
            .whereType<String>()
            .where((value) => value.trim().isNotEmpty)
            .join(' · '),
        icon: Icons.location_on_outlined,
        primaryIndex: 0,
      ),
    );
  }
  for (var index = 0; index < analysis.facts.length; index++) {
    final fact = analysis.facts[index];
    details.add(
      _SelectableTipDetail(
        id: 'fact-$index',
        kind: _TipDetailKind.fact,
        cardLabel: fact.label,
        cardValue: fact.value,
        icon: Icons.check_circle_outline_rounded,
        primaryIndex: index,
      ),
    );
  }
  for (
    var groupIndex = 0;
    groupIndex < analysis.ingredientGroups.length;
    groupIndex++
  ) {
    final group = analysis.ingredientGroups[groupIndex];
    for (var itemIndex = 0; itemIndex < group.ingredients.length; itemIndex++) {
      final ingredient = group.ingredients[itemIndex];
      details.add(
        _SelectableTipDetail(
          id: 'ingredient-$groupIndex-$itemIndex',
          kind: _TipDetailKind.ingredient,
          cardLabel: group.name,
          cardValue: ingredient.originalText,
          icon: Icons.soup_kitchen_outlined,
          primaryIndex: groupIndex,
          secondaryIndex: itemIndex,
        ),
      );
    }
  }
  for (var index = 0; index < analysis.steps.length; index++) {
    final step = analysis.steps[index];
    details.add(
      _SelectableTipDetail(
        id: 'step-$index',
        kind: _TipDetailKind.step,
        cardLabel: '순서 ${step.order}',
        cardValue: step.instruction,
        icon: Icons.format_list_numbered_rounded,
        primaryIndex: index,
      ),
    );
  }
  final sourceUrl = capture.raw.rawUrl;
  if (sourceUrl != null) {
    details.add(
      _SelectableTipDetail(
        id: 'source',
        kind: _TipDetailKind.source,
        cardLabel: '원문 전체 주소',
        cardValue: sourceUrl,
        icon: Icons.link_rounded,
        primaryIndex: 0,
      ),
    );
  }
  return details;
}

Iterable<String> _defaultSelection(List<_SelectableTipDetail> details) sync* {
  var count = 0;
  for (final detail in details) {
    if (detail.kind == _TipDetailKind.source) continue;
    if (count >= 4) break;
    yield detail.id;
    count++;
  }
}
