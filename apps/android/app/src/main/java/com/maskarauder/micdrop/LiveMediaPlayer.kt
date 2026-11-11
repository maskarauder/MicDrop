package com.maskarauder.micdrop

import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

// A control adapter, not an audio player/queue. All audio stays in StreamReceiver.
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
internal class LiveMediaPlayer(private val onPlay: () -> Unit, private val onPause: () -> Unit,
    private val onStop: () -> Unit) : SimpleBasePlayer(Looper.getMainLooper()) {
    private var presentation = MediaPresentation.of(SessionPhase.IDLE, false, false)
    private var item: MediaItem? = null
    private val commands = Player.Commands.Builder().addAll(Player.COMMAND_PLAY_PAUSE,
        Player.COMMAND_PREPARE, Player.COMMAND_STOP, Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
        Player.COMMAND_GET_TIMELINE, Player.COMMAND_GET_METADATA, Player.COMMAND_SET_MEDIA_ITEM,
        Player.COMMAND_GET_AUDIO_ATTRIBUTES, Player.COMMAND_RELEASE).build()

    fun update(view: SessionView, id: String?, automatic: Boolean, queued: Boolean) {
        presentation = MediaPresentation.of(view.phase, automatic, queued)
        if (view.outputEnabled && view.outputPause != null && view.active)
            presentation = presentation.copy(buffering = true)
        item = if (presentation.visible && id != null) liveItem(id).let { live ->
            live.buildUpon().setMediaMetadata(live.mediaMetadata.buildUpon()
                .setArtist(view.outputPause?.detail ?: "Windows audio").build()).build()
        } else null
        invalidateState()
    }

    override fun getState(): State {
        val data = item?.let { MediaItemData.Builder(it.mediaId).setMediaItem(it)
            .setIsDynamic(true).setIsSeekable(false)
            .setLiveConfiguration(MediaItem.LiveConfiguration.Builder().build()).build() }
        return State.Builder().setAvailableCommands(commands)
            .setPlaylist(if (data == null) emptyList() else listOf(data))
            .setPlaybackState(if (data == null) Player.STATE_IDLE else if (presentation.buffering) Player.STATE_BUFFERING else Player.STATE_READY)
            .setPlayWhenReady(presentation.playWhenReady, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackSuppressionReason(if (presentation.suppressed) Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS else Player.PLAYBACK_SUPPRESSION_REASON_NONE)
            .setAudioAttributes(androidx.media3.common.AudioAttributes.Builder()
                .setUsage(androidx.media3.common.C.USAGE_MEDIA).setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC).build())
            .build()
    }
    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) onPlay() else onPause()
        return Futures.immediateVoidFuture()
    }
    override fun handleStop(): ListenableFuture<*> { onStop(); return Futures.immediateVoidFuture() }
    override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()
    override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()
    override fun handleSetMediaItems(mediaItems: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
        // Library callbacks canonicalize IDs and drop all caller-supplied URIs.
        return if (mediaItems.size == 1 && mediaItems[0].mediaId == item?.mediaId) Futures.immediateVoidFuture()
            else Futures.immediateFailedFuture<Void>(IllegalArgumentException("That live connection is no longer available."))
    }
    companion object {
        fun liveItem(id: String): MediaItem = MediaItem.Builder().setMediaId("live/$id")
            .setMediaMetadata(MediaMetadata.Builder().setTitle("MicDrop live audio")
                .setArtist("Windows audio").setIsPlayable(true).setIsBrowsable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION).build()).build()
    }
}
