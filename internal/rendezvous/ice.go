package rendezvous

import (
	"crypto/hmac"
	"crypto/sha1" // coturn's TURN REST credential construction requires HMAC-SHA1.
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

const CredentialLifetime = 10 * time.Minute

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type ICEConfiguration struct {
	Version   int         `json:"version"`
	ExpiresAt int64       `json:"expires_at"`
	Servers   []ICEServer `json:"ice_servers"`
}

func (s *Server) ice(w http.ResponseWriter, p *principal) {
	s.mu.Lock()
	allowed := p.ice.allow(s.now(), 1)
	s.mu.Unlock()
	if !allowed {
		http.Error(w, "Try later", http.StatusTooManyRequests)
		return
	}
	result := ICEConfiguration{Version: 1, ExpiresAt: s.now().Add(CredentialLifetime).Unix(), Servers: []ICEServer{}}
	if len(s.config.STUNURLs) > 0 {
		result.Servers = append(result.Servers, ICEServer{URLs: s.config.STUNURLs})
	}
	if turn := s.config.TURN; turn != nil {
		// No device identity, bearer token or address is included in the username.
		user := strconv.FormatInt(result.ExpiresAt, 10) + ":" + NewToken()
		mac := hmac.New(sha1.New, []byte(turn.SharedSecret))
		_, _ = mac.Write([]byte(user))
		result.Servers = append(result.Servers, ICEServer{URLs: turn.URLs, Username: user, Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}
