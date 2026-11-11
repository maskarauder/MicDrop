package com.maskarauder.micdrop

import android.os.Bundle
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
internal class PlaybackLibraryCallback(private val owner: PlaybackService) : MediaLibrarySession.Callback {
    override fun onConnectAsync(session: MediaSession, controller: MediaSession.ControllerInfo): ListenableFuture<MediaSession.ConnectionResult> {
        // Verified same-UID, System UI and authorized media controllers only.
        // Never use a caller-supplied package string as an authorization check.
        val result = if (!controller.isTrusted) MediaSession.ConnectionResult.reject() else
            MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                .setAvailableSessionCommands(MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS.buildUpon()
                    .add(STOP).build()).build()
        return Futures.immediateFuture(result)
    }
    override fun onCustomCommand(session: MediaSession, controller: MediaSession.ControllerInfo,
        customCommand: SessionCommand, args: Bundle): ListenableFuture<SessionResult> {
        val code = when (customCommand.customAction) {
            STOP.customAction -> { owner.stopFromActivity(); SessionResult.RESULT_SUCCESS }
            else -> SessionError.ERROR_NOT_SUPPORTED
        }
        return Futures.immediateFuture(SessionResult(code))
    }
    override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
        params: LibraryParams?): ListenableFuture<LibraryResult<MediaItem>> {
        // Legacy System UI may block its main thread for the root. Never defer
        // this callback to a main-thread storage observer.
        return Futures.immediateFuture(LibraryResult.ofItem(ROOT, params))
    }
    override fun onGetChildren(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
        parentId: String, page: Int, pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
        if (parentId != ROOT.mediaId || page != 0) return Futures.immediateFuture(LibraryResult.ofItemList(emptyList(), params))
        val current = owner.currentMediaItem()
        if (current != null) return Futures.immediateFuture(LibraryResult.ofItemList(listOf(current), params))
        val result = Futures.transform(owner.resumptionItem(), { item -> LibraryResult.ofItemList(listOf(item), params) }, owner.mainExecutor)
        return Futures.catching(result, Exception::class.java, { LibraryResult.ofItemList(emptyList(), params) }, owner.mainExecutor)
    }
    override fun onGetItem(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
        mediaId: String): ListenableFuture<LibraryResult<MediaItem>> {
        val item = owner.currentMediaItem()
        return Futures.immediateFuture(if (item?.mediaId == mediaId) LibraryResult.ofItem(item, null)
            else LibraryResult.ofError(SessionError.ERROR_BAD_VALUE))
    }
    override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo,
        mediaItems: List<MediaItem>): ListenableFuture<List<MediaItem>> {
        val item = owner.currentMediaItem()
        return if (item != null && mediaItems.size == 1 && mediaItems[0].mediaId == item.mediaId)
            Futures.immediateFuture(listOf(item)) // Discard caller-supplied metadata/URIs.
        else Futures.immediateFailedFuture(IllegalArgumentException("Unknown live connection."))
    }
    override fun onPlaybackResumption(session: MediaSession, controller: MediaSession.ControllerInfo,
        isForPlayback: Boolean): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
        Futures.transform(owner.resumptionItem(), { item ->
            MediaSession.MediaItemsWithStartPosition(listOf(item), 0, C.TIME_UNSET)
        }, owner.mainExecutor)

    companion object {
        private val ROOT = MediaItem.Builder().setMediaId("micdrop-root")
            .setMediaMetadata(MediaMetadata.Builder().setTitle("MicDrop")
                .setIsBrowsable(true).setIsPlayable(false).build()).build()
        private val STOP = SessionCommand("com.maskarauder.micdrop.STOP", Bundle.EMPTY)
        val buttons: List<CommandButton> = listOf(
            CommandButton.Builder(CommandButton.ICON_STOP).setDisplayName("Stop").setSessionCommand(STOP)
                .setSlots(CommandButton.SLOT_FORWARD).build())
    }
}
