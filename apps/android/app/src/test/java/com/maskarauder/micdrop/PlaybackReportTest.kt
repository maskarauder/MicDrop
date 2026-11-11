package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class PlaybackReportTest {
    @Test fun liveTelemetryAcknowledgmentDoesNotClaimThatALogWasSaved() {
        val delivery = ReportDelivery(1)
        delivery.acknowledge("not_recorded", 4, 4)
        assertTrue(delivery.enabled)
        assertEquals("Live status shared with Windows; not saved to a log", delivery.text)
        delivery.acknowledge("not_recorded", 4, 5)
        assertFalse(delivery.enabled)
    }

    @Test fun diagnosticsFallbackPreservesTheSettingsSnapshot() {
        val control = mapOf("version" to 1, "enabled" to false)
        val body = mapOf("version" to 3, "android" to emptyMap<String, Any>(), "phone_control" to control)
        val delivery = ReportDelivery(1)
        var requests = 0
        delivery.exchangeStatus(body, { false }) { request ->
            requests++
            if (requests == 1) throw HttpFailure(400)
            assertSame(control, request!!["phone_control"])
            assertEquals(setOf("version", "phone_control"), request.keys)
        }
        assertEquals(2, requests)
    }

    @Test fun tlsTrustCountersAreOptionalAndContainOnlyBoundedDiagnostics() {
        val report = PlaybackReport(1, "2026-10-25T04:26:18Z", 10000, null, "Connecting", "waiting",
            PlaybackSnapshot("unavailable", "unavailable", emptyMap()))
        assertFalse(report.fields().containsKey("tls_certificate_verification"))
        val trust = TurnTlsTrustSnapshot(2, 1, TurnTlsTrustResult.TRUSTED)
        assertEquals(trust.fields(), report.copy(tlsVerification = trust).fields()["tls_certificate_verification"])
        assertEquals(setOf("version", "checks", "failures", "last_result"), trust.fields().keys)
    }
    @Test fun routeSelectionIsIncludedOnlyWhenRequested() {
        val routes = RouteSelectionSnapshot(true, true, 0, 2)
        val report = PlaybackReport(1, "2026-10-11T00:00:00Z", 10000, null, "Connected", "running",
            PlaybackSnapshot("Opus", "direct / udp", emptyMap()))
        assertFalse(report.fields().containsKey("route_selection"))
        assertEquals(routes.fields(), report.copy(routeSelection = routes).fields()["route_selection"])
    }
    @Test fun selectedTransportIsOptionalForOlderHostsAndDoesNotChangeLegacyPath() {
        val transport = MediaTransportSnapshot("relay", "relay", "udp", "tls")
        val report = PlaybackReport(1, "2026-10-09T00:00:00Z", 10000, null, "Connected", "running",
            PlaybackSnapshot("Opus", transport.legacyPath, emptyMap(), transport))
        assertFalse(report.fields().containsKey("media_transport"))
        val fields = report.copy(mediaTransport = transport).fields()
        assertEquals(transport.fields(), fields["media_transport"])
        assertEquals("relay / udp", fields["path"])
    }

    @Test fun initialGatheringIsOptionalInPeriodicReports() {
        val gathering = IceGathering.initial("", false, true, true, 15001)
        val report = PlaybackReport(1, "2026-10-09T00:00:00Z", 10000, null, "Connected", "running",
            PlaybackSnapshot("Opus", "relay / udp", emptyMap()), iceGathering = gathering)
        assertEquals(gathering.fields(), report.fields()["ice_gathering"])
        assertFalse(report.copy(iceGathering = null).fields().containsKey("ice_gathering"))
    }

    @Test fun outputControlIsOptionalBoundedAndContainsNoPhysicalDeviceIdentity() {
        val control = OutputControlSnapshot("default", false, "waiting", "bluetooth", false, false, 0, "none", 2, null)
        val report = PlaybackReport(1, "2026-01-01T00:00:00Z", 10000, null, "Connected", "waiting",
            PlaybackSnapshot("Opus", "direct / udp", emptyMap()), outputControl = control)
        assertEquals(control.fields(), report.fields()["output_control"])
        assertEquals(setOf("version", "selection", "requested_enabled", "phase", "pause", "default_matches",
            "system_route_known", "transfers", "transfer_result", "playout_recreations", "nearby_permission"), control.fields().keys)
        assertFalse(report.copy(outputControl = null).fields().containsKey("output_control"))
    }
    @Test fun optionalProcessingAndRecoveryCarryPolicyWithoutIdentifiers() {
        val report = PlaybackReport(1, "2026-01-01T00:00:00Z", 10000, null, "Connected", "running",
            PlaybackSnapshot("Opus", "direct / udp", emptyMap()),
            microphone = MicrophoneSnapshot("running", "built-in microphone", 48000, 1), mode = StreamMode.DUPLEX,
            microphoneProcessing = MicrophoneProcessing(true, false),
            lanRecovery = LanRecovery(true).fields("wifi"))
        assertEquals(mapOf("echo_cancellation_requested" to true, "noise_reduction_requested" to false),
            (report.fields()["microphone"] as Map<*, *>)["processing"])
        assertEquals(setOf("phase", "restarts", "signaling_route"), (report.fields()["lan_recovery"] as Map<*, *>).keys)
        assertFalse(report.copy(microphoneProcessing = null, lanRecovery = null).fields().containsKey("lan_recovery"))
    }
    @Test fun wireFieldsPreserveUnknownsAndSignedLossWithoutCopyText() {
        val environment = EnvironmentSnapshot("0.1.0-dev", "local", "Test", "Phone", "16", 36,
            null, "normal", true, false)
        val report = PlaybackReport(1, "2026-09-28T21:00:00Z", 10000, environment, "Connected", "running",
            PlaybackSnapshot("Opus", "direct / udp", mapOf("buffer_ms" to null, "lost_packets" to -1.0)))
        val fields = report.fields()
        assertEquals(setOf("sequence", "captured_at", "uptime_ms", "environment", "state", "media_output", "codec", "path", "metrics"), fields.keys)
        assertEquals(1L, fields["sequence"])
        assertEquals(report.snapshot.values, fields["metrics"])
        assertNull(environment.fields()["expected_routes"])
        assertTrue(environment.text().contains("unavailable"))
        assertNull(report.copy(environment = null).fields()["environment"])
    }

    @Test fun oldHostsAndLoggingFailuresKeepCopyFallback() {
        assertFalse(ReportDelivery(0).enabled)
        assertFalse(ReportDelivery(2).enabled)
        val delivery = ReportDelivery(1)
        assertTrue(delivery.enabled)
        delivery.acknowledge("accepted", 1, 1)
        assertTrue(delivery.text.contains("automatically"))
        delivery.acknowledge("busy", 2, 2)
        assertTrue(delivery.enabled)
        for (state in listOf("disabled", "unavailable", "full", "closed", "unknown")) {
            val failed = ReportDelivery(1); failed.acknowledge(state, 1, 1)
            assertFalse(failed.enabled)
            assertTrue(failed.text.contains("Copy last stream report"))
        }
        delivery.acknowledge("accepted", 2, 3)
        assertFalse(delivery.enabled)
    }

    @Test fun microphoneReportsHaveFixedInputLabelsWithoutPlaybackTiming() {
        val microphone = MicrophoneSnapshot("running", "built-in microphone", 48000, 1)
        val report = PlaybackReport(1, "2026-09-30T00:00:00Z", 10000, null, "Connected", "waiting",
            PlaybackSnapshot("Opus", "direct / udp", mapOf("sent_bytes_total" to 8000.0)), microphone = microphone)
        assertEquals(microphone.fields(), report.fields()["microphone"])
        assertNull(report.fields()["output"])
        assertNull(report.fields()["recovery"])
        assertEquals(setOf("state", "route", "sample_rate_hz", "channels"), microphone.fields().keys)
        val muted = report.copy(microphone = MicrophoneSnapshot("muted", "unavailable"))
        assertEquals(0, (muted.fields()["microphone"] as Map<*, *>)["sample_rate_hz"])
        assertFalse(report.copy(microphone = null).fields().containsKey("microphone"))
    }

    @Test fun duplexReportsBothDirectionsWithOutputTimingAndConsent() {
        val microphone = MicrophoneSnapshot("running", "built-in microphone", 48000, 1)
        val environment = EnvironmentSnapshot("dev", "local", "Test", "Phone", "17", 37, null, "normal", false, false)
        val report = PlaybackReport(1, "2026-09-30T00:00:00Z", 10000, environment, "Connected", "running",
            PlaybackSnapshot("Opus", "direct / udp", mapOf("bytes_total" to 16000.0, "sent_bytes_total" to 8000.0)),
            microphone = microphone, mode = StreamMode.DUPLEX)
        assertEquals("duplex", report.fields(true)["audio_direction"])
        assertEquals(microphone.fields(), report.fields(true)["microphone"])
        assertTrue(report.fields(true).containsKey("output"))
        assertTrue(report.fields(true).containsKey("recovery"))
        assertTrue(environment.text(true, true).contains("explicit consent"))
        assertFalse(environment.text(true, true).contains("Playback: off"))
        assertFalse(report.copy(mode = StreamMode.MICROPHONE).fields(true).containsKey("audio_direction"))
    }

    @Test fun headsetSelectionReportsOnlyFixedLabelsAndVerification() {
        for (kind in MicrophoneKind.entries) {
            val microphone = MicrophoneSnapshot("running", kind.label, 48000, 1, kind.label, true)
            assertEquals(kind.label, microphone.fields()["requested_route"])
            assertEquals(true, microphone.fields()["route_verified"])
            assertEquals(setOf("state", "route", "sample_rate_hz", "channels", "requested_route", "route_verified"), microphone.fields().keys)
            val muted = microphone.copy(state = "muted", route = "unavailable", routeVerified = false)
            assertEquals(false, muted.fields()["route_verified"])
            assertTrue(muted.text().contains(kind.label))
        }
    }

    @Test fun schemaRejectionFallsBackWithoutMaskingSessionErrors() {
        for (code in listOf(400, 404, 405, 409, 413, 422)) {
            val delivery = ReportDelivery(1)
            assertTrue(delivery.reject(code)); assertFalse(delivery.enabled)
        }
        for (code in listOf(401, 410, 429, 500, 503)) {
            val delivery = ReportDelivery(1)
            assertFalse(delivery.reject(code)); assertTrue(delivery.enabled)
        }
    }

    @Test fun rejectedReportRetriesWithoutDroppingOrRegeneratingIce() {
        for (iceField in listOf(null, "ice", "continuous_ice")) {
            val delivery = ReportDelivery(1)
            val update = mapOf("version" to 1, "generation" to 2, "revision" to 3)
            val body = linkedMapOf<String, Any>("version" to 3, "android" to mapOf("sequence" to 7)).apply {
                iceField?.let { put(it, update) }
            }
            var calls = 0
            val response = delivery.exchangeStatus(body, { false }) { request ->
                calls++
                if (calls == 1) {
                    assertSame(body, request)
                    throw HttpFailure(400)
                }
                if (iceField == null) assertNull(request) else {
                    assertEquals(setOf("version", iceField), request!!.keys)
                    assertEquals(3, request["version"])
                    assertSame(update, request[iceField])
                }
                "accepted"
            }
            assertEquals("accepted", response)
            assertEquals(2, calls)
            assertFalse(delivery.enabled)
            assertTrue(body.containsKey("android"))
        }
    }

    @Test fun iceRejectionAfterRemovingReportIsStillFatal() {
        for (iceField in listOf("ice", "continuous_ice")) {
            val delivery = ReportDelivery(1)
            val body = mapOf("version" to 3, "android" to emptyMap<String, Any>(), iceField to mapOf("generation" to 99))
            val rejectedIce = HttpFailure(400)
            var calls = 0
            val error = assertThrows(HttpFailure::class.java) {
                delivery.exchangeStatus<Unit>(body, { false }) { request ->
                    calls++
                    assertEquals(body[iceField], request!![iceField])
                    if (calls == 1) throw HttpFailure(400)
                    assertFalse(request.containsKey("android"))
                    throw rejectedIce
                }
            }
            assertSame(rejectedIce, error)
            assertEquals(2, calls)
        }
    }

    @Test fun reportFallbackDoesNotRetryAuthenticationExpiryOrTransportFailures() {
        val body = mapOf("version" to 3, "android" to emptyMap<String, Any>(), "continuous_ice" to emptyMap<String, Any>())
        for (failure in listOf(HttpFailure(401), HttpFailure(403), HttpFailure(410), HttpFailure(429),
            HttpFailure(500), HttpFailure(503), java.io.IOException(), javax.net.ssl.SSLException("private"), InterruptedException())) {
            val delivery = ReportDelivery(1)
            var calls = 0
            val error = assertThrows(failure.javaClass) {
                delivery.exchangeStatus<Unit>(body, { false }) { calls++; throw failure }
            }
            assertSame(failure, error)
            assertEquals(1, calls)
            assertTrue(delivery.enabled)
        }
    }

    @Test fun stopAndRequestsWithoutDiagnosticsCannotEnterReportFallback() {
        val report = mapOf("version" to 3, "android" to emptyMap<String, Any>())
        for (body in listOf(null, mapOf("version" to 3, "ice" to emptyMap<String, Any>()),
            mapOf("version" to 3, "continuous_ice" to emptyMap<String, Any>()), report)) {
            val delivery = ReportDelivery(1)
            var calls = 0
            var stopped = false
            assertThrows(HttpFailure::class.java) {
                delivery.exchangeStatus<Unit>(body, { stopped }) {
                    calls++; stopped = body === report
                    throw HttpFailure(400)
                }
            }
            assertEquals(1, calls)
            assertTrue(delivery.enabled)
        }
    }
}
