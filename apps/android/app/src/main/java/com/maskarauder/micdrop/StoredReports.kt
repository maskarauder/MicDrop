package com.maskarauder.micdrop

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.InputStream

// One bounded stream report and one Java crash record, private and excluded
// from backup. Neither is uploaded or used as a media/consent resume ticket.
internal object StoredReports {
    private const val LIMIT = 96 * 1024
    private const val STREAM = "last-stream-report.txt"
    private const val JAVA_CRASH = "last-java-crash.txt"

    @Synchronized fun saveStream(context: Context, text: String) = write(context, STREAM, text)
    @Synchronized fun stream(context: Context): String? = read(context, STREAM)
    @Synchronized fun saveJavaCrash(context: Context, text: String) = write(context, JAVA_CRASH, text)
    @Synchronized fun javaCrash(context: Context): String? = read(context, JAVA_CRASH)

    private fun file(context: Context, name: String) = AtomicFile(File(context.noBackupFilesDir, name))
    private fun write(context: Context, name: String, text: String) {
        val target = file(context, name)
        val output = target.startWrite()
        try {
            output.write(text.toByteArray(Charsets.UTF_8).let { if (it.size > LIMIT) it.copyOf(LIMIT) else it })
            target.finishWrite(output)
        } catch (error: Throwable) { target.failWrite(output); throw error }
    }
    private fun read(context: Context, name: String): String? = runCatching {
        file(context, name).openRead().use { readBounded(it, LIMIT).toString(Charsets.UTF_8) }.takeIf { it.isNotBlank() }
    }.getOrNull()

    fun readBounded(input: InputStream, limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() <= limit - count)
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
