package main

import (
	"context"
	"strings"
	"testing"
)

func TestServiceActionRunsSystemctlAndReadsState(t *testing.T) {
	var calls [][]string
	old := systemctlRun
	defer func() { systemctlRun = old }()
	systemctlRun = func(ctx context.Context, args ...string) ([]byte, error) {
		calls = append(calls, args)
		if args[0] == "show" {
			return []byte("LoadState=loaded\nActiveState=active\nSubState=running\nDescription=A high performance web server\n"), nil
		}
		return nil, nil
	}
	st, err := serviceAction(context.Background(), "nginx", "restart")
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || strings.Join(calls[0], " ") != "restart nginx.service" {
		t.Fatalf("calls = %v", calls)
	}
	if st.Name != "nginx.service" || st.Active != "active" || st.Sub != "running" || st.Description != "A high performance web server" {
		t.Fatalf("state = %+v", st)
	}
}

func TestServiceActionRefusesProtectedUnitsAndBadInput(t *testing.T) {
	old := systemctlRun
	defer func() { systemctlRun = old }()
	ran := false
	systemctlRun = func(ctx context.Context, args ...string) ([]byte, error) { ran = true; return nil, nil }
	cases := []struct{ unit, action, want string }{
		{"srvmon-agent", "restart", "managed by the app"},
		{"srvmon-agent", "start", "managed by the app"},
		{"ssh", "stop", "never stopped"},
		{"sshd.service", "restart", "never stopped"},
		{"nginx", "kill", "unknown action"},
		{"nginx; rm -rf /", "start", "invalid unit"},
		{"../x", "start", "invalid unit"},
	}
	for _, c := range cases {
		_, err := serviceAction(context.Background(), c.unit, c.action)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s %s: err = %v, want %q", c.action, c.unit, err, c.want)
		}
	}
	if ran {
		t.Fatal("systemctl ran for a refused request")
	}
	// starting sshd is allowed (it cannot cut the connection)
	if _, err := serviceAction(context.Background(), "ssh", "start"); err != nil && strings.Contains(err.Error(), "never stopped") {
		t.Fatal("start ssh should be allowed")
	}
}

func TestServiceActionRouteNeedsAllowActions(t *testing.T) {
	srv := newFSServer(t)
	code, body := fsCall(t, srv.Handler(), "POST", "/v1/services/nginx/restart", nil)
	if code != 403 || !strings.Contains(body["error"].(string), "allow_actions") {
		t.Fatalf("got %d %v", code, body)
	}
}
