import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../domain/models.dart';
import '../../state/app_controller.dart';

enum CaptureListAction { organize, delete }

Future<CaptureListAction?> showCaptureActionSheet(
  BuildContext context, {
  required bool canOrganize,
}) {
  return showModalBottomSheet<CaptureListAction>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      key: const Key('capture-action-safe-area'),
      top: false,
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.only(bottom: AppTheme.bottomSheetSafeInset),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canOrganize)
              ListTile(
                key: const Key('capture-action-organize'),
                leading: const Icon(Icons.bookmark_add_outlined),
                title: const Text('정리함에 저장'),
                onTap: () =>
                    Navigator.of(context).pop(CaptureListAction.organize),
              ),
            ListTile(
              key: const Key('capture-action-delete'),
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: AppTheme.negative,
              ),
              title: const Text(
                '삭제',
                style: TextStyle(color: AppTheme.negative),
              ),
              onTap: () => Navigator.of(context).pop(CaptureListAction.delete),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> confirmCaptureDeletion(
  BuildContext context, {
  required AppController controller,
  required String captureId,
}) async {
  final capture = controller.captureById(captureId);
  final batchPending =
      capture?.analysisMode == CaptureAnalysisMode.batch &&
      capture?.status == CaptureStatus.analyzing;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('이 콘텐츠를 삭제할까요?'),
      content: Text(
        'luffi에 보관된 내용만 삭제해요. 갤러리 원본은 그대로 남아요.'
        '${batchPending ? '\n\n이미 서버에 접수된 절약 분석은 취소되지 않아 요금이 발생할 수 있어요.' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        TextButton(
          key: const Key('confirm-capture-delete'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppTheme.negative),
          child: const Text('삭제'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return false;
  }

  final deleted = await controller.deleteCapture(captureId);
  if (!deleted && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('삭제하지 못했어요. 잠시 후 다시 시도해 주세요.')),
      );
  }
  return deleted;
}
