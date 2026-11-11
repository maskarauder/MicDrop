package session

import (
	"context"
	"net/http"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

type localSignalingKey struct{}

// LocalSignaling wraps only the LAN listener. This is trusted listener metadata,
// never a client header. Both listeners retain the same Host and authorization.
func LocalSignaling(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), localSignalingKey{}, true)))
	})
}

func selectSignalingRoute(peer rtc.Peer, r *http.Request) {
	if p, ok := peer.(interface{ SetLocalSignaling(bool) }); ok {
		local, _ := r.Context().Value(localSignalingKey{}).(bool)
		p.SetLocalSignaling(local)
	}
}
