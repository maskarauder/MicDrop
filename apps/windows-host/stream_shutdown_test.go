package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestShutdownStopsMediaButLetsAcknowledgmentFlush(t *testing.T) {
	entered, flush := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ok":true}`)) // Buffered until the handler returns.
		close(entered)
		<-flush
	}))
	defer server.Close()
	received := make(chan string, 1)
	go func() {
		reply, err := server.Client().Get(server.URL)
		if err != nil {
			received <- "request failed"
			return
		}
		defer reply.Body.Close()
		body, err := io.ReadAll(reply.Body)
		if err != nil {
			received <- "body failed"
			return
		}
		received <- string(body)
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		close(flush)
		t.Fatal("handler did not start")
	}
	mediaStopped, finished := make(chan struct{}), make(chan struct{})
	go func() {
		shutdownStreams([]*http.Server{server.Config}, func() { close(mediaStopped) })
		close(finished)
	}()
	select {
	case <-mediaStopped:
	case <-time.After(3 * time.Second):
		close(flush)
		t.Fatal("media did not stop")
	}
	close(flush)
	select {
	case body := <-received:
		if body != `{"ok":true}` {
			t.Fatalf("lost stop acknowledgment: %s", body)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("acknowledgment timed out")
	}
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown did not finish")
	}
}
