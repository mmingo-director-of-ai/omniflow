package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type mcpBrokerEndpoint struct {
	Socket string `json:"socket"`
	Token  string `json:"token"`
}
type mcpLaunchRequest struct {
	Token  string          `json:"token"`
	Config mcpServerConfig `json:"config"`
}

// macOS cannot stack sandbox_init profiles on an already sandboxed child.
// This launch-only mode is started before the host activates its IP deny rule.
// It accepts only authenticated local sockets and starts EVERY server through
// the restrictive sandbox wrapper. It never executes MCP operations itself.
func serveMCPBroker(ctx context.Context, input io.Reader) error {
	reader := bufio.NewReaderSize(input, 4096)
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return err
	}
	var endpoint mcpBrokerEndpoint
	if json.Unmarshal(line, &endpoint) != nil || len(endpoint.Token) != 64 || !filepath.IsAbs(endpoint.Socket) || len(endpoint.Socket) > 100 {
		return errors.New("invalid_broker_bootstrap")
	}
	directory := filepath.Dir(endpoint.Socket)
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("private_broker_directory_required")
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: endpoint.Socket, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.RemoveAll(directory)
	if err := os.Chmod(endpoint.Socket, 0600); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// Closing the parent's lifetime pipe (including a host crash) shuts down
	// the listener and all children. No LaunchAgent or daemon is installed.
	go func() { _, _ = io.Copy(io.Discard, reader); cancel() }()
	go func() { <-ctx.Done(); _ = listener.Close() }()
	var workers sync.WaitGroup
	defer func() { cancel(); workers.Wait() }()
	slots := make(chan struct{}, 8)
	for {
		connection, err := listener.AcceptUnix()
		if err != nil {
			return nil
		}
		select {
		case slots <- struct{}{}:
		default:
			_ = connection.Close()
			continue
		}
		workers.Add(1)
		go func() {
			defer workers.Done()
			defer func() { <-slots }()
			defer connection.Close()
			finished := make(chan struct{})
			defer close(finished)
			go func() {
				select {
				case <-ctx.Done():
					_ = connection.Close()
				case <-finished:
				}
			}()
			_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
			buffer := bufio.NewReaderSize(connection, 32768)
			line, err := buffer.ReadSlice('\n')
			if err != nil {
				return
			}
			var request mcpLaunchRequest
			if json.Unmarshal(line, &request) != nil || subtle.ConstantTimeCompare([]byte(request.Token), []byte(endpoint.Token)) != 1 {
				return
			}
			if len(request.Config.Arguments) > 32 || len(request.Config.Command) > 4096 {
				return
			}
			for _, arg := range request.Config.Arguments {
				if len(arg) > 4096 {
					return
				}
			}
			_ = connection.SetDeadline(time.Now().Add(190 * time.Second))
			workdir, err := os.MkdirTemp(directory, "server-")
			if err != nil {
				return
			}
			defer os.RemoveAll(workdir)
			// The transport creates its own final child directory, keeping the
			// launcher's socket and other servers outside the write/read grant.
			transport := &localMCPTransport{config: request.Config, workdir: filepath.Join(workdir, "work"), ctx: ctx}
			if err := transport.Connect(); err != nil {
				return
			}
			defer transport.Close()
			if _, err := connection.Write([]byte("{\"ready\":true}\n")); err != nil {
				return
			}
			copied := make(chan struct{}, 1)
			go func() { _, _ = io.Copy(transport.stdin, buffer); copied <- struct{}{} }()
			for {
				select {
				case <-ctx.Done():
					return
				case <-copied:
					return
				case item, ok := <-transport.input:
					if !ok || item.err != nil {
						return
					}
					if _, err := connection.Write(append(item.data, '\n')); err != nil {
						return
					}
				}
			}
		}()
	}
}

func (t *localMCPTransport) connectBroker() error {
	if t.broker == nil || len(t.broker.Token) != 64 || !filepath.IsAbs(t.broker.Socket) {
		return errors.New("mcp_launcher_unavailable")
	}
	var connection net.Conn
	var err error
	for attempt := 0; attempt < 30; attempt++ {
		connection, err = (&net.Dialer{}).DialContext(t.ctx, "unix", t.broker.Socket)
		if err == nil {
			break
		}
		select {
		case <-t.ctx.Done():
			return t.ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
	if err != nil {
		return errors.New("mcp_launcher_unavailable_restart_omniflow")
	}
	if deadline, ok := t.ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	}
	// Tool grants stay in the Atlas process; the launcher needs only the
	// user-selected executable and literal argument vector.
	config := mcpServerConfig{Command: t.config.Command, Arguments: t.config.Arguments}
	data, err := json.Marshal(mcpLaunchRequest{Token: t.broker.Token, Config: config})
	if err != nil || len(data) >= 32768 {
		_ = connection.Close()
		return errors.New("mcp_launch_argument_limit")
	}
	if _, err := connection.Write(append(data, '\n')); err != nil {
		_ = connection.Close()
		return err
	}
	reader := bufio.NewReader(connection)
	line, err := reader.ReadSlice('\n')
	if err != nil || string(line) != "{\"ready\":true}\n" {
		_ = connection.Close()
		return errors.New("mcp_launch_failed")
	}
	_ = connection.SetDeadline(time.Time{})
	t.connection = connection
	t.stdin = connection
	t.input, t.done, t.wait = make(chan mcpInput, 1), make(chan struct{}), make(chan struct{})
	go func() { defer close(t.wait); t.readOutput(reader) }()
	return nil
}
