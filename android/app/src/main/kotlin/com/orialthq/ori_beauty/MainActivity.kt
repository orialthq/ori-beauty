package com.orialthq.ori_beauty

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import com.orialthq.ori_beauty.share.CapturePickerBatchPolicy
import com.orialthq.ori_beauty.share.IncomingShareIngestor
import com.orialthq.ori_beauty.share.IncomingSharePayload
import com.orialthq.ori_beauty.share.IncomingShareRoutePolicy
import com.orialthq.ori_beauty.share.IncomingShareStore
import com.orialthq.ori_beauty.trigger.TriggerSchedulerChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var incomingChannel: MethodChannel? = null
    private var placeReminderChannel: MethodChannel? = null
    private var appNavigationChannel: MethodChannel? = null
    private var portableTipChannel: MethodChannel? = null
    private val triggerSchedulerChannel: TriggerSchedulerChannel by lazy {
        TriggerSchedulerChannel(applicationContext)
    }
    private val incomingStore: IncomingShareStore by lazy {
        IncomingShareStore(applicationContext)
    }
    private val incomingShareIngestor: IncomingShareIngestor by lazy {
        IncomingShareIngestor(applicationContext)
    }
    private val captureNotifications: CaptureNotificationManager by lazy {
        CaptureNotificationManager(applicationContext)
    }
    private val placeReminderManager: PlaceReminderManager by lazy {
        PlaceReminderManager(applicationContext)
    }
    private val sharedMediaDeletionManager: SharedMediaDeletionManager by lazy {
        SharedMediaDeletionManager(applicationContext)
    }
    private val portableTipStore: PortableTipStore by lazy {
        PortableTipStore(applicationContext)
    }
    private var pendingCaptureNotificationId: String? = null
    private var pendingCapturePickerResult: MethodChannel.Result? = null
    private var capturePickerInFlight = false
    private var pendingLocationPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var notificationPermissionRequestInFlight = false
    private var pendingSourceDeletionResult: MethodChannel.Result? = null
    private var pendingSourceDeletionTransportId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        incomingChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                INCOMING_SHARE_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "drainPendingShares" -> {
                            val pending =
                                incomingStore.pending().map { payload ->
                                    val transportId = payload["id"] as? String
                                    payload +
                                        ("sourceDeletionAvailable" to
                                            (transportId != null &&
                                                sharedMediaDeletionManager.isAvailable(
                                                    transportId,
                                                )))
                                }
                            result.success(pending)
                        }
                        "presentCapturePicker" -> presentCapturePicker(result)
                        "loadAppSnapshot" -> result.success(incomingStore.loadAppSnapshot())
                        "loadPlanSnapshot" -> result.success(incomingStore.loadPlanSnapshot())
                        "saveAppSnapshot" -> {
                            val snapshot = call.arguments as? String
                            if (snapshot.isNullOrBlank()) {
                                result.error(
                                    "invalid_snapshot",
                                    "App snapshot must be a non-empty string.",
                                    null,
                                )
                            } else if (incomingStore.saveAppSnapshot(snapshot)) {
                                result.success(true)
                            } else {
                                result.error(
                                    "snapshot_save_failed",
                                    "App snapshot could not be committed to durable storage.",
                                    null,
                                )
                            }
                        }
                        "savePlanSnapshot" -> {
                            val snapshot = call.arguments as? String
                            if (snapshot.isNullOrBlank()) {
                                result.error(
                                    "invalid_plan_snapshot",
                                    "Plan snapshot must be a non-empty string.",
                                    null,
                                )
                            } else if (incomingStore.savePlanSnapshot(snapshot)) {
                                result.success(true)
                            } else {
                                result.error(
                                    "plan_snapshot_save_failed",
                                    "Plan snapshot could not be committed to durable storage.",
                                    null,
                                )
                            }
                        }
                        "acknowledgeShares" -> {
                            val arguments = call.arguments as? Map<*, *>
                            val ids =
                                (arguments?.get("ids") as? List<*>)
                                    ?.filterIsInstance<String>()
                                    .orEmpty()
                            if (incomingStore.acknowledge(ids)) {
                                result.success(null)
                            } else {
                                result.error(
                                    "share_acknowledge_failed",
                                    "Pending shares could not be committed to durable storage.",
                                    null,
                                )
                            }
                        }
                        "deleteSharedSource" ->
                            requestSharedSourceDeletion(call.arguments, result)
                        "keepSharedSource" -> {
                            val transportId =
                                (call.arguments as? Map<*, *>)?.get("transportId") as? String
                            if (transportId.isNullOrBlank()) {
                                result.error(
                                    "invalid_transport",
                                    "Transport id is required.",
                                    null,
                                )
                            } else {
                                sharedMediaDeletionManager.forget(transportId)
                                result.success(null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }

        placeReminderChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PLACE_REMINDER_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getPlaceReminder" -> {
                            val id = (call.arguments as? Map<*, *>)?.get("id") as? String
                            if (id.isNullOrBlank()) {
                                result.error("invalid_place", "Place id is required.", null)
                            } else {
                                result.success(
                                    placeReminderManager.state(id) + locationPermissionState(),
                                )
                            }
                        }
                        "requestForegroundLocationPermission" ->
                            requestForegroundLocationPermission(result)
                        "requestNotificationPermission" ->
                            requestNotificationPermission(result)
                        "openBackgroundLocationSettings" -> {
                            if (openBackgroundLocationSettings()) {
                                result.success(null)
                            } else {
                                result.error(
                                    "settings_unavailable",
                                    "Location permission settings are unavailable.",
                                    null,
                                )
                            }
                        }
                        "enablePlaceReminder" -> enablePlaceReminder(call.arguments, result)
                        "disablePlaceReminder" -> disablePlaceReminder(call.arguments, result)
                        "pendingPlaceReminderOpens" ->
                            result.success(placeReminderManager.pendingOpenIds())
                        "acknowledgePlaceReminderOpens" -> {
                            val ids =
                                ((call.arguments as? Map<*, *>)?.get("ids") as? List<*>)
                                    ?.filterIsInstance<String>()
                                    .orEmpty()
                            if (placeReminderManager.acknowledgePendingOpens(ids)) {
                                result.success(null)
                            } else {
                                result.error(
                                    "place_open_acknowledge_failed",
                                    "Pending place destinations could not be committed.",
                                    null,
                                )
                            }
                        }
                        "getMapProviders" -> getMapProviders(result)
                        "openMapProvider" -> openMapProvider(call.arguments, result)
                        "openMap" -> openMap(call.arguments, result)
                        else -> result.notImplemented()
                    }
                }
            }

        appNavigationChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                APP_NAVIGATION_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "returnToPreviousApp" -> returnToPreviousApp(result)
                        else -> result.notImplemented()
                    }
                }
            }

        portableTipChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PORTABLE_TIP_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "pendingPackages" -> result.success(portableTipStore.pending())
                        "acknowledgePackages" -> {
                            val transportIds =
                                ((call.arguments as? Map<*, *>)?.get("transportIds") as? List<*>)
                                    ?.filterIsInstance<String>()
                                    .orEmpty()
                            portableTipStore.acknowledge(transportIds)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }

        triggerSchedulerChannel.attach(
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val incomingIntent = intent
        setIntent(intentForFlutter(incomingIntent))
        super.onCreate(savedInstanceState)
        captureNotifications.createChannel()
        handleIncomingIntent(incomingIntent)
    }

    override fun onNewIntent(intent: Intent) {
        val incomingIntent = intent
        val flutterIntent = intentForFlutter(incomingIntent)
        super.onNewIntent(flutterIntent)
        setIntent(flutterIntent)
        handleIncomingIntent(incomingIntent)
    }

    override fun onResume() {
        super.onResume()
        triggerSchedulerChannel.emitPendingInteractions()
    }

    override fun onDestroy() {
        triggerSchedulerChannel.detach()
        super.onDestroy()
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SOURCE_DELETE_REQUEST_CODE) {
            val transportId = pendingSourceDeletionTransportId
            if (transportId != null) {
                sharedMediaDeletionManager.forget(transportId)
            }
            pendingSourceDeletionResult?.success(
                if (resultCode == RESULT_OK) "deleted" else "kept",
            )
            pendingSourceDeletionResult = null
            pendingSourceDeletionTransportId = null
            return
        }
        if (requestCode != PICK_CAPTURE_REQUEST_CODE) {
            return
        }
        if (resultCode != RESULT_OK) {
            completeCapturePicker(
                CapturePickerBatchPolicy.resultMap(
                    selectedCount = 0,
                    importedCount = 0,
                    rejectedCount = 0,
                ),
            )
            return
        }
        val selectedUris = selectedCaptureUris(data)
        if (selectedUris.isEmpty()) {
            completeCapturePicker(
                CapturePickerBatchPolicy.resultMap(
                    selectedCount = 0,
                    importedCount = 0,
                    rejectedCount = 0,
                ),
            )
            return
        }
        if (selectedUris.size > CapturePickerBatchPolicy.MAX_SELECTION) {
            pendingCapturePickerResult?.error(
                "capture_picker_too_many",
                "Choose no more than ${CapturePickerBatchPolicy.MAX_SELECTION} images.",
                mapOf(
                    "selectedCount" to selectedUris.size,
                    "maxSelection" to CapturePickerBatchPolicy.MAX_SELECTION,
                ),
            )
            pendingCapturePickerResult = null
            capturePickerInFlight = false
            return
        }
        importCapturePickerBatch(selectedUris)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (triggerSchedulerChannel.handleIntent(intent)) {
            return
        }
        if (intent?.action == ACTION_OPEN_PLACE_REMINDER) {
            val captureId = intent.getStringExtra(EXTRA_PLACE_REMINDER_CAPTURE_ID)?.trim()
            if (!captureId.isNullOrEmpty() && placeReminderManager.enqueuePendingOpen(captureId)) {
                placeReminderChannel?.invokeMethod(
                    "placeReminderOpened",
                    mapOf("captureId" to captureId),
                )
            }
            return
        }
        if (intent?.action == ACTION_PICK_CAPTURE) {
            if (!capturePickerInFlight) {
                capturePickerInFlight = true
                try {
                    launchCapturePicker()
                } catch (_: Exception) {
                    capturePickerInFlight = false
                }
            }
            return
        }
        if (portableTipStore.isPortableIntent(intent)) {
            if (portableTipStore.stage(intent) != null) {
                portableTipChannel?.invokeMethod("pendingPackagesChanged", null)
            }
            return
        }
        stageIncomingShare(intent)
    }

    private fun launchCapturePicker() {
        val pickerIntent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                    type = "image/*"
                    putExtra(
                        MediaStore.EXTRA_PICK_IMAGES_MAX,
                        CapturePickerBatchPolicy.systemSelectionLimit(
                            MediaStore.getPickImagesMaxLimit(),
                        ),
                    )
                }
            } else {
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "image/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
            }
        startActivityForResult(pickerIntent, PICK_CAPTURE_REQUEST_CODE)
    }

    private fun presentCapturePicker(result: MethodChannel.Result) {
        if (capturePickerInFlight) {
            result.error(
                "capture_picker_in_progress",
                "A capture picker is already open.",
                null,
            )
            return
        }
        capturePickerInFlight = true
        pendingCapturePickerResult = result
        try {
            launchCapturePicker()
        } catch (_: Exception) {
            pendingCapturePickerResult = null
            capturePickerInFlight = false
            result.error(
                "capture_picker_unavailable",
                "The capture picker could not be presented.",
                null,
            )
        }
    }

    private fun selectedCaptureUris(data: Intent?): List<Uri> {
        val clipData = data?.clipData
        if (clipData != null) {
            return buildList {
                for (index in 0 until clipData.itemCount) {
                    clipData.getItemAt(index).uri?.let(::add)
                }
            }
        }
        return listOfNotNull(data?.data)
    }

    private fun importCapturePickerBatch(selectedUris: List<Uri>) {
        val sourcePackage = referrer?.host
        captureImportExecutor.execute {
            val payloads = mutableListOf<IncomingSharePayload>()
            var batchBytes = 0L
            selectedUris.forEach { selectedUri ->
                val payload =
                    runCatching {
                        val mimeType =
                            runCatching { contentResolver.getType(selectedUri) }
                                .getOrNull() ?: "image/*"
                        incomingShareIngestor.ingest(
                            intent =
                                Intent(Intent.ACTION_VIEW).apply {
                                    // Intent.setType clears data that was set by the
                                    // (action, uri) constructor. Set both together so
                                    // the picker URI reaches the image ingestor.
                                    setDataAndType(selectedUri, mimeType)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                },
                            sourcePackage = sourcePackage,
                        )
                    }.getOrNull()
                if (payload != null) {
                    val payloadBytes = payload.attachments.sumOf { it.byteSize }
                    if (
                        CapturePickerBatchPolicy.canAccept(
                            currentBatchBytes = batchBytes,
                            payloadBytes = payloadBytes,
                            usableBytesAfterPayloadCopy = noBackupFilesDir.usableSpace,
                        )
                    ) {
                        payloads += payload
                        batchBytes += payloadBytes
                    } else {
                        incomingShareIngestor.deleteAttachments(payload.attachments)
                    }
                }
            }
            val committed =
                payloads.isNotEmpty() &&
                    runCatching { incomingStore.appendAll(payloads) }.getOrDefault(false)
            if (!committed) {
                payloads.forEach { payload ->
                    incomingShareIngestor.deleteAttachments(payload.attachments)
                }
            }

            val importedCount = if (committed) payloads.size else 0
            val platformResult =
                CapturePickerBatchPolicy.resultMap(
                    selectedCount = selectedUris.size,
                    importedCount = importedCount,
                    rejectedCount = selectedUris.size - importedCount,
                )
            runOnUiThread {
                if (committed) {
                    if (selectedUris.size == 1 && payloads.size == 1) {
                        sharedMediaDeletionManager.remember(
                            payloads.single().id,
                            selectedUris,
                        )
                    }
                    incomingChannel?.invokeMethod("pendingSharesChanged", null)
                }
                completeCapturePicker(platformResult)
            }
        }
    }

    private fun completeCapturePicker(platformResult: Map<String, Int>) {
        pendingCapturePickerResult?.success(platformResult)
        pendingCapturePickerResult = null
        capturePickerInFlight = false
    }

    private fun locationPermissionState(): Map<String, Any> {
        val foregroundGranted =
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        val backgroundGranted =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        val backgroundLabel =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                packageManager.backgroundPermissionOptionLabel.toString()
            } else {
                "항상 허용"
            }
        return mapOf(
            "foregroundGranted" to foregroundGranted,
            "backgroundGranted" to backgroundGranted,
            "backgroundPermissionLabel" to backgroundLabel,
        )
    }

    private fun requestForegroundLocationPermission(result: MethodChannel.Result) {
        if (
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingLocationPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "A location permission request is already in progress.",
                null,
            )
            return
        }
        pendingLocationPermissionResult = result
        requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            LOCATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingNotificationPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "A notification permission request is already in progress.",
                null,
            )
            return
        }

        pendingNotificationPermissionResult = result
        if (notificationPermissionRequestInFlight) {
            // A capture notification may already have opened the same system
            // permission dialog. Resolve this Flutter request from that result.
            return
        }

        notificationPermissionRequestInFlight = true
        getSharedPreferences(NOTIFICATION_PREFERENCES_NAME, MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, true)
            .apply()
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun openBackgroundLocationSettings(): Boolean {
        return LocationPermissionSettingsNavigator.open(this)
    }

    private fun returnToPreviousApp(result: MethodChannel.Result) {
        // Let Flutter receive the method result before this activity is paused or
        // finished. If a share target was added on top of the source app's task,
        // finishing reveals that source activity. Otherwise, moving Trun On's own
        // task behind reveals whichever app was foreground before the share.
        result.success(true)
        window.decorView.post {
            if (isFinishing || isDestroyed) {
                return@post
            }
            if (!isTaskRoot) {
                finish()
            } else if (!moveTaskToBack(true)) {
                finish()
            }
        }
    }

    private fun enablePlaceReminder(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val id = values?.get("id") as? String
        val title = values?.get("title") as? String
        val address = values?.get("address") as? String
        val radius = (values?.get("radiusMeters") as? Number)?.toFloat()
        if (
            id.isNullOrBlank() ||
                title.isNullOrBlank() ||
                address.isNullOrBlank() ||
                radius == null
        ) {
            result.error("invalid_place", "Place reminder fields are invalid.", null)
            return
        }
        val permission = locationPermissionState()
        if (permission["foregroundGranted"] != true) {
            result.success(mapOf("status" to "needs_foreground_permission"))
            return
        }
        if (permission["backgroundGranted"] != true) {
            result.success(
                mapOf(
                    "status" to "needs_background_permission",
                    "backgroundPermissionLabel" to
                        (permission["backgroundPermissionLabel"] as? String ?: "항상 허용"),
                ),
            )
            return
        }
        placeReminderManager.enable(id, title, address, radius) { outcome ->
            runOnUiThread {
                outcome.fold(
                    onSuccess = { reminder ->
                        result.success(
                            mapOf(
                                "status" to "enabled",
                                "radiusMeters" to reminder.radiusMeters.toDouble(),
                            ),
                        )
                    },
                    onFailure = { error ->
                        result.success(
                            mapOf(
                                "status" to
                                    if (error.message == "address_not_found") {
                                        "address_not_found"
                                    } else {
                                        "failed"
                                    },
                            ),
                        )
                    },
                )
            }
        }
    }

    private fun disablePlaceReminder(arguments: Any?, result: MethodChannel.Result) {
        val id = (arguments as? Map<*, *>)?.get("id") as? String
        if (id.isNullOrBlank()) {
            result.error("invalid_place", "Place id is required.", null)
            return
        }
        placeReminderManager.disable(id) { removed ->
            runOnUiThread { result.success(removed) }
        }
    }

    private enum class MapProvider(
        val wireName: String,
        val packageName: String?,
    ) {
        NAVER("naver", "com.nhn.android.nmap"),
        KAKAO("kakao", "net.daum.android.map"),
        GOOGLE("google", "com.google.android.apps.maps"),
        ;

        companion object {
            fun fromWireName(value: String?): MapProvider? =
                entries.firstOrNull { it.wireName == value }
        }
    }

    private fun getMapProviders(result: MethodChannel.Result) {
        val probeQuery = "Trun On"
        result.success(
            MapProvider.entries.map { provider ->
                mapOf(
                    "id" to provider.wireName,
                    "appInstalled" to canOpen(mapAppIntent(provider, probeQuery)),
                    "available" to true,
                )
            },
        )
    }

    private fun openMapProvider(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val provider =
            MapProvider.fromWireName(values?.get("provider") as? String)
        if (provider == null) {
            result.error("invalid_map_provider", "A supported map provider is required.", null)
            return
        }
        val explicitQuery = (values?.get("query") as? String)?.trim().orEmpty()
        val name = values?.get("name") as? String
        val address = values?.get("address") as? String
        val query =
            explicitQuery.ifEmpty {
                listOfNotNull(name, address).joinToString(" ").trim()
            }
        if (query.isEmpty()) {
            result.error("invalid_place", "A map query is required.", null)
            return
        }

        val appIntent = mapAppIntent(provider, query)
        val openedInApp = canOpen(appIntent) && tryOpen(appIntent)
        if (!openedInApp && !tryOpen(mapWebIntent(provider, query))) {
            result.error("map_unavailable", "No map app or browser could open the place.", null)
            return
        }
        result.success(
            mapOf(
                "provider" to provider.wireName,
                "openedInApp" to openedInApp,
            ),
        )
    }

    private fun openMap(arguments: Any?, result: MethodChannel.Result) {
        val values = (arguments as? Map<*, *>).orEmpty()
        openMapProvider(values + ("provider" to MapProvider.NAVER.wireName), result)
    }

    private fun mapAppIntent(provider: MapProvider, query: String): Intent {
        val uri =
            when (provider) {
                MapProvider.NAVER ->
                    Uri.Builder()
                        .scheme("nmap")
                        .authority("search")
                        .appendQueryParameter("query", query)
                        .appendQueryParameter("appname", packageName)
                        .build()
                MapProvider.KAKAO ->
                    Uri.Builder()
                        .scheme("kakaomap")
                        .authority("search")
                        .appendQueryParameter("q", query)
                        .build()
                MapProvider.GOOGLE -> mapWebUri(provider, query)
            }
        return Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            provider.packageName?.let { setPackage(it) }
        }
    }

    private fun mapWebIntent(provider: MapProvider, query: String): Intent =
        Intent(Intent.ACTION_VIEW, mapWebUri(provider, query)).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
        }

    private fun mapWebUri(provider: MapProvider, query: String): Uri =
        when (provider) {
            MapProvider.NAVER ->
                Uri.Builder()
                    .scheme("https")
                    .authority("map.naver.com")
                    .appendPath("p")
                    .appendPath("search")
                    .appendPath(query)
                    .build()
            MapProvider.KAKAO ->
                Uri.Builder()
                    .scheme("https")
                    .authority("map.kakao.com")
                    .appendPath("link")
                    .appendPath("search")
                    .appendPath(query)
                    .build()
            MapProvider.GOOGLE ->
                Uri.Builder()
                    .scheme("https")
                    .authority("www.google.com")
                    .appendPath("maps")
                    .appendPath("search")
                    .appendPath("")
                    .appendQueryParameter("api", "1")
                    .appendQueryParameter("query", query)
                    .build()
        }

    private fun canOpen(intent: Intent): Boolean =
        intent.resolveActivity(packageManager) != null

    private fun tryOpen(intent: Intent): Boolean =
        try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }

    private fun requestSharedSourceDeletion(
        arguments: Any?,
        result: MethodChannel.Result,
    ) {
        val transportId =
            (arguments as? Map<*, *>)?.get("transportId") as? String
        if (transportId.isNullOrBlank()) {
            result.error("invalid_transport", "Transport id is required.", null)
            return
        }
        if (pendingSourceDeletionResult != null) {
            result.error(
                "deletion_request_in_progress",
                "A source deletion request is already in progress.",
                null,
            )
            return
        }
        val deleteRequest =
            sharedMediaDeletionManager.createDeleteRequest(transportId)
        if (deleteRequest == null) {
            sharedMediaDeletionManager.forget(transportId)
            result.success("unavailable")
            return
        }
        pendingSourceDeletionResult = result
        pendingSourceDeletionTransportId = transportId
        try {
            startIntentSenderForResult(
                deleteRequest.intentSender,
                SOURCE_DELETE_REQUEST_CODE,
                null,
                0,
                0,
                0,
            )
        } catch (_: Exception) {
            pendingSourceDeletionResult = null
            pendingSourceDeletionTransportId = null
            sharedMediaDeletionManager.forget(transportId)
            result.success("failed")
        }
    }

    private fun intentForFlutter(intent: Intent): Intent {
        if (!IncomingShareRoutePolicy.shouldStripData(intent.action)) {
            return intent
        }
        return Intent(intent).apply {
            data = null
        }
    }

    private fun stageIncomingShare(intent: Intent?): Boolean {
        val sourcePackage = referrer?.host
        val payload =
            incomingShareIngestor.ingest(
                intent = intent,
                sourcePackage = sourcePackage,
            ) ?: return false
        if (!incomingStore.append(payload)) {
            incomingShareIngestor.deleteAttachments(payload.attachments)
            return false
        }
        if (payload.sourceImageUris.isNotEmpty()) {
            sharedMediaDeletionManager.remember(payload.id, payload.sourceImageUris)
        }
        if (payload.attachments.isNotEmpty()) {
            notifyCaptureReceived(payload.id)
        }
        incomingChannel?.invokeMethod("pendingSharesChanged", null)
        return true
    }

    private fun notifyCaptureReceived(transportId: String) {
        if (
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            captureNotifications.showReceived(transportId)
            pendingCaptureNotificationId = null
            return
        }

        pendingCaptureNotificationId = transportId
        val preferences =
            getSharedPreferences(NOTIFICATION_PREFERENCES_NAME, MODE_PRIVATE)
        if (preferences.getBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, false)) {
            return
        }
        preferences
            .edit()
            .putBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, true)
            .apply()
        notificationPermissionRequestInFlight = true
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            NOTIFICATION_PERMISSION_REQUEST_CODE -> {
                val granted =
                    grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    pendingCaptureNotificationId?.let(captureNotifications::showReceived)
                }
                pendingCaptureNotificationId = null
                pendingNotificationPermissionResult?.success(granted)
                pendingNotificationPermissionResult = null
                notificationPermissionRequestInFlight = false
            }
            LOCATION_PERMISSION_REQUEST_CODE -> {
                val granted =
                    checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                        PackageManager.PERMISSION_GRANTED
                pendingLocationPermissionResult?.success(granted)
                pendingLocationPermissionResult = null
            }
        }
    }

    companion object {
        const val ACTION_PICK_CAPTURE =
            "com.orialthq.ori_beauty.action.PICK_CAPTURE"
        const val ACTION_OPEN_PLACE_REMINDER =
            "com.orialthq.ori_beauty.action.OPEN_PLACE_REMINDER"
        const val EXTRA_PLACE_REMINDER_CAPTURE_ID = "place_reminder_capture_id"
        private const val INCOMING_SHARE_CHANNEL =
            "com.orialthq.ori_beauty/incoming_share/v1"
        private const val PLACE_REMINDER_CHANNEL =
            "com.orialthq.ori_beauty/place_reminders/v1"
        private const val APP_NAVIGATION_CHANNEL =
            "com.orialthq.ori_beauty/app_navigation/v1"
        private const val PORTABLE_TIP_CHANNEL =
            "com.orialthq.ori_beauty/portable_tip/v1"
        private const val PICK_CAPTURE_REQUEST_CODE = 4109
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 4107
        private const val LOCATION_PERMISSION_REQUEST_CODE = 4111
        private const val SOURCE_DELETE_REQUEST_CODE = 4112
        private const val NOTIFICATION_PREFERENCES_NAME = "capture_notifications"
        private const val KEY_NOTIFICATION_PERMISSION_REQUESTED = "permission_requested"
        private val captureImportExecutor = Executors.newSingleThreadExecutor()
    }
}
