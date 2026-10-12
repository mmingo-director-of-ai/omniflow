package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/mcp"
)

type mcpApproval struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
}
type mcpServerConfig struct {
	ID                 string            `json:"id"`
	Name               string            `json:"name"`
	Transport          string            `json:"transport,omitempty"`
	URL                string            `json:"url,omitempty"`
	Headers            map[string]string `json:"headers,omitempty"`
	AuthorizationError string            `json:"authorizationError,omitempty"`
	Command            string            `json:"command"`
	Arguments          []string          `json:"arguments"`
	Enabled            bool              `json:"enabled"`
	AllowedTools       []mcpApproval     `json:"allowedTools"`
	AllowResources     bool              `json:"allowResources"`
}
type mcpCatalogTool struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Digest      string `json:"digest"`
	Supported   bool   `json:"supported"`
	schema      map[string]interface{}
	raw         json.RawMessage
}
type mcpConnection struct {
	config       mcpServerConfig
	transport    *localMCPTransport
	bridge       *mcp.Bridge
	tools        map[string]mcpCatalogTool
	resources    map[string]bool
	hasResources bool
}
type mcpHost struct {
	selected    *mcpSelectedTool
	broker      *mcpBrokerEndpoint
	configs     []mcpServerConfig
	connections map[string]*mcpConnection
	store       *payloadStore
}

// Only the selected, approved schema crosses into model context, never the
// entire catalog. The Swift tool adapter supplies server/name itself when called.
type mcpSelectedTool struct {
	Server          string `json:"server"`
	Name            string `json:"name"`
	Description     string `json:"description"`
	InputSchemaJSON string `json:"inputSchemaJSON"`
}

func (h *mcpHost) selectedTool() *mcpSelectedTool {
	if h.selected == nil {
		return nil
	}
	c := h.connections[h.selected.Server]
	if c == nil || !c.allowed(c.tools[h.selected.Name]) {
		return nil
	}
	return h.selected
}

func newMCPHost(configs []mcpServerConfig, store *payloadStore) (*mcpHost, error) {
	if len(configs) > 8 {
		return nil, errors.New("mcp_server_limit")
	}
	ids := map[string]bool{}
	for _, config := range configs {
		if len(config.ID) < 1 || len(config.ID) > 64 || ids[config.ID] || len(config.Name) > 80 || len(config.Arguments) > 32 || len(config.AllowedTools) > 256 {
			return nil, errors.New("invalid_mcp_configuration")
		}
		ids[config.ID] = true
		if config.AuthorizationError != "" && config.AuthorizationError != "mcp_authentication_required" {
			return nil, errors.New("invalid_mcp_configuration")
		}
		switch config.Transport {
		case "", "stdio":
			if !filepath.IsAbs(config.Command) || config.URL != "" || len(config.Headers) != 0 {
				return nil, errors.New("invalid_local_mcp_configuration")
			}
		case "http":
			if config.Command != "" || len(config.Arguments) != 0 {
				return nil, errors.New("invalid_remote_mcp_configuration")
			}
			if _, _, err := validateMCPHTTP(config); err != nil {
				return nil, err
			}
		default:
			return nil, errors.New("unsupported_mcp_transport")
		}
		for _, arg := range config.Arguments {
			if len(arg) > 4096 || strings.ContainsRune(arg, 0) {
				return nil, errors.New("invalid_mcp_argument")
			}
		}
		for _, approval := range config.AllowedTools {
			if len(approval.Name) > 128 || len(approval.Digest) != 64 {
				return nil, errors.New("invalid_mcp_approval")
			}
		}
	}
	return &mcpHost{configs: configs, connections: make(map[string]*mcpConnection), store: store}, nil
}

func (h *mcpHost) close() {
	for _, connection := range h.connections {
		_ = connection.transport.Close()
	}
}

