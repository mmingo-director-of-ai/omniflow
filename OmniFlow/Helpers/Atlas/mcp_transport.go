package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/mcp"
)

const maxMCPFrameBytes = 24 * 1024 * 1024 // accommodates base64 framing, with a separate expanded-data quota

type mcpInput struct {
	data []byte
	err  error
}

// Implements the canonical SDK's Transport. The SDK's default stdio reader is
// unbounded; this host adapter adds deadlines, frame limits and process cleanup.
type localMCPTransport struct {
	http           *mcpHTTPTransport
	broker         *mcpBrokerEndpoint
	connection     net.Conn
	config         mcpServerConfig
	workdir        string
	command        *exec.Cmd
	stdin          io.WriteCloser
	input          chan mcpInput
	done           chan struct{}
	wait           chan struct{}
	closeOnce      sync.Once
	ctx            context.Context
	pending        json.RawMessage
	lastResult     json.RawMessage
	sequence       int
	catalogChanged bool
}

func (t *localMCPTransport) Connect() error {
	if t.config.Transport == "http" {
		if t.http != nil {
			return errors.New("mcp_already_connected")
		}
		var err error
		t.http, err = newMCPHTTP(t.config)
		return err
	}
	if t.broker != nil {
		return t.connectBroker()
	}
	if t.command != nil {
		return errors.New("mcp_already_connected")
	}
	if !filepath.IsAbs(t.config.Command) || len(t.config.Arguments) > 32 {
		return errors.New("local_executable_required")
	}
	info, err := os.Stat(t.config.Command)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return errors.New("mcp_executable_unavailable")
	}
	if err := os.Mkdir(t.workdir, 0700); err != nil {
		return err
	}
	// Seatbelt path filters compare canonical paths (/var is a symlink).
	canonical, err := filepath.EvalSymlinks(t.workdir)
	if err != nil {
		return err
	}
	t.workdir = canonical
	// A server is a user-selected local executable, never a model-selected shell
	// command. The sandbox is inherited by descendants. No outbound transports,
	// writes outside the disposable work directory, or Apple Events are allowed.
	profile := `(version 1) (allow default) (deny network*) (deny file-write*) (deny appleevent-send) (deny mach-lookup) ` +
		`(deny file-read* (subpath ` + jsonText(filepath.Dir(t.workdir)) + `)) ` +
		`(allow file-read* file-write* (subpath ` + jsonText(t.workdir) + `)) ` +
		`(deny file-read* (regex #"^/Users/[^/]+/(\\.ssh|\\.aws|\\.azure|\\.kube|\\.gnupg)(/|$)")) ` +
		`(deny file-read* (regex #"^/Users/[^/]+/Library/(Keychains|Cookies)(/|$)"))`
	args := append([]string{"-p", profile, t.config.Command}, t.config.Arguments...)
	command := exec.Command("/usr/bin/sandbox-exec", args...)
	command.Dir = t.workdir
	command.Env = []string{"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG=en_US.UTF-8", "HOME=" + t.workdir, "TMPDIR=" + t.workdir, "GOTRACEBACK=none"}
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return err
	}
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return errors.New("mcp_start_failed")
	}
	t.command, t.stdin = command, stdin
	t.input, t.done, t.wait = make(chan mcpInput, 1), make(chan struct{}), make(chan struct{})
	go t.readOutput(stdout)
	go func() { _ = command.Wait(); close(t.wait) }()
	return nil
}

func (t *localMCPTransport) readOutput(stdout io.Reader) {
	defer close(t.input)
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), maxMCPFrameBytes)
	for scanner.Scan() {
		item := mcpInput{data: append([]byte(nil), scanner.Bytes()...)}
		select {
		case t.input <- item:
		case <-t.done:
			return
		}
	}
	if scanner.Err() != nil {
		select {
		case t.input <- mcpInput{err: errors.New("mcp_frame_limit_or_io_failure")}:
		case <-t.done:
		}
	}
}

func (t *localMCPTransport) Close() error {
	t.closeOnce.Do(func() {
		if t.http != nil {
			t.http.close()
			return
		}
		if t.connection != nil {
			close(t.done)
			_ = t.connection.Close()
			<-t.wait
			return
		}
		if t.command != nil {
			close(t.done)
			_ = t.stdin.Close()
			// Kill the entire owned process group, including server workers.
			_ = syscall.Kill(-t.command.Process.Pid, syscall.SIGKILL)
			<-t.wait
		}
	})
	return nil
}

