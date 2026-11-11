package session

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

func TestTrickleStatusHTTP10HasExplicitLengthAcrossCandidateAcknowledgment(t *testing.T) {
	s, peer, token := newTrickleSession(t)
	peer.local = trickleDescription
	for i := 0; i < 6; i++ {
		peer.local += fmt.Sprintf("a=candidate:%d 1 udp 2122260223 2001:db8:1234:5678::%d 5000 typ host generation 0 ufrag host network-id 2 network-cost 10\r\n", i, i+1)
	}
	peer.status.MediaTransport = &rtc.MediaTransport{Version: 1, LocalCandidate: "host", RemoteCandidate: "host", CandidateProtocol: "udp", RelayProtocol: "not_applicable"}
	peer.status.ICEGathering = &rtc.ICEGathering{Result: "trickle", MediaSections: 1}
	server := httptest.NewTLSServer(s)
	defer server.Close()
	tlsConfig := server.Client().Transport.(*http.Transport).TLSClientConfig
	for _, ack := range []int{0, 6} {
		body := strings.Replace(iceStatus(), `"ack":0`, fmt.Sprintf(`"ack":%d`, ack), 1)
		conn, err := tls.Dial("tcp", server.Listener.Addr().String(), tlsConfig)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		_, err = fmt.Fprintf(conn, "POST /status HTTP/1.0\r\nHost: paired.test\r\nConnection: close\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", token, len(body), body)
		if err != nil {
			conn.Close()
			t.Fatal(err)
		}
		response, err := http.ReadResponse(bufio.NewReader(conn), nil)
		if err != nil {
			conn.Close()
			t.Fatal(err)
		}
		payload, err := io.ReadAll(response.Body)
		response.Body.Close()
		conn.Close()
		if err != nil || response.StatusCode != http.StatusOK {
			t.Fatalf("status response failed: code=%d err=%v", response.StatusCode, err)
		}
		if ack == 0 && len(payload) <= 2048 {
			t.Fatal("fixture must exceed Go's automatic Content-Length buffer")
		}
		if response.ContentLength != int64(len(payload)) || len(response.TransferEncoding) != 0 {
			t.Fatalf("status must finish without transport EOF: Content-Length=%d body=%d", response.ContentLength, len(payload))
		}
		var reply struct {
			State string       `json:"state"`
			ICE   rtc.ICEDelta `json:"ice"`
		}
		if json.Unmarshal(payload, &reply) != nil || reply.State != "connected" || reply.ICE.Ack != 1 || len(reply.ICE.Candidates) != 6-ack || !reply.ICE.Complete || peer.added != 1 {
			t.Fatal("status or idempotent ICE acknowledgment changed")
		}
	}
}

func TestResponseEncodingFailureDoesNotSendSuccessOrPartialJSON(t *testing.T) {
	w := httptest.NewRecorder()
	respond(w, map[string]float64{"invalid": math.NaN()})
	if w.Code != http.StatusInternalServerError || strings.Contains(w.Body.String(), "invalid") || strings.Contains(w.Body.String(), "NaN") {
		t.Fatal("encoding failure must be a generic error, not successful or partial JSON")
	}
}