func (h *mcpHost) connect(ctx context.Context, id string) (connected *mcpConnection, failure error) {
	defer func() {
		if failure != nil {
			if c := h.connections[id]; c != nil {
				_ = c.transport.Close()
				delete(h.connections, id)
			}
		}
	}()
	if connection := h.connections[id]; connection != nil {
		if connection.transport.http == nil || !connection.transport.http.expired {
			return connection, nil
		}
		// A session-expiry error ends that operation. A later explicit operation
		// gets a fresh handshake/catalog; never automatically replay a tool call.
		_ = connection.transport.Close()
		delete(h.connections, id)
	}
	var config *mcpServerConfig
	for index := range h.configs {
		if h.configs[index].ID == id && h.configs[index].Enabled {
			config = &h.configs[index]
			break
		}
	}
	if config == nil {
		return nil, errors.New("mcp_server_not_enabled")
	}
	if config.AuthorizationError != "" {
		return nil, errors.New(config.AuthorizationError)
	}
	requestContext, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	transport := &localMCPTransport{broker: h.broker, config: *config, workdir: filepath.Join(h.store.directory, "server-"+jsonText(len(h.connections))), ctx: requestContext}
	bridge := mcp.NewBridge()
	initialized, err := bridge.Initialize(requestContext, transport, mcp.Implementation{Name: "NotchLee", Version: sdkVersion}, mcp.ClientCapabilities{})
	if err != nil {
		_ = transport.Close()
		if config.Transport == "http" {
			if safe := safeMCPHTTPError(err); safe != nil {
				return nil, safe
			}
			return nil, errors.New("mcp_initialize_failed_check_endpoint_and_credentials")
		}
		return nil, errors.New("mcp_initialize_failed_check_local_command")
	}
	if !supportedMCPProtocol(initialized.ProtocolVersion) {
		_ = transport.Close()
		return nil, errors.New("unsupported_mcp_protocol")
	}
	connection := &mcpConnection{config: *config, transport: transport, bridge: bridge, tools: map[string]mcpCatalogTool{}, resources: map[string]bool{}, hasResources: initialized.Capabilities.Resources != nil}
	h.connections[id] = connection
	if initialized.Capabilities.Tools == nil {
		return connection, nil
	}
	cursor := ""
	seen := map[string]bool{}
	for page := 0; page < 32; page++ {
		params := map[string]string{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := transport.rpc(requestContext, "tools/list", params)
		if err != nil {
			return nil, err
		}
		var result struct {
			Tools      []json.RawMessage `json:"tools"`
			NextCursor string            `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &result) != nil {
			return nil, errors.New("invalid_mcp_catalog")
		}
		for _, encoded := range result.Tools {
			var tool struct {
				Name        string                 `json:"name"`
				Description string                 `json:"description"`
				InputSchema map[string]interface{} `json:"inputSchema"`
			}
			if len(encoded) > 32768 || json.Unmarshal(encoded, &tool) != nil || len(tool.Name) < 1 || len(tool.Name) > 128 || len(tool.Description) > 8192 || connection.tools[tool.Name].Name != "" {
				return nil, errors.New("mcp_tool_definition_limit_or_duplicate")
			}
			// Pin the entire advertised tool definition, including descriptions and
			// annotations, so a changed catalog requires new user approval.
			var canonical interface{}
			_ = json.Unmarshal(encoded, &canonical)
			digest := sha256.Sum256([]byte(jsonText(canonical)))
			connection.tools[tool.Name] = mcpCatalogTool{Name: tool.Name, Description: tool.Description, Digest: hex.EncodeToString(digest[:]), Supported: numbersRoundTrip(encoded) && schemaSupported(tool.InputSchema, tool.InputSchema, 0), schema: tool.InputSchema, raw: encoded}
			if len(connection.tools) > 256 {
				return nil, errors.New("mcp_catalog_limit_256_tools")
			}
		}
		cursor = result.NextCursor
		if cursor == "" {
			return connection, nil
		}
		if seen[cursor] || len(cursor) > 4096 {
			return nil, errors.New("mcp_invalid_pagination")
		}
		seen[cursor] = true
	}
	return nil, errors.New("mcp_catalog_page_limit")
}

func (c *mcpConnection) allowed(tool mcpCatalogTool) bool {
	if c.transport.catalogChanged {
		return false
	}
	for _, approval := range c.config.AllowedTools {
		if approval.Name == tool.Name && approval.Digest == tool.Digest && tool.Supported {
			return true
		}
	}
	return false
}

func (h *mcpHost) catalog(ctx context.Context, id string) (string, error) {
	c, err := h.connect(ctx, id)
	if err != nil {
		return "", err
	}
	list := []mcpCatalogTool{}
	for _, tool := range c.tools {
		tool.Description = utf8Prefix(tool.Description, 320)
		list = append(list, tool)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	return jsonText(map[string]interface{}{"tools": list, "hasResources": c.hasResources}), nil
}

func (h *mcpHost) execute(ctx context.Context, args map[string]interface{}) (interface{}, error) {
	op, _ := args["operation"].(string)
	if op == "servers" {
		list := []map[string]interface{}{}
		for _, config := range h.configs {
			if config.Enabled {
				list = append(list, map[string]interface{}{"id": config.ID, "name": config.Name, "approvedTools": len(config.AllowedTools), "resourcesAllowed": config.AllowResources})
			}
		}
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "servers": list}), nil
	}
	id, _ := args["server"].(string)
	c, err := h.connect(ctx, id)
	if err != nil {
		return nil, err
	}
	name, _ := args["name"].(string)
	switch op {
	case "tools":
		query, _ := args["query"].(string)
		if len(query) > 128 {
			return nil, errors.New("mcp_query_limit")
		}
		list := []map[string]interface{}{}
		toolCount := 0
		names := []string{}
		for name := range c.tools {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			tool := c.tools[name]
			if !c.allowed(tool) {
				continue
			}
			toolCount++
			match, _ := filepath.Match(query, name)
			if query == "" || match || strings.Contains(strings.ToLower(name+" "+tool.Description), strings.ToLower(query)) {
				list = append(list, map[string]interface{}{"name": name, "description": utf8Prefix(tool.Description, 200)})
			}
		}
		offset, err := integerArgument(args, "offset", 0, len(list))
		if err != nil {
			return nil, err
		}
		end := min(offset+8, len(list))
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "server": id, "tools": list[offset:end], "nextOffset": end, "total": len(list), "hasMore": end < len(list), "toolCount": toolCount, "filter": query, "searchScope": "tool_catalog"}), nil
	case "schema", "call":
		tool, ok := c.tools[name]
		if !ok {
			return nil, errors.New("mcp_unknown_tool_name_use_tools_to_discover")
		}
		if !c.allowed(tool) {
			return nil, errors.New("mcp_tool_not_approved_or_definition_changed")
		}
		h.selected = &mcpSelectedTool{Server: id, Name: name, Description: utf8Prefix(tool.Description, 320), InputSchemaJSON: jsonText(tool.schema)}
		if op == "schema" {
			entry, err := h.store.put("mcp:"+id+":"+name+":schema", []byte(jsonText(tool.schema)), true)
			if err != nil {
				return nil, err
			}
			entry.Kind = "schema"
			// The schema already defines the model's selected native function.
			// Keep it available for explicit inspection without presenting its
			// properties a second time as if they were fetched source evidence.
			return jsonText(map[string]interface{}{
				"trust": "untrusted_data", "status": "ready_to_call", "server": id,
				"name": name, "executed": false, "parameterDefinitionID": entry.ID,
			}), nil
		}
		encoded, _ := args["argumentsJSON"].(string)
		var arguments map[string]interface{}
		if len(encoded) > 16000 || !numbersRoundTrip([]byte(encoded)) || json.Unmarshal([]byte(encoded), &arguments) != nil || arguments == nil || !validateSchema(arguments, tool.schema, tool.schema, 0) {
			return nil, errors.New("mcp_arguments_do_not_match_approved_schema")
		}
		requestContext, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		c.transport.ctx = requestContext
		_, err := c.bridge.CallTool(requestContext, name, arguments)
		if err != nil {
			if c.config.Transport == "http" {
				if safe := safeMCPHTTPError(err); safe != nil {
					return nil, safe
				}
			}
			return nil, errors.New("mcp_tool_failed_or_unsupported_result")
		}
		return h.ingest(c, "mcp:"+id+":"+name, c.transport.lastResult, false)
	case "resources":
		if !c.config.AllowResources || !c.hasResources {
			return nil, errors.New("mcp_resources_not_enabled")
		}
		cursor, _ := args["cursor"].(string)
		if len(cursor) > 4096 {
			return nil, errors.New("mcp_cursor_limit")
		}
		params := map[string]string{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.transport.rpc(ctx, "resources/list", params)
		if err != nil {
			return nil, err
		}
		var result struct {
			Resources  []mcp.Resource `json:"resources"`
			NextCursor string         `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &result) != nil || len(result.Resources) > 256 || len(result.NextCursor) > 4096 {
			return nil, errors.New("mcp_resource_page_limit")
		}
		for _, resource := range result.Resources {
			if err := c.rememberResource(resource.URI); err != nil {
				return nil, err
			}
		}
		entry, err := h.store.put("mcp:"+id+":resources", raw, true)
		if err != nil {
			return nil, err
		}
		return jsonText(map[string]interface{}{"trust": "untrusted_data", "nextCursor": result.NextCursor, "page": json.RawMessage(h.store.preview(entry))}), nil
	case "readResource":
		if !c.config.AllowResources || !c.resources[name] {
			return nil, errors.New("mcp_resource_not_approved_or_not_discovered")
		}
		requestContext, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		c.transport.ctx = requestContext
		_, err := c.bridge.ReadResource(requestContext, name)
		if err != nil {
			if c.config.Transport == "http" {
				if safe := safeMCPHTTPError(err); safe != nil {
					return nil, safe
				}
			}
			return nil, errors.New("mcp_resource_read_failed")
		}
		return h.ingest(c, "mcp:"+id+":resource:"+utf8Prefix(name, 256), c.transport.lastResult, true)
	default:
		return nil, errors.New("unknown_mcp_operation")
	}
}

func (c *mcpConnection) rememberResource(uri string) error {
	if len(uri) == 0 || len(uri) > 2048 || len(c.resources) >= 1024 {
		return errors.New("mcp_resource_limit")
	}
	c.resources[uri] = true
	return nil
}

func (h *mcpHost) ingest(c *mcpConnection, source string, raw json.RawMessage, isResource bool) (interface{}, error) {
	// Preserve the exact response, including structured content, before projecting
	// text. Raw binary/base64 is never injected into a language-model prompt.
	original, err := h.store.put(source+":raw", raw, false)
	if err != nil {
		return nil, err
	}
	var result struct {
		Content           []json.RawMessage `json:"content"`
		Contents          []json.RawMessage `json:"contents"`
		StructuredContent json.RawMessage   `json:"structuredContent"`
		IsError           bool              `json:"isError"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return nil, errors.New("invalid_mcp_result")
	}
	blocks := result.Content
	if isResource {
		blocks = result.Contents
	}
	if len(blocks) > 64 {
		return nil, errors.New("mcp_content_block_limit")
	}
	var text strings.Builder
	attachments := []*payloadEntry{}
	for _, rawBlock := range blocks {
		var block struct {
			Type     string          `json:"type"`
			Text     string          `json:"text"`
			Blob     string          `json:"blob"`
			Data     string          `json:"data"`
			MimeType string          `json:"mimeType"`
			URI      string          `json:"uri"`
			Name     string          `json:"name"`
			Resource json.RawMessage `json:"resource"`
		}
		if json.Unmarshal(rawBlock, &block) != nil {
			return nil, errors.New("invalid_mcp_content_block")
		}
		if block.Type == "resource" && len(block.Resource) > 0 {
			if json.Unmarshal(block.Resource, &block) != nil {
				return nil, errors.New("invalid_embedded_resource")
			}
		}
		if block.Type == "resource_link" {
			if err := c.rememberResource(block.URI); err != nil {
				return nil, err
			}
			text.WriteString("Resource reference: " + jsonText(map[string]string{"uri": block.URI, "name": utf8Prefix(block.Name, 200)}) + "\n")
		}
		if block.Text != "" {
			text.WriteString(block.Text)
			text.WriteString("\n")
		}
		blob := block.Blob
		if blob == "" {
			blob = block.Data
		}
		if blob != "" {
			decoded, isText, err := decodeResourceBlob(blob, block.MimeType)
			if err != nil {
				return nil, err
			}
			entry, err := h.store.put(source+":attachment", decoded, isText)
			if err != nil {
				return nil, err
			}
			attachments = append(attachments, entry)
			if len(attachments) > 8 {
				return nil, errors.New("mcp_attachment_limit")
			}
		}
		if text.Len() > maxPayloadBytes {
			return nil, errors.New("expanded_payload_limit")
		}
	}
	if len(result.StructuredContent) > 0 && string(result.StructuredContent) != "null" {
		var formatted bytes.Buffer
		if json.Indent(&formatted, result.StructuredContent, "", "  ") != nil {
			return nil, errors.New("invalid_structured_content")
		}
		text.WriteString("\nStructured content:\n")
		text.Write(formatted.Bytes())
	}
	entry, err := h.store.put(source, []byte(text.String()), true)
	if err != nil {
		return nil, err
	}
	return jsonText(map[string]interface{}{"trust": "untrusted_data", "isError": result.IsError, "raw": original.ID, "evidence": json.RawMessage(h.store.preview(entry)), "attachments": attachments}), nil
}

func utf8Prefix(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	for limit > 0 && value[limit]&0xc0 == 0x80 {
		limit--
	}
	return value[:limit]
}