func (t *localMCPTransport) OnError(func(error)) {}
func (t *localMCPTransport) OnClose(func())      {}

func (t *localMCPTransport) write(value interface{}) error {
	if t.http != nil {
		return t.http.post(t.ctx, value, false, false)
	}
	data, err := json.Marshal(value)
	if err != nil || len(data) > 32768 {
		return errors.New("mcp_request_limit")
	}
	data = append(data, '\n')
	finished := make(chan error, 1)
	go func() { _, err := t.stdin.Write(data); finished <- err }()
	select {
	case err := <-finished:
		return err
	case <-t.ctx.Done():
		_ = t.Close()
		return t.ctx.Err()
	}
}

func (t *localMCPTransport) Send(request *mcp.JSONRPCRequest) error {
	t.pending = append(json.RawMessage(nil), request.ID...)
	t.lastResult = nil
	if t.http != nil {
		return t.http.post(t.ctx, request, true, request.Method == "initialize")
	}
	return t.write(request)
}
func (t *localMCPTransport) SendNotification(notification *mcp.JSONRPCNotification) error {
	return t.write(notification)
}

func (t *localMCPTransport) Receive() (*mcp.JSONRPCResponse, error) {
	for ignored := 0; ignored < 64; ignored++ {
		var item mcpInput
		if t.http != nil {
			item.data, item.err = t.http.nextFrame()
			if item.err != nil {
				if errors.Is(t.ctx.Err(), context.DeadlineExceeded) {
					return nil, errors.New("mcp_http_timeout")
				}
				if t.ctx.Err() != nil {
					return nil, t.ctx.Err()
				}
				return nil, item.err
			}
		} else {
			select {
			case <-t.ctx.Done():
				_ = t.Close()
				return nil, t.ctx.Err()
			case received, ok := <-t.input:
				if !ok || received.err != nil {
					_ = t.Close()
					return nil, errors.New("mcp_transport_closed_or_oversized")
				}
				item = received
			}
		}
		var wire struct {
			JSONRPC string            `json:"jsonrpc"`
			ID      json.RawMessage   `json:"id"`
			Method  string            `json:"method"`
			Result  json.RawMessage   `json:"result"`
			Error   *mcp.JSONRPCError `json:"error"`
		}
		if json.Unmarshal(item.data, &wire) != nil || wire.JSONRPC != "2.0" {
			return nil, errors.New("mcp_invalid_frame")
		}
		if wire.Method != "" {
			if wire.Method == "notifications/tools/list_changed" {
				t.catalogChanged = true
			}
			if len(wire.ID) != 0 {
				// Sampling, elicitation and root requests cannot invoke host tools,
				// collect secrets, or expand the user's approved permissions.
				if err := t.write(mcp.JSONRPCResponse{JSONRPC: "2.0", ID: wire.ID, Error: &mcp.JSONRPCError{Code: -32601, Message: "Host requests are disabled"}}); err != nil {
					return nil, err
				}
			}
			continue
		}
		if !bytes.Equal(bytes.TrimSpace(wire.ID), t.pending) || (len(wire.Result) == 0 && wire.Error == nil) || (len(wire.Result) > 0 && wire.Error != nil) {
			return nil, errors.New("mcp_response_mismatch")
		}
		if t.http != nil {
			if err := t.http.finishResponse(wire.Result, wire.Error != nil); err != nil {
				return nil, err
			}
		}
		t.lastResult = append(json.RawMessage(nil), wire.Result...)
		// Keep raw JSON to preserve arbitrary schemas and exact integer values
		// across the SDK's marshal/unmarshal bridge.
		return &mcp.JSONRPCResponse{JSONRPC: "2.0", ID: wire.ID, Result: wire.Result, Error: wire.Error}, nil
	}
	return nil, errors.New("mcp_notification_limit")
}

func (t *localMCPTransport) rpc(ctx context.Context, method string, params interface{}) (json.RawMessage, error) {
	requestContext, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	t.ctx = requestContext
	t.sequence++
	data, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	if err := t.Send(&mcp.JSONRPCRequest{JSONRPC: "2.0", ID: json.RawMessage(fmtID(t.sequence)), Method: method, Params: data}); err != nil {
		return nil, err
	}
	response, err := t.Receive()
	if err != nil {
		return nil, err
	}
	if response.Error != nil {
		return nil, errors.New("mcp_server_returned_error")
	}
	return t.lastResult, nil
}

func fmtID(sequence int) string { return jsonText(sequence) }
