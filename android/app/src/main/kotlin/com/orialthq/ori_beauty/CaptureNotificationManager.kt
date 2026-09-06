package com.orialthq.ori_beauty

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

class CaptureNotificationManager(private val context: Context) {
    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                "캡처 도착 알림",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "luffi로 보낸 캡처의 도착과 분석 시작을 알려드려요."
            }
        notificationManager.createNotificationChannel(channel)
    }

    fun showReceived(transportId: String) {
        createChannel()
        val openAppIntent =
            Intent(context, MainActivity::class.java).apply {
                action = ACTION_OPEN_CAPTURE_NOTIFICATION
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_TRANSPORT_ID, transportId)
            }
        val contentIntent =
            PendingIntent.getActivity(
                context,
                transportId.hashCode(),
                openAppIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
            }

        val notification =
            builder
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("캡처를 받았어요")
                .setContentText("탭해서 luffi의 분석 상태를 확인해 주세요.")
                .setCategory(Notification.CATEGORY_STATUS)
                .setContentIntent(contentIntent)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .build()
        notificationManager.notify(transportId.hashCode(), notification)
    }

    companion object {
        const val ACTION_OPEN_CAPTURE_NOTIFICATION =
            "com.orialthq.ori_beauty.action.OPEN_CAPTURE_NOTIFICATION"
        const val EXTRA_TRANSPORT_ID = "capture_transport_id"
        private const val CHANNEL_ID = "capture_arrivals_v1"
    }
}
