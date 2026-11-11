package com.maskarauder.micdrop

// Selective reader for the public Android tombstone protobuf schema:
// https://github.com/aosp-mirror/platform_system_core/blob/master/debuggerd/proto/tombstone.proto
// Retain only signal/abort and the crashing thread's symbolic frames. Skip
// command lines, logs, registers, memory dumps, mappings and open descriptors.
internal object NativeCrashTrace {
    const val MAX_BYTES = 2 * 1024 * 1024
    private data class ThreadTrace(val name: String, val frames: List<String>)

    fun decode(bytes: ByteArray): String {
        require(bytes.size <= MAX_BYTES)
        val reader = Proto(bytes)
        var tid = 0L
        var signal = "unavailable"
        var abort = ""
        val threads = linkedMapOf<Long, ThreadTrace>()
        while (reader.next()) when (reader.number) {
            6 -> tid = reader.integer()
            10 -> {
                val item = reader.message(); var name = ""; var code = ""
                while (item.next()) when (item.number) { 2 -> name = item.string(64); 4 -> code = item.string(64) }
                signal = "$name $code".trim().ifEmpty { "unavailable" }
            }
            14 -> abort = CrashText.safe(reader.string(2048))
            16 -> {
                val entry = reader.message(); var key = 0L; var trace: ThreadTrace? = null
                while (entry.next()) when (entry.number) {
                    1 -> key = entry.integer()
                    2 -> trace = thread(entry.message())
                }
                if (threads.size < 128 && trace != null) threads[key] = trace
            }
        }
        val crashing = threads[tid]
        return buildString {
            appendLine("Native signal: ${CrashText.safe(signal)}")
            if (abort.isNotEmpty()) appendLine("Native abort: $abort")
            if (crashing == null) appendLine("Crashing thread stack: unavailable") else {
                appendLine("Crashing thread: ${CrashText.safe(crashing.name, 128)}")
                crashing.frames.forEachIndexed { index, frame -> appendLine("  #$index $frame") }
                if (crashing.frames.isEmpty()) appendLine("Crashing thread stack: unavailable")
            }
        }
    }

    private fun thread(reader: Proto): ThreadTrace {
        var name = ""; val frames = mutableListOf<String>()
        while (reader.next()) when (reader.number) {
            2 -> name = reader.string(128)
            4 -> if (frames.size < 24) frames.add(frame(reader.message()))
        }
        return ThreadTrace(name, frames)
    }
    private fun frame(reader: Proto): String {
        var relative = 0L; var function = ""; var offset = 0L; var file = ""; var build = ""
        while (reader.next()) when (reader.number) {
            1 -> relative = reader.integer()
            4 -> function = CrashText.symbol(reader.string(512))
            5 -> offset = reader.integer()
            6 -> file = reader.string(2048).substringAfterLast('/')
            8 -> build = reader.string(128).takeIf { it.matches(Regex("[0-9a-fA-F]{1,128}")) }.orEmpty()
        }
        return "pc ${java.lang.Long.toUnsignedString(relative, 16)} ${CrashText.safe(file, 256)}" +
            (if (function.isNotEmpty()) " ($function+$offset)" else "") +
            (if (build.isNotEmpty()) " build-id=$build" else "")
    }

    private class Proto(private val bytes: ByteArray, private val end: Int = bytes.size, private var position: Int = 0) {
        var number = 0; private set
        private var wire = 0
        private var value = 0L
        private var start = 0
        private var length = 0

        fun next(): Boolean {
            if (position == end) return false
            val tag = varint()
            require(tag > 0 && (tag ushr 3) <= 536870911)
            number = (tag ushr 3).toInt(); require(number > 0)
            wire = (tag and 7).toInt()
            when (wire) {
                0 -> value = varint()
                1 -> skip(8)
                2 -> {
                    val size = varint(); require(size >= 0 && size <= end - position)
                    start = position; length = size.toInt(); skip(length)
                }
                5 -> skip(4)
                else -> throw IllegalArgumentException("Unsupported protobuf wire type")
            }
            return true
        }
        fun integer(): Long { require(wire == 0); return value }
        fun message(): Proto { require(wire == 2); return Proto(bytes, start + length, start) }
        fun string(limit: Int): String { require(wire == 2); return String(bytes, start, minOf(length, limit), Charsets.UTF_8) }
        private fun skip(count: Int) { require(count >= 0 && count <= end - position); position += count }
        private fun varint(): Long {
            var value = 0L
            for (index in 0..9) {
                require(position < end)
                val part = bytes[position++].toInt() and 255
                if (index == 9) require(part <= 1)
                value = value or ((part and 127).toLong() shl (index * 7))
                if (part and 128 == 0) return value
            }
            throw IllegalArgumentException("Overlong protobuf varint")
        }
    }
}
