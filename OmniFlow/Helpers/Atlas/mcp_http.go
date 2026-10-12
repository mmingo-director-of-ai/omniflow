package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

// Streamable HTTP uses the same SDK Bridge and host approval checks as stdio.
// Credentials exist only in the private run configuration, never model context.
type mcpHTTPTransport struct {
	endpoint     *url.URL
	headers      http.Header
	client       *http.Client
	session      string
	protocol     string
	initializing bool
	response     *http.Response
	reader       *bufio.Reader
	remaining    int64
	stream       bool
	closed       bool
	expired      bool
}

func validateMCPHTTP(config mcpServerConfig) (*url.URL, http.Header, error) {
	if len(config.URL) == 0 || len(config.URL) > 4096 || !safeHeaderValue(config.URL) || strings.Contains(config.URL, " ") {
		return nil, nil, errors.New("invalid_mcp_http_url")
	}
	endpoint, err := url.Parse(config.URL)
	if err != nil || endpoint.User != nil || endpoint.Hostname() == "" || endpoint.Fragment != "" || endpoint.Opaque != "" {
		return nil, nil, errors.New("invalid_mcp_http_url")
	}
	if endpoint.Scheme != "https" && !(endpoint.Scheme == "http" && isLoopbackHost(endpoint.Hostname())) {
		return nil, nil, errors.New("mcp_http_requires_https")
	}
	headers := make(http.Header)
	seenHeaders := make(map[string]bool)
	total := 0
	if len(config.Headers) > 16 {
		return nil, nil, errors.New("mcp_http_header_limit")
	}
	for name, value := range config.Headers {
		canonical := http.CanonicalHeaderKey(name)
		if !headerToken(name) || len(name) > 128 || len(value) > 8192 || !safeHeaderValue(value) || seenHeaders[canonical] {
			return nil, nil, errors.New("invalid_mcp_http_header")
		}
		switch strings.ToLower(name) {
		case "host", "connection", "proxy-connection", "proxy-authorization", "proxy-authenticate", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "content-length", "content-type", "accept", "accept-encoding", "mcp-session-id", "mcp-protocol-version", "last-event-id", "origin":
			return nil, nil, errors.New("reserved_mcp_http_header")
		}
		total += len(name) + len(value)
		if total > 16384 {
			return nil, nil, errors.New("mcp_http_header_limit")
		}
		seenHeaders[canonical] = true
		headers.Set(canonical, value)
	}
	return endpoint, headers, nil
}
func isLoopbackHost(host string) bool {
	return strings.EqualFold(host, "localhost") || net.ParseIP(host).IsLoopback()
}
func headerToken(s string) bool {
	if s == "" {
		return false
	}
	for _, ch := range s {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || strings.ContainsRune("!#$%&'*+-.^_`|~", ch)) {
			return false
		}
	}
	return true
}
func safeHeaderValue(s string) bool {
	for _, ch := range s {
		if ch < 0x20 || ch > 0x7e {
			return false
		}
	}
	return true
}
func supportedMCPProtocol(version string) bool {
	switch version {
	case "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05":
		return true
	}
	return false
}
func newMCPHTTP(config mcpServerConfig) (*mcpHTTPTransport, error) {
	endpoint, headers, err := validateMCPHTTP(config)
	if err != nil {
		return nil, err
	}
	dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		Proxy: nil, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 8 * time.Second, ResponseHeaderTimeout: 12 * time.Second,
		MaxResponseHeaderBytes: 32768, MaxIdleConns: 2, MaxIdleConnsPerHost: 2,
		IdleConnTimeout: 30 * time.Second, DisableCompression: true,
	}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		connection, err := dialer.DialContext(ctx, network, address)
		if err == nil && endpoint.Scheme == "http" {
			addr, ok := connection.RemoteAddr().(*net.TCPAddr)
			if !ok || !addr.IP.IsLoopback() {
				_ = connection.Close()
				return nil, errors.New("mcp_http_requires_loopback")
			}
		}
		return connection, err
	}
	return &mcpHTTPTransport{endpoint: endpoint, headers: headers, client: &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func (h *mcpHTTPTransport) request(ctx context.Context, method string, data []byte) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, h.endpoint.String(), bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("mcp_http_request_failed")
	}
	request.Header = h.headers.Clone()
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "NotchLee/"+sdkVersion)
	if h.session != "" {
		request.Header.Set("Mcp-Session-Id", h.session)
	}
	if h.protocol != "" {
		request.Header.Set("Mcp-Protocol-Version", h.protocol)
	}
	response, err := h.client.Do(request)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, errors.New("mcp_http_timeout")
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		// net/http errors can contain URLs, query strings and credentials.
		return nil, errors.New("mcp_http_connection_failed")
	}
	return response, nil
}
func (h *mcpHTTPTransport) post(ctx context.Context, value interface{}, expectsResponse, initialize bool) error {
	if h.closed {
		return errors.New("mcp_http_closed")
	}
	data, err := json.Marshal(value)
	if err != nil || len(data) > 32768 {
		return errors.New("mcp_request_limit")
	}
	response, err := h.request(ctx, http.MethodPost, data)
	if err != nil {
		return err
	}
	accepted := false
	defer func() {
		if !accepted {
			_ = response.Body.Close()
		}
	}()
	if response.StatusCode >= 300 || response.StatusCode < 200 {
		switch response.StatusCode {
		case 401:
			return errors.New("mcp_authentication_required")
		case 403:
			return errors.New("mcp_http_forbidden")
		case 404:
			if h.session != "" {
				h.expired = true
			}
			return errors.New("mcp_http_endpoint_unavailable")
		case 429:
			return errors.New("mcp_http_rate_limited")
		}
		if response.StatusCode >= 300 && response.StatusCode < 400 {
			return errors.New("mcp_http_redirect_refused")
		}
		return errors.New("mcp_http_status_error")
	}
	sessions := response.Header.Values("Mcp-Session-Id")
	if len(sessions) > 1 {
		return errors.New("invalid_mcp_http_session")
	}
	if len(sessions) == 1 {
		session := sessions[0]
		if session == "" || len(session) > 4096 || !safeHeaderValue(session) || strings.Contains(session, " ") {
			return errors.New("invalid_mcp_http_session")
		}
		if initialize {
			h.session = session
		} else if session != h.session {
			return errors.New("mcp_http_session_changed")
		}
	}
	if !expectsResponse {
		if response.StatusCode != http.StatusAccepted && response.StatusCode != http.StatusNoContent {
			return errors.New("mcp_http_notification_not_accepted")
		}
		// Acknowledgements cannot carry arbitrary streams or unbounded bodies.
		body, readErr := io.ReadAll(io.LimitReader(response.Body, 2))
		if readErr != nil || len(body) != 0 {
			return errors.New("mcp_http_invalid_acknowledgement")
		}
		return nil
	}
	if response.StatusCode != http.StatusOK {
		return errors.New("mcp_http_response_required")
	}
	contentType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || contentType != "application/json" && contentType != "text/event-stream" {
		return errors.New("mcp_http_unsupported_content_type")
	}
	if response.ContentLength > maxMCPFrameBytes {
		return errors.New("mcp_http_response_limit")
	}
	if h.response != nil {
		_ = h.response.Body.Close()
	}
	h.response, h.initializing, h.stream = response, initialize, contentType == "text/event-stream"
	h.remaining = maxMCPFrameBytes + 1
	h.reader = bufio.NewReader(io.LimitReader(response.Body, h.remaining))
	accepted = true
	return nil
}
func (h *mcpHTTPTransport) nextFrame() ([]byte, error) {
	if h.response == nil {
		return nil, errors.New("mcp_http_response_required")
	}
	if !h.stream {
		data, err := io.ReadAll(h.reader)
		if err != nil {
			return nil, errors.New("mcp_http_response_failed")
		}
		if len(data) > maxMCPFrameBytes {
			return nil, errors.New("mcp_http_response_limit")
		}
		if !utf8.Valid(data) {
			return nil, errors.New("mcp_invalid_frame")
		}
		return data, nil
	}
	var event bytes.Buffer
	for {
		line, err := h.reader.ReadString('\n')
		h.remaining -= int64(len(line))
		if h.remaining <= 0 {
			return nil, errors.New("mcp_http_response_limit")
		}
		if err != nil {
			return nil, errors.New("mcp_http_stream_ended_before_response")
		}
		line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		if line == "" {
			if event.Len() != 0 {
				frame := bytes.TrimSuffix(event.Bytes(), []byte{'\n'})
				if !utf8.Valid(frame) {
					return nil, errors.New("mcp_invalid_frame")
				}
				return frame, nil
			}
			continue
		}
		if strings.HasPrefix(line, "data:") {
			data := strings.TrimPrefix(line, "data:")
			data = strings.TrimPrefix(data, " ")
			// Empty priming events are allowed by Streamable HTTP.
			if data != "" || event.Len() != 0 {
				event.WriteString(data)
				event.WriteByte('\n')
			}
		}
	}
}
func (h *mcpHTTPTransport) finishResponse(result json.RawMessage, isError bool) error {
	if h.response != nil {
		_ = h.response.Body.Close()
		h.response = nil
	}
	if h.initializing && !isError {
		var value struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		if json.Unmarshal(result, &value) != nil || !supportedMCPProtocol(value.ProtocolVersion) {
			return errors.New("unsupported_mcp_protocol")
		}
		h.protocol = value.ProtocolVersion
	}
	h.initializing = false
	return nil
}
func (h *mcpHTTPTransport) close() {
	if h.closed {
		return
	}
	h.closed = true
	if h.response != nil {
		_ = h.response.Body.Close()
		h.response = nil
	}
	// Terminate only the session allocated to this run. Never retry tool POSTs:
	// cancellation/disconnection can leave a remote operation's outcome unknown.
	if h.session != "" && !h.expired {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		response, err := h.request(ctx, http.MethodDelete, nil)
		if err == nil {
			_ = response.Body.Close()
		}
		cancel()
	}
	h.client.CloseIdleConnections()
}

// The SDK wraps transport failures. Export only these fixed codes, never a
// server error body, URL, query, response header, or Authorization value.
func safeMCPHTTPError(err error) error {
	for err != nil {
		switch err.Error() {
		case "mcp_authentication_required", "mcp_http_forbidden", "mcp_http_endpoint_unavailable", "mcp_http_redirect_refused", "mcp_http_timeout", "mcp_http_rate_limited", "mcp_http_connection_failed":
			return errors.New(err.Error())
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return errors.New("mcp_http_timeout")
		}
		err = errors.Unwrap(err)
	}
	return nil
}
