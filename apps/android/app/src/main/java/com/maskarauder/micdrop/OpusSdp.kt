package com.maskarauder.micdrop

// setCodecPreferences selects existing capabilities; it cannot change their
// fmtp parameters. Request stereo in our local answer, before installing it,
// and send that same installed description to Windows after ICE gathering.
internal object OpusSdp {
    fun stereoAnswer(description: String): String {
        require(description.length <= 65536 && '\u0000' !in description)
        val lines = description.replace("\r\n", "\n").trimEnd('\n').split('\n').toMutableList()
        var start = 0
        var updated = false
        while (start < lines.size) {
            if (!lines[start].startsWith("m=")) { start++; continue }
            var end = start + 1
            while (end < lines.size && !lines[end].startsWith("m=")) end++
            val media = lines[start].split(' ')
            if (media.size >= 4 && media[0] == "m=audio" && media[1] != "0") {
                val payloads = media.drop(3).toSet()
                val opus = Regex("a=rtpmap:([0-9]+) opus/48000/2", RegexOption.IGNORE_CASE)
                val maps = (start + 1 until end).mapNotNull { index ->
                    opus.matchEntire(lines[index])?.groupValues?.get(1)?.takeIf { it in payloads }
                }
                for (payload in maps) {
                    val prefix = "a=fmtp:$payload "
                    val indices = (start + 1 until end).filter { lines[it].startsWith(prefix) }
                    require(indices.size <= 1) { "Duplicate Opus parameters" }
                    if (indices.isEmpty()) {
                        lines.add(end, "${prefix}stereo=1"); end++
                    } else {
                        val index = indices.single()
                        val parameters = lines[index].removePrefix(prefix).split(';')
                            .map { it.trim() }.filter { it.isNotEmpty() &&
                                !it.substringBefore('=').trim().equals("stereo", true) }
                        lines[index] = prefix + (parameters + "stereo=1").joinToString(";")
                    }
                    updated = true
                }
            }
            start = end
        }
        check(updated) { "No active stereo Opus audio section" }
        return lines.joinToString("\r\n", postfix = "\r\n").also { require(it.length <= 65536) }
    }
}
