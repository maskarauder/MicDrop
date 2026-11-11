package session

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestResumeHintIsBoundedAndOnlyUsesAuthenticatedPhoneIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, client     string
		headers, reasons []string
		code             int
		resume           bool
		reason           string
	}{
		{"legacy client", "phone", nil, nil, 200, false, ""},
		{"resume", "phone", []string{"1"}, nil, 200, true, ""},
		{"manual resume", "phone", []string{"1"}, []string{"manual"}, 200, true, "manual"},
		{"automatic resume", "phone", []string{"1"}, []string{"automatic"}, 200, true, "automatic"},
		{"focus regain resume", "phone", []string{"1"}, []string{"focus_regain"}, 200, true, "focus_regain"},
		{"unknown reason", "phone", []string{"1"}, []string{"accessory"}, 200, true, ""},
		{"longest unknown reason", "phone", []string{"1"}, []string{strings.Repeat("a", 32)}, 200, true, ""},
		{"unpaired resume", "unknown", []string{"1"}, nil, 403, false, ""},
		{"unpaired reason", "unknown", []string{"1"}, []string{"manual"}, 403, false, ""},
		{"duplicate hint", "phone", []string{"1", "1"}, nil, 400, false, ""},
		{"invalid hint", "phone", []string{"true"}, nil, 400, false, ""},
		{"empty hint", "phone", []string{""}, nil, 400, false, ""},
		{"reason without hint", "phone", nil, []string{"manual"}, 400, false, ""},
		{"reason with invalid hint", "phone", []string{"true"}, []string{"manual"}, 400, false, ""},
		{"duplicate reason", "phone", []string{"1"}, []string{"manual", "manual"}, 400, false, ""},
		{"empty reason", "phone", []string{"1"}, []string{""}, 400, false, ""},
		{"long reason", "phone", []string{"1"}, []string{strings.Repeat("a", 33)}, 400, false, ""},
		{"uppercase reason", "phone", []string{"1"}, []string{"Manual"}, 400, false, ""},
		{"reason list", "phone", []string{"1"}, []string{"manual, focus_regain"}, 400, false, ""},
		{"hyphenated reason", "phone", []string{"1"}, []string{"focus-regain"}, 400, false, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls int
			var seen OfferOptions
			h, err := NewPairedHost(microphoneAuthority{}, func(_ time.Time, offer OfferOptions) (Resources, error) {
				calls++
				seen = offer
				return Resources{Peer: &cyclePeer{}}, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			defer h.Close("test")
			r := httptest.NewRequest("POST", "https://host.test/offer", strings.NewReader(`{"version":3}`))
			r.Header.Set("X-Test-Verified-Identity", tc.client)
			r.Header.Set("X-Phone-Key", "spoofed identity")
			for _, value := range tc.headers {
				r.Header.Add(sessionResumeHeader, value)
			}
			for _, value := range tc.reasons {
				r.Header.Add(sessionResumeReasonHeader, value)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.code {
				t.Fatal(w.Code, w.Body.String())
			}
			if tc.code == 200 {
				if calls != 1 || seen.ClientKey != tc.client || seen.Resuming != tc.resume || seen.ResumeReason != tc.reason {
					t.Fatal("factory did not receive authenticated presentation metadata", calls, seen)
				}
			} else if calls != 0 {
				t.Fatal("rejected request allocated media")
			}
		})
	}
}

// Phones may add optional headers; only the named offer headers are validated.
func TestUnrelatedMicDropHeaderDoesNotRejectAResumeOffer(t *testing.T) {
	var seen OfferOptions
	h, err := NewPairedHost(microphoneAuthority{}, func(_ time.Time, offer OfferOptions) (Resources, error) {
		seen = offer
		return Resources{Peer: &cyclePeer{}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")
	r := httptest.NewRequest("POST", "https://host.test/offer", strings.NewReader(`{"version":3}`))
	r.Header.Set("X-Test-Verified-Identity", "phone")
	r.Header.Set(sessionResumeHeader, "1")
	r.Header.Set(sessionResumeReasonHeader, "focus_regain")
	r.Header.Set("X-MicDrop-Session-Resume-Source", "Headset Play")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || !seen.Resuming || seen.ResumeReason != "focus_regain" {
		t.Fatal(w.Code, w.Body.String(), seen)
	}
}

func TestUnpairedLegacyOfferCannotRequestResumePresentation(t *testing.T) {
	for _, headers := range []map[string]string{
		{sessionResumeHeader: "1"},
		{sessionResumeReasonHeader: "manual"},
		{sessionResumeHeader: "1", sessionResumeReasonHeader: "focus_regain"},
	} {
		h := NewHost(reusableToken, time.Now().Add(time.Minute), func(time.Time, OfferOptions) (Resources, error) {
			t.Fatal("legacy resume hint reached resource allocation")
			return Resources{}, nil
		})
		r := httptest.NewRequest("POST", "https://host.test/offer", strings.NewReader(`{"version":2}`))
		r.Header.Set("Authorization", "Bearer "+reusableToken)
		for name, value := range headers {
			r.Header.Set(name, value)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatal(headers, w.Code, w.Body.String())
		}
	}
}
