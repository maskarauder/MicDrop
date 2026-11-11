package com.maskarauder.micdrop

// A presentation hint for the authenticated Windows host. It grants no capture
// consent and carries no session capability. Only Play/focus-resume and the
// input-switch replacement set it; explicit Connect/Reconnect, including after
// Stop while paused, sends none.
internal object SessionResume {
    const val HEADER = "X-MicDrop-Session-Resume"
    const val REASON_HEADER = "X-MicDrop-Session-Resume-Reason"
    // MANUAL is any Play/Resume command (accessory or system Play cannot be told
    // apart), FOCUS_REGAIN is AUDIOFOCUS_GAIN, and AUTOMATIC is a phone-initiated
    // replacement with neither.
    enum class Reason(val wire: String) { MANUAL("manual"), AUTOMATIC("automatic"), FOCUS_REGAIN("focus_regain") }
    val INPUT_SWITCH = Reason.AUTOMATIC
    fun resumed(userRequested: Boolean) = if (userRequested) Reason.MANUAL else Reason.FOCUS_REGAIN
    fun offerHeader(version: Int, path: String, resume: Reason?): String? =
        "1".takeIf { version == 3 && path == "/offer" && resume != null }
    fun reasonHeader(version: Int, path: String, resume: Reason?): String? =
        resume?.wire?.takeIf { offerHeader(version, path, resume) != null }
    // Both request paths send the reason once, right after the hint.
    fun offerHeaders(version: Int, path: String, resume: Reason?): List<Pair<String, String>> = listOfNotNull(
        offerHeader(version, path, resume)?.let { HEADER to it },
        reasonHeader(version, path, resume)?.let { REASON_HEADER to it })
}
