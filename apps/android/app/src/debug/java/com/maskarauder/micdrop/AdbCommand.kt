package com.maskarauder.micdrop

// Fixed commands and typed extras only. Never log an incoming Intent, invitation,
// exception message, saved endpoint or session credential.
internal data class AdbCommand(val name: String, val mode: String? = null,
    val enabled: Boolean? = null, val invitation: String? = null) {
    companion object {
        fun parse(extras: Map<String, *>): AdbCommand {
            require(extras.keys.all { it in setOf("command", "mode", "enabled", "invitation") })
            val name = if ("command" in extras) extras["command"] as? String else "launch"
            require(name in setOf("launch", "connect", "pair", "stop", "microphone", "output", "status", "report"))
            val mode = extras["mode"] as? String
            require("mode" !in extras || (name in setOf("connect", "pair") && mode in setOf("playback", "microphone", "duplex")))
            val enabled = extras["enabled"] as? Boolean
            require(if (name in setOf("microphone", "output")) enabled != null else "enabled" !in extras)
            val invitation = extras["invitation"] as? String
            require(if (name == "pair") invitation != null && invitation.length in 1..16384 &&
                invitation.startsWith("micdrop://") && invitation.none { it.isWhitespace() || it.isISOControl() }
                else "invitation" !in extras)
            return AdbCommand(requireNotNull(name), mode, enabled, invitation)
        }
    }
}
