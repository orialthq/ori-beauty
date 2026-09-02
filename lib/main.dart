import 'package:flutter/widgets.dart';

import 'app/ori_beauty_app.dart';
import 'data/app_snapshot_store.dart';
import 'data/incoming_share_service.dart';
import 'data/portable_tip_service.dart';
import 'data/place_enrichment_service.dart';
import 'data/remote_content_analysis_service.dart';
import 'data/tag_merge_service.dart';
import 'data/tag_sense_service.dart';
import 'data/trigger_plan_store.dart';
import 'data/trigger_scheduler.dart';
import 'state/app_controller.dart';
import 'state/plan_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The analysis asks the controller for the library's words at request time,
  // and the controller owns the analysis: declared first so the closure can
  // name it, assigned once the analysis exists to hand over.
  late final AppController controller;
  controller = AppController(
    MethodChannelIncomingShareService(),
    RemoteContentAnalysisService(vocabulary: () => controller.tagVocabulary),
    const MethodChannelAppSnapshotStore(),
    MethodChannelPortableTipInbox(),
    const RemotePlaceEnrichmentService(),
    const RemoteTagMergeService(),
    const RemoteTagSenseService(),
  );
  final planController = PlanController(
    store: const MethodChannelTriggerPlanStore(),
    scheduler: MethodChannelTriggerScheduler(),
  );

  runApp(OriBeautyApp(controller: controller, planController: planController));
  controller.initialize();
  planController.initialize();
}
