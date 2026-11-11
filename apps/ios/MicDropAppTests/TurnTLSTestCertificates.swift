import Foundation
import Security

/// Public-only TURN/TLS test certificates (base64 DER) for `TurnTLSTrustVerifierTests`, covering the cases of
/// Android's `turn-test-certificates.json` (`TurnTlsTrustPlatformTest.kt`). Generated once with OpenSSL 3.5;
/// the private keys were discarded and are not in the repository. The Android fixture cannot be reused: its
/// leaves are valid 2020-2100, and Apple's TLS server policy rejects that validity even under test anchors.
///
/// - RSA-2048: `root` → `intermediate` (CA, path length 0) → `server`. P-256: `ecRoot` → `ecIntermediate` →
///   `ecServer`. SHA-256 signatures.
/// - Leaves: SAN `DNS:turn.invalid`, serverAuth EKU, valid 2026-01-01 to 2027-01-01 (365 days).
/// - Issued by `intermediate`: `expired` (valid 2025-01-01 to 2025-12-31), `clientOnly` (clientAuth EKU
///   only) and `invalidSignature` (last signature byte flipped after signing).
/// - CAs are valid from 2025-01-01 until 2040 (intermediates) or 2045 (roots).
enum TurnTLSTestCertificates {
    struct DecodingFailure: Error {}

    /// 2026-06-01T00:00:00Z: inside every fixture's validity except `expired`'s.
    static let verifyDate = Date(timeIntervalSince1970: 1_780_272_000)

