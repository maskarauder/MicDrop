package com.maskarauder.micdrop

// Every field here is an untrusted LAN hint. Only the saved pairing supplies trust.
internal data class DiscoveredHost(val host: String, val port: Int, val keyHint: String) {
    fun matches(saved: LanInvitation?) = saved?.version == 3 &&
        keyHint == PublicIdentity.hex(saved.fingerprint)

    fun connectionFor(saved: LanInvitation): LanInvitation {
        require(matches(saved))
        return LanInvitation.paired(host, port, PublicIdentity.hex(saved.fingerprint), saved.clientKey, saved.remote)
    }
}

internal object DiscoveryRecord {
    const val TYPE = "_micdrop._tcp"
    const val MAX_SERVICES = 8
    const val MAX_HOSTS = 16
    fun acceptsType(type: String) = type.trimEnd('.').equals(TYPE, true) ||
        type.trimEnd('.').equals("$TYPE.local", true)

    fun parse(addresses: List<String>, port: Int, attributes: Map<String, ByteArray?>): List<DiscoveredHost> {
        // DNS-SD permits key-only TXT entries, represented as null by Android.
        if (attributes.keys != setOf("v", "p", "id") || attributes.values.any { it == null || it.size > 64 }) return emptyList()
        fun text(key: String) = String(requireNotNull(attributes[key]), Charsets.US_ASCII)
        if (text("v") != "1" || text("p") != "3") return emptyList()
        val key = text("id")
        if (!key.matches(Regex("[0-9a-f]{64}"))) return emptyList()
        return addresses.take(8).distinct().mapNotNull { host ->
            try {
                LanInvitation.validateEndpoint(host, port)
                DiscoveredHost(host, port, key)
            } catch (_: IllegalArgumentException) { null }
        }.take(4)
    }
}

// Tokens distinguish a removed/reappearing service from its late NSD callbacks.
// This bounded index is independent of Android so lifecycle races can be tested.
internal class DiscoveryIndex {
    data class Ticket(val service: String, val serial: Long)
    private data class Entry(val ticket: Ticket, var hosts: List<DiscoveredHost> = emptyList())
    private val entries = linkedMapOf<String, Entry>()
    private var serial = 0L
    fun claim(service: String): Ticket? {
        if (service.isBlank() || service.length > 256 || service in entries || entries.size >= DiscoveryRecord.MAX_SERVICES) return null
        val ticket = Ticket(service, ++serial)
        entries[service] = Entry(ticket)
        return ticket
    }
    fun contains(ticket: Ticket) = entries[ticket.service]?.ticket == ticket
    fun update(ticket: Ticket, hosts: List<DiscoveredHost>) {
        if (contains(ticket)) entries.getValue(ticket.service).hosts = hosts.take(4)
    }
    fun remove(service: String): Ticket? = entries.remove(service)?.ticket
    fun clear() { entries.clear() }
    fun hosts(): List<DiscoveredHost> = entries.values.flatMap { it.hosts }.distinct()
        .sortedWith(compareBy({ it.keyHint }, { it.host }, { it.port })).take(DiscoveryRecord.MAX_HOSTS)
}
