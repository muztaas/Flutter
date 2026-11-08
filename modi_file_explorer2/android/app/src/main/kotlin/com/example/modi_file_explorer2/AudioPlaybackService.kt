package com.example.modi_file_explorer2

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommands
import androidx.media3.session.SessionResult

@OptIn(UnstableApi::class)
class AudioPlaybackService : MediaSessionService() {
	private var player: ExoPlayer? = null
	private var mediaSession: MediaSession? = null

	override fun onCreate() {
		super.onCreate()
		player = ExoPlayer.Builder(this)
			.setWakeMode(C.WAKE_MODE_LOCAL)
			.build()
			.apply {
				setAudioAttributes(
					AudioAttributes.Builder()
						.setUsage(C.USAGE_MEDIA)
						.setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
						.build(),
					true,
				)
				setHandleAudioBecomingNoisy(true)
				addListener(object : Player.Listener {
					override fun onTimelineChanged(
						timeline: androidx.media3.common.Timeline,
						reason: Int,
					) {
						updateNotificationNavigationCommands()
					}

					override fun onMediaItemTransition(
						mediaItem: androidx.media3.common.MediaItem?,
						reason: Int,
					) {
						updateNotificationNavigationCommands()
					}

					override fun onMediaMetadataChanged(
						mediaMetadata: androidx.media3.common.MediaMetadata,
					) {
						updateNotificationNavigationCommands()
					}

					override fun onPlayerError(error: PlaybackException) {
						val activePlayer = player ?: return
						if (activePlayer.hasNextMediaItem()) {
							activePlayer.seekToNextMediaItem()
							activePlayer.prepare()
							activePlayer.play()
						}
					}

				})
			}

		val launchIntent = Intent(this, MainActivity::class.java).apply {
			flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
			putExtra(AudioPlaybackPlatformChannel.EXTRA_OPEN_AUDIO_TAB, true)
		}
		val sessionActivity = PendingIntent.getActivity(
			this,
			0,
			launchIntent,
			PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
		)

		mediaSession = MediaSession.Builder(this, player!!)
			.setSessionActivity(sessionActivity)
			.setCallback(object : MediaSession.Callback {
				override fun onPlayerCommandRequest(
					session: MediaSession,
					controller: MediaSession.ControllerInfo,
					playerCommand: Int,
				): Int {
					if (playerCommand == Player.COMMAND_STOP) {
						android.os.Handler(mainLooper).post {
							player?.clearMediaItems()
							sendBroadcast(
								Intent(AudioPlaybackPlatformChannel.ACTION_STOPPED)
									.setPackage(packageName),
							)
							pauseAllPlayersAndStopSelf()
						}
					}
					return SessionResult.RESULT_SUCCESS
				}
			})
			.build()
		updateNotificationNavigationCommands()

		val notificationProvider = DefaultMediaNotificationProvider.Builder(this)
			.setChannelId(AUDIO_NOTIFICATION_CHANNEL_ID)
			.setChannelName(R.string.audio_playback_channel_name)
			.build()
		setMediaNotificationProvider(notificationProvider)
	}

	override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
		mediaSession

	private fun updateNotificationNavigationCommands() {
		val session = mediaSession ?: return
		val notificationController = session.mediaNotificationControllerInfo ?: return
		val activePlayer = player ?: return
		val isSingleTrack =
			activePlayer.currentMediaItem?.mediaMetadata?.albumTitle == "This audio"
		val playerCommands = activePlayer.availableCommands.buildUpon().apply {
			if (isSingleTrack) {
				remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
				remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
			} else if (!activePlayer.hasNextMediaItem()) {
				remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
			}
		}.build()
		session.setAvailableCommands(
			notificationController,
			SessionCommands.EMPTY,
			playerCommands,
		)
	}

	override fun onTaskRemoved(rootIntent: Intent?) {
		pauseAllPlayersAndStopSelf()
	}

	override fun onDestroy() {
		mediaSession?.release()
		mediaSession = null
		player?.release()
		player = null
		super.onDestroy()
	}

	companion object {
		const val AUDIO_NOTIFICATION_CHANNEL_ID = "audio_playback"
	}
}
