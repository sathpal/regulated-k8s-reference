package main

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testServer(t *testing.T) (*server, *httptest.Server, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	s := newServer(slog.New(slog.NewJSONHandler(&logs, nil)))
	s.ready.Store(true)
	ts := httptest.NewServer(s.routes())
	t.Cleanup(ts.Close)
	return s, ts, &logs
}

func post(t *testing.T, url, key, body string) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest("POST", url+"/v1/payments", strings.NewReader(body))
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp, string(b)
}

const good = `{"amount_minor":125000,"currency":"INR","card_number":"4111111111111111"}`

func TestMaskPAN(t *testing.T) {
	if got := maskPAN("4111111111111111"); got != "411111******1111" {
		t.Fatalf("maskPAN = %q", got)
	}
}

func TestPaymentNeverExposesFullPAN(t *testing.T) {
	_, ts, logs := testServer(t)
	resp, body := post(t, ts.URL, "k1", good)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("status %d: %s", resp.StatusCode, body)
	}
	if strings.Contains(body, "4111111111111111") || strings.Contains(logs.String(), "4111111111111111") {
		t.Fatal("full card number leaked into the response or the audit log")
	}
	if !strings.Contains(logs.String(), `"msg":"audit"`) {
		t.Fatal("no audit line written")
	}
}

func TestIdempotentRetryDoesNotChargeTwice(t *testing.T) {
	s, ts, _ := testServer(t)
	_, first := post(t, ts.URL, "same-key", good)
	resp, second := post(t, ts.URL, "same-key", good)
	if resp.StatusCode != http.StatusOK || first != second || len(s.byID) != 1 {
		t.Fatalf("retry created a second payment: %d %q vs %q", resp.StatusCode, first, second)
	}
}

func TestValidation(t *testing.T) {
	_, ts, _ := testServer(t)
	if resp, _ := post(t, ts.URL, "", good); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing key: %d", resp.StatusCode)
	}
	if resp, _ := post(t, ts.URL, "k2", `{"amount_minor":0,"currency":"INR","card_number":"4111"}`); resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("bad payment: %d", resp.StatusCode)
	}
}

func TestReadinessFollowsDrainState(t *testing.T) {
	s, ts, _ := testServer(t)
	if r, _ := http.Get(ts.URL + "/readyz"); r.StatusCode != 200 {
		t.Fatalf("ready: %d", r.StatusCode)
	}
	s.ready.Store(false) // what SIGTERM does first
	if r, _ := http.Get(ts.URL + "/readyz"); r.StatusCode != 503 {
		t.Fatalf("draining: %d", r.StatusCode)
	}
}
