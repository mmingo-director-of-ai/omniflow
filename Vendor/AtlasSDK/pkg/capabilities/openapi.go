// OpenAPI -> tools. Each operation (path + method) becomes a callable tool with
// an input schema assembled from its parameters and JSON request body. Used by
// the OpenAI-plugin adapter and usable directly for any OpenAPI 3 spec.
package capabilities

import (
	"regexp"
	"strings"
)

var openapiMethods = []string{"get", "post", "put", "patch", "delete"}

var (
	reBraces    = regexp.MustCompile(`[{}]`)
	reNonAlnum  = regexp.MustCompile(`[^a-zA-Z0-9]+`)
	reTrimUnder = regexp.MustCompile(`^_+|_+$`)
)

// sanitizeName builds a deterministic tool name from an HTTP method and path
// when the operation has no operationId. Mirrors the TS sanitizeName: strip
// braces, collapse non-alphanumerics to underscores, trim leading/trailing
// underscores, prefix with the method, and cap at 64 chars.
func sanitizeName(method, path string) string {
	p := reBraces.ReplaceAllString(path, "")
	p = reNonAlnum.ReplaceAllString(p, "_")
	p = reTrimUnder.ReplaceAllString(p, "")
	return truncate(method+"_"+p, 64)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// OpenAPIToTools converts an OpenAPI 3 document into normalized tools. It
// iterates paths x methods (get/post/put/patch/delete), assembles an input
// schema from each operation's parameters and its application/json request
// body, and captures the invocation metadata (method, path, baseURL, security,
// plus the additive Params and BodyKeys).
func OpenAPIToTools(spec map[string]interface{}, source string) []CapabilityTool {
	if source == "" {
		source = "openapi"
	}

	tools := []CapabilityTool{}

	paths, _ := spec["paths"].(map[string]interface{})
	if paths == nil {
		paths = map[string]interface{}{}
	}

	baseURL := firstServerURL(spec)

	for path, itemRaw := range paths {
		item, ok := itemRaw.(map[string]interface{})
		if !ok {
			continue
		}
		for _, method := range openapiMethods {
			opRaw, ok := item[method]
			if !ok {
				continue
			}
			op, ok := opRaw.(map[string]interface{})
			if !ok {
				continue
			}

			properties := map[string]interface{}{}
			required := []string{}
			params := []ParamRef{}
			bodyKeys := []string{}

			// Path/query/header parameters.
			if paramList, ok := op["parameters"].([]interface{}); ok {
				for _, pRaw := range paramList {
					param, ok := pRaw.(map[string]interface{})
					if !ok {
						continue
					}
					name, ok := param["name"].(string)
					if !ok || name == "" {
						continue
					}
					if schema, ok := param["schema"]; ok {
						properties[name] = schema
					} else {
						desc, _ := param["description"].(string)
						properties[name] = map[string]interface{}{
							"type":        "string",
							"description": desc,
						}
					}
					in, _ := param["in"].(string)
					params = append(params, ParamRef{Name: name, In: in})
					if req, ok := param["required"].(bool); ok && req {
						required = append(required, name)
					}
				}
			}

			// JSON request body.
			if bodySchema := jsonBodySchema(op); bodySchema != nil {
				if props, ok := bodySchema["properties"].(map[string]interface{}); ok {
					for k, v := range props {
						properties[k] = v
						bodyKeys = append(bodyKeys, k)
					}
				}
				if reqs, ok := bodySchema["required"].([]interface{}); ok {
					for _, r := range reqs {
						if rs, ok := r.(string); ok {
							required = append(required, rs)
						}
					}
				}
			}

			name := sanitizeName(method, path)
			if opID, ok := op["operationId"].(string); ok && opID != "" {
				name = truncate(opID, 64)
			}

			inputSchema := map[string]interface{}{
				"type":       "object",
				"properties": properties,
			}
			if dedup := uniqueStrings(required); len(dedup) > 0 {
				inputSchema["required"] = dedup
			}

			description := name
			if s, ok := op["summary"].(string); ok && s != "" {
				description = s
			} else if d, ok := op["description"].(string); ok && d != "" {
				description = d
			}

			tools = append(tools, CapabilityTool{
				Name:        name,
				Description: description,
				InputSchema: inputSchema,
				Source:      source,
				Invocation: &ToolInvocation{
					Kind:     InvocationOpenAPI,
					Method:   strings.ToUpper(method),
					Path:     path,
					BaseURL:  baseURL,
					Security: operationSecurity(op),
					Params:   params,
					BodyKeys: bodyKeys,
				},
			})
		}
	}

	return tools
}

// firstServerURL returns spec.servers[0].url if present.
func firstServerURL(spec map[string]interface{}) string {
	servers, ok := spec["servers"].([]interface{})
	if !ok || len(servers) == 0 {
		return ""
	}
	server, ok := servers[0].(map[string]interface{})
	if !ok {
		return ""
	}
	url, _ := server["url"].(string)
	return url
}

// jsonBodySchema digs out op.requestBody.content["application/json"].schema.
func jsonBodySchema(op map[string]interface{}) map[string]interface{} {
	requestBody, ok := op["requestBody"].(map[string]interface{})
	if !ok {
		return nil
	}
	content, ok := requestBody["content"].(map[string]interface{})
	if !ok {
		return nil
	}
	appJSON, ok := content["application/json"].(map[string]interface{})
	if !ok {
		return nil
	}
	schema, _ := appJSON["schema"].(map[string]interface{})
	return schema
}

// operationSecurity flattens op.security ([{scheme: [...]}, ...]) into the list
// of scheme names, matching TS's security.flatMap(s => Object.keys(s)). Returns
// nil when no security is declared (TS leaves the field undefined).
func operationSecurity(op map[string]interface{}) []string {
	secList, ok := op["security"].([]interface{})
	if !ok {
		return nil
	}
	out := []string{}
	for _, sRaw := range secList {
		s, ok := sRaw.(map[string]interface{})
		if !ok {
			continue
		}
		for k := range s {
			out = append(out, k)
		}
	}
	return out
}

// uniqueStrings de-duplicates a string slice, preserving first-seen order
// (mirrors TS Array.from(new Set(required))).
func uniqueStrings(in []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}