    /// DER bytes of a fixture below.
    static func der(_ base64: String) throws -> Data {
        guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw DecodingFailure()
        }
        return der
    }

    /// An in-memory anchor; never added to a keychain or trust store.
    static func certificate(_ base64: String) throws -> SecCertificate {
        let data = try der(base64)
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw DecodingFailure()
        }
        return certificate
    }

    static func chain(_ fixtures: String...) throws -> [Data] {
        try fixtures.map(der)
    }

    static let root = """
        MIIDADCCAeigAwIBAgICUQEwDQYJKoZIhvcNAQELBQAwITEfMB0GA1UEAwwWTWljRHJvcCBUVVJO
        IHRlc3Qgcm9vdDAeFw0yNTAxMDEwMDAwMDBaFw00NTAxMDEwMDAwMDBaMCExHzAdBgNVBAMMFk1p
        Y0Ryb3AgVFVSTiB0ZXN0IHJvb3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDOwzms
        UdETELVFlNHjeasPsIqoB9IDqoQ884hnAbdLJranwmMK0CAxbe7rfqWmGgFEFpFRx2XpHCBgKciQ
        RlpuRKqdbVTVmthFZSpDaBLEd+udRoL8ehlNAVcD4U5eDsApFwfV1qV9e5HQSnXAMAOyaZKweXsy
        jRzYePx9YvIazH6MBl+ngiUZ5oGCujAd2EmIALUp8PH1jBVL522YugFltSQGuapIvPoDh812hVEf
        r6K9XwBuepJT8DVMWLJQgLX8wKP9VmsaCCfQC/DQ/QqHYTt51D/O/y9L05V/y0QWduch1zAXNaY3
        oOTUHUNRfP6Qeztp7PTc3IIk5BVPQJeJAgMBAAGjQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P
        AQH/BAQDAgEGMB0GA1UdDgQWBBTW4jIJZLGYCEz2t+MsfgBGfIelezANBgkqhkiG9w0BAQsFAAOC
        AQEAjW6IEJtUQg0KI7oJFsx6la6eN33xcyaq3W0e562q/lzAW+Wqy8kWmynQynFQIg0cD1u3Tzqv
        wJ91H9m361psXNwV6/8wwITsWrw5jR0i52ssZ1WUnhVQgFayUEGfoZD87FBA7iiPMWM+KnXLiJGb
        2zj2yVtL0FH7CefojzhU9s03r+YgTZLSZJ89lf7Z9B1Z31AV8ah1VGsgLiwuhNgFoOvCY7x2wqdi
        2rS/gBrSmvdriqorFE69X4cB0awTBK8wM21o0aOd2eKjABnPcvEboiUpL9teBxGSG47vID38OWyh
        JLxu2JiNpOucg97oD8thmoBFW7SNW6UriCp7Ah+LWg==
        """

    static let intermediate = """
        MIIDLDCCAhSgAwIBAgICUQIwDQYJKoZIhvcNAQELBQAwITEfMB0GA1UEAwwWTWljRHJvcCBUVVJO
        IHRlc3Qgcm9vdDAeFw0yNTAxMDEwMDAwMDBaFw00MDAxMDEwMDAwMDBaMCkxJzAlBgNVBAMMHk1p
        Y0Ryb3AgVFVSTiB0ZXN0IGludGVybWVkaWF0ZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
        ggEBALTRskVcgiuCP5m+pouNpEryjNypDlyhRNKP168J+sxYpM2zkwLteOmH+9QrM5rqlSSstBfd
        aqmdNds52SBPD3ppK8D1vaYuhu4d55djYHJvZglBfPcD6BvPOXKzBLmkolU4kpygbAls8Elm0VvX
        9EB5ywIBvFbYgjzOP6jTLLs86/SBVCgyC3PD89ZGcEudHmyc25bt51QIaovJsx7noUO0H2hyxOYg
        DvlWIk3nHroC7oP1FcEbFOh/0ibNjGQyM7jAR2Fr3rshFjQNO6bmtJzEMYoUsigjSXfTbnKyF5bk
        zhMTCWaGo3Y19r1W7MsjMLYDkCwKIXvMByK/Ja/YVukCAwEAAaNmMGQwEgYDVR0TAQH/BAgwBgEB
        /wIBADAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFDRKgO7MCoFG3EAuVaaP6Ng6X35LMB8GA1Ud
        IwQYMBaAFNbiMglksZgITPa34yx+AEZ8h6V7MA0GCSqGSIb3DQEBCwUAA4IBAQAS54LPMo1U0o1Q
        d6/EdACnDGYGihHNjTLrkxka1XQAcGpYEa1ZtcKHOaNH/mfYRJ3f86efmyjf3a+z+WrQLwvc9/eG
        YClqcTLQwttMw2iFajdPQNIgyQ0Mhw0c6jWCqFXZC4ytLrinUA2f7NekeeVERgsoH4IS2Joa4Q56
        dxICCJyMLoMNg/Yn8I76w4jvXBOT5MTdGLqC2fspMol1/W/NDgU8cJOI3eP44L8hbLXlFdZIKpuQ
        dh0pO3Z94ovBHBbxi9H9X9+mI4tktd3gcu7aObtxwQ4pka0B01vJNu1kQ7ktG1RSJ8VE8QBR+2KZ
        QDDBTmKSJNm2irK6L977Id5D
        """

    static let server = """
        MIIDWDCCAkCgAwIBAgICUQMwDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweTWljRHJvcCBUVVJO
        IHRlc3QgaW50ZXJtZWRpYXRlMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowIzEhMB8G
        A1UEAwwYTWljRHJvcCBUVVJOIHRlc3Qgc2VydmVyMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
        CgKCAQEAiMperA1uDsXly8rTG9OvXDP0+tEBIm6b/m/6/8D2761FDmyH4XwGXqgj7u16arzZdZYR
        5JrQRc3bidErcnBFm3QS8kdY3A+E0jGjPd1IJju6g07MtEb5X9fKj0+MmJsY+MlHOKlSsdp3PFbV
        zESsUwbtc7ul7+YR5bzMjUDi97jdK7LUI+czYaY0mNBXrv0YHIrjk7/RWwVBnt3810qYP3pycZJN
        Bp3EwndLaWCnyDNXbEUEnMQ80HE9PmBiQwMd1XJdCFHEUdJWF34NWqpmm8zfkoGisRi8Qe42plS4
        /fCUbjrpGadvEc8CN78ZIF+OcBsndm34dUu8UU3Fud88WQIDAQABo4GPMIGMMAwGA1UdEwEB/wQC
        MAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBcGA1UdEQQQMA6CDHR1cm4u
        aW52YWxpZDAdBgNVHQ4EFgQU6kxvvCvuAZgpsCibCPg1T1RyxYQwHwYDVR0jBBgwFoAUNEqA7swK
        gUbcQC5Vpo/o2DpffkswDQYJKoZIhvcNAQELBQADggEBAISR/3U9wvUPWtQQPosyDP19ZIJ+5SJe
        AAwqPvr2/KvB/kwcUg+pbVnh6mCXzfQYmvkf+gtG21Lj95Ek/vt0IRB8G9TZkkbYDvgbiyetKesp
        +QVUaomEvESWoLgjhJ6zSMznZAuBrKG0DfOn5/2CnvuJnqgurt8d14uLpHcmdhRSvb8/2yVNNyCD
        7PXs91t6KONXrc8fdaJH/ErPQN2So+Z6LLmf69JPpkfMQLTkCvsD1EbVlU9XmjZXsODpILZwXBKm
        kvXKfRh0H0ZDtP2JMviY9sizl596GrEIO81a+ghhK3csA4Nb0Zqa8aM3++hF0MokmbwJREwqA/bE
        gF37ykI=
        """

    static let ecRoot = """
        MIIBezCCASCgAwIBAgICUgEwCgYIKoZIzj0EAwIwJDEiMCAGA1UEAwwZTWljRHJvcCBUVVJOIHRl
        c3QgRUMgcm9vdDAeFw0yNTAxMDEwMDAwMDBaFw00NTAxMDEwMDAwMDBaMCQxIjAgBgNVBAMMGU1p
        Y0Ryb3AgVFVSTiB0ZXN0IEVDIHJvb3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQMklRyjZyJ
        2dDhw8Gz0dx4Kr0hw1r21s/P6ea77WtkK6mqq9br4ih9MC1QZNPKELwFY8AgPpeonesgDeOipn9R
        o0IwQDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQUEAPFOyvwamDv
        0/kU280VNcpwA5QwCgYIKoZIzj0EAwIDSQAwRgIhAM1cg1AX0zuDJd0ezE1TbJyv39MhL3J6z79i
        WlinBROMAiEAkiSDfCqIVyn+44fEAX8QNXJpmwfRIzRJ+nHIUbvn62E=
        """

    static let ecIntermediate = """
        MIIBpTCCAUygAwIBAgICUgIwCgYIKoZIzj0EAwIwJDEiMCAGA1UEAwwZTWljRHJvcCBUVVJOIHRl
        c3QgRUMgcm9vdDAeFw0yNTAxMDEwMDAwMDBaFw00MDAxMDEwMDAwMDBaMCwxKjAoBgNVBAMMIU1p
        Y0Ryb3AgVFVSTiB0ZXN0IEVDIGludGVybWVkaWF0ZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
        BP8Ro+vOzPqEZixcRaALuLBIl4bJr81NKIZdyqH0QKY91sAOvjRVzLHPsEJgxQXMtc27yZoQEex0
        zGWA/udHKsGjZjBkMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQW
        BBQc/nI1G/wnYPpy8zmn9iHdsZbkLTAfBgNVHSMEGDAWgBQQA8U7K/BqYO/T+RTbzRU1ynADlDAK
        BggqhkjOPQQDAgNHADBEAiAcHRQ3bOl3wqVqqHeNZhnR1ryT0MY9GCOhEoO7+FEXRgIgTH2UfnzC
        YQXJ6R3uJZUJw5JF5Fg6Qm3OXhIIz+rD9pY=
        """

    static let ecServer = """
        MIIB0jCCAXigAwIBAgICUgMwCgYIKoZIzj0EAwIwLDEqMCgGA1UEAwwhTWljRHJvcCBUVVJOIHRl
        c3QgRUMgaW50ZXJtZWRpYXRlMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowJjEkMCIG
        A1UEAwwbTWljRHJvcCBUVVJOIHRlc3QgRUMgc2VydmVyMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcD
        QgAE9fQ/EHnlneZDBziMbCq8RjFT1Gh5AuyyMkoJfzsfuSbiN5LzrIf+fb0FpoPxYujwgNFtxaY7
        +sReQjffLaZpBaOBjzCBjDAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAK
        BggrBgEFBQcDATAXBgNVHREEEDAOggx0dXJuLmludmFsaWQwHQYDVR0OBBYEFJ2+PUrdUZt5fLQm
        tTtu/uFhG12eMB8GA1UdIwQYMBaAFBz+cjUb/Cdg+nLzOaf2Id2xluQtMAoGCCqGSM49BAMCA0gA
        MEUCIQDrlEbyoxqldXXPthbNujwKzi/SJhTjEVOebCdQa8sCZwIgL6eD3tzEkzO6Gm5UdDIHml9z
        y6jHOGBoDoBSKdP1uOA=
        """

    static let expired = """
        MIIDWTCCAkGgAwIBAgICUQQwDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweTWljRHJvcCBUVVJO
        IHRlc3QgaW50ZXJtZWRpYXRlMB4XDTI1MDEwMTAwMDAwMFoXDTI1MTIzMTAwMDAwMFowJDEiMCAG
        A1UEAwwZTWljRHJvcCBUVVJOIHRlc3QgZXhwaXJlZDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
        AQoCggEBAOTuKyI3gm53Dug005yTCUrpEG74XHXgt+LMHbrsb7pqhLmNmUVoarXiryvAJoX2tIx9
        zHx3Q9HILGlGh/UPliKwPyBTD0yQeEebHtS2I6mbiO9igI2BuLtdyD6u6nPqRQNot4dl6S9bFbap
        A5yuCx0+wXG3phSXClot51SDFbXEXTa9CQ6xNtbppQfpGvyRnL1rz8MswW5/PmN71XkFCwWOy++1
        i/jNgKZkFlnXo1hPJpegVAKXr3madqnV8cSdLb9+sYPA9x0OSprHlgvVm0VxBQ2K8azJFBkioJOp
        LFZtUfpmXrpRrHs1JUFLVG1rmG/h7NVeqZ4cjpA5lh6FngUCAwEAAaOBjzCBjDAMBgNVHRMBAf8E
        AjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAXBgNVHREEEDAOggx0dXJu
        LmludmFsaWQwHQYDVR0OBBYEFImR0uMG/mDqWZ4URBpGaR42JUBGMB8GA1UdIwQYMBaAFDRKgO7M
        CoFG3EAuVaaP6Ng6X35LMA0GCSqGSIb3DQEBCwUAA4IBAQBwzVuOg/keZl6STya5u2ATk3gEDRlp
        BbzL8nW+C8tHRP7HYABdKc0/0QHS2DabYTkNwJjEUBQrm5aeiHmP+Rkg1CjwwHtTLQAGLx3oM3QQ
        kCpd+1ZZEOj5Nucjn2ykRinJLePjAultF+7l965AeOcietgRSR9Vd92qTrsq9AnKC2YNsoT1LE0U
        2Ar08XdPRQM0Iw2I+7JnMLr2IBcPyDeqi9jnp0foCFroJ+8pcIbSlNWn4c0l3bwaLsthsbJ1R1xn
        xg4/juyU2ApAQKvf4JGfubg81ZiBFiUoygdlJ8ceSWks547jcl2hNHL7oxbD9/AvzqRSQoloR/U/
        NQjIi31g
        """

    static let clientOnly = """
        MIIDXTCCAkWgAwIBAgICUQUwDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweTWljRHJvcCBUVVJO
        IHRlc3QgaW50ZXJtZWRpYXRlMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowKDEmMCQG
        A1UEAwwdTWljRHJvcCBUVVJOIHRlc3QgY2xpZW50IG9ubHkwggEiMA0GCSqGSIb3DQEBAQUAA4IB
        DwAwggEKAoIBAQDRE4OSowaCc4pe+Uoln7sclytReZlH0NY33+0fBAPnxHcOKi1ZXB9HAqeIg3dW
        rrBodd52FfIchd5wzKwQ38rS73enwxWjjtQ6Zb8gK55TZEgKNYJD6zb+L/THIvdcULe62abnyncu
        MTOkWALr/vnD7zsh0x91rGKXZ2V6joxbsNl0x9RUHrHLuM+Hhc/UAv3KW1K1k+XLfyT8DGuuGwF7
        7vZn/G0OUlAwo1XmU/DANkilKHbLM+8UUNr8PottV2bnld0bea4bejY5hPPg1SH7iCjeJDoiHAu8
        A/ohcGmRsCvgLVzDUDgqZXztbyYLhptazbgkQ5KFDRNJJPXZwP/VAgMBAAGjgY8wgYwwDAYDVR0T
        AQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwIwFwYDVR0RBBAwDoIM
        dHVybi5pbnZhbGlkMB0GA1UdDgQWBBRzhHYglqyqtoTqH1jLEZQzLX05tTAfBgNVHSMEGDAWgBQ0
        SoDuzAqBRtxALlWmj+jYOl9+SzANBgkqhkiG9w0BAQsFAAOCAQEAOf2IuyVApdl4JPovixApbi/i
        6ILRcDP7p2UdXwpYlIaL9T4B0sVZHExaLPwfuGuWVN51KzLML/Hd1ZmyC2xuLsuQYgvVFiLOhiOL
        hylBRma/QmamQ9ce4GMs5hu4IUkcfkZ22ApNQ1jgmwRxMUN9PPDn44vO7XjmTV+b6IX+z40zz6za
        HG6d9qg3dpPZ6lZjbOLzIhvEpVjmmMsckdW9JCn4tMLmmaeqcOjgbZfL2m8Szq2rABwZ07iJc012
        hQpvuzv7DoEcOOIO0h0Zv1wyasDxCbAHPHhfob47TecmjZ5Yw9aWn2nEW3nq2NcCSY709zYarmKK
        0DNkv4tNRpq/vw==
        """

    static let invalidSignature = """
        MIIDYzCCAkugAwIBAgICUQYwDQYJKoZIhvcNAQELBQAwKTEnMCUGA1UEAwweTWljRHJvcCBUVVJO
        IHRlc3QgaW50ZXJtZWRpYXRlMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowLjEsMCoG
        A1UEAwwjTWljRHJvcCBUVVJOIHRlc3QgaW52YWxpZCBzaWduYXR1cmUwggEiMA0GCSqGSIb3DQEB
        AQUAA4IBDwAwggEKAoIBAQD2v/mnljZq2QZp1Kn9gp9Iidx3+aWI9WFN3d66W58LgYK5u+0iYHpl
        HQHz4+vCVknHG6Vk5PZ+y42/2QnHBrZXsJOZrcmADlZD/M+Vh0MT6DGNV2dZ3ef1WdgFDaTazpy7
        bu+6LW5RItG64o2GNV6+Hhuw5lnOIZWYL8FO9pkM5xr7pZ/2poeJmnfcaSGsz0j8g/RIYWWLrxbU
        TduaKYX1P8IPVF7jEEivrsO7jRvc5Cx5chGzR7aRpAZkfXjabIZQZWJcMzJLfJaJtvQBFDpO7oFu
        QifgmUFh40tj+Yt6Q9ZNdrs4sKnqSIcrAphqgmWGU2ZJt3gQlZGTdSXY+VrdAgMBAAGjgY8wgYww
        DAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFwYDVR0R
        BBAwDoIMdHVybi5pbnZhbGlkMB0GA1UdDgQWBBQ4LMIcuE/GMhnxX0wIy9kSwog3IjAfBgNVHSME
        GDAWgBQ0SoDuzAqBRtxALlWmj+jYOl9+SzANBgkqhkiG9w0BAQsFAAOCAQEAaLNqV7Fu0XMTqDxv
        cYHWhZ1VhnFyBWfe8U56HRoEOdFw1g7cc9USKyMOycvPusbZFIpwy86O6RFsHZU82ou8IVw1t/i8
        gDJtHbdbP+x1RYWq0PIeuoLGiVimdBoVE5dKJFQulJL1sVQeJGHBRhpZJOITx4l2tsEoU5cGGJuO
        F2f/uC8vtA8G7AiqEC6/YMQjMshd0xRmnzJKr6ydt0flr5+JCvHBiAq6IZoBVJSCgCyn6pT4SQmP
        exErJ4neLt6YR0v4xj1kJu2ieg8rsmTNA0GNwOsr0SBbaZkJvdZEz3WOzEdmrNboX/Fw8dr+QTEY
        YLJfCDGT/lGfQ93gvRWiig==
        """
}
