package main

import (
	"bytes"
	"encoding/json"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The SDK's argument map uses float64. Reject values whose numeric meaning
// would change on re-encoding, instead of calling a tool with a rounded ID.
// Result payloads stay raw JSON and are not subject to this representation limit.
func numbersRoundTrip(data []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var root interface{}
	if decoder.Decode(&root) != nil {
		return false
	}
	var check func(interface{}, int) bool
	check = func(value interface{}, depth int) bool {
		if depth > 32 {
			return false
		}
		switch value := value.(type) {
		case json.Number:
			if len(value) > 128 {
				return false
			}
			// ParseFloat can silently underflow to zero. Bound the exponent
			// before asking big.Rat to allocate an exact representation.
			if index := strings.IndexAny(string(value), "eE"); index >= 0 {
				exponent, err := strconv.Atoi(string(value)[index+1:])
				if err != nil || exponent < -512 || exponent > 512 {
					return false
				}
			}
			floating, err := value.Float64()
			if err != nil || math.IsInf(floating, 0) {
				return false
			}
			before, ok := new(big.Rat).SetString(string(value))
			if !ok {
				return false
			}
			after, ok := new(big.Rat).SetString(jsonText(floating))
			return ok && before.Cmp(after) == 0
		case []interface{}:
			for _, child := range value {
				if !check(child, depth+1) {
					return false
				}
			}
		case map[string]interface{}:
			for _, child := range value {
				if !check(child, depth+1) {
					return false
				}
			}
		}
		return true
	}
	return check(root, 0)
}

// Fail closed for unsupported JSON Schema validation keywords. This is a
// deliberately bounded subset, not a claim of full JSON Schema conformance.
func schemaSupported(schema, root map[string]interface{}, depth int) bool {
	if schema == nil || depth > 16 {
		return false
	}
	for key, value := range schema {
		switch key {
		case "$schema", "$id", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly":
		case "type":
			check := func(value interface{}) bool {
				s, ok := value.(string)
				return ok && (s == "object" || s == "array" || s == "string" || s == "number" || s == "integer" || s == "boolean" || s == "null")
			}
			if values, ok := value.([]interface{}); ok {
				for _, v := range values {
					if !check(v) {
						return false
					}
				}
			} else if !check(value) {
				return false
			}
		case "properties", "$defs", "definitions":
			values, ok := value.(map[string]interface{})
			if !ok {
				return false
			}
			for _, v := range values {
				child, ok := v.(map[string]interface{})
				if !ok || !schemaSupported(child, root, depth+1) {
					return false
				}
			}
		case "$ref":
			ref, ok := value.(string)
			if !ok || !schemaSupported(resolveSchema(ref, root), root, depth+1) {
				return false
			}
		case "items":
			child, ok := value.(map[string]interface{})
			if !ok || !schemaSupported(child, root, depth+1) {
				return false
			}
		case "additionalProperties":
			if _, ok := value.(bool); !ok {
				child, ok := value.(map[string]interface{})
				if !ok || !schemaSupported(child, root, depth+1) {
					return false
				}
			}
		case "anyOf", "oneOf", "allOf":
			children, ok := value.([]interface{})
			if !ok || len(children) == 0 || len(children) > 16 {
				return false
			}
			for _, v := range children {
				child, ok := v.(map[string]interface{})
				if !ok || !schemaSupported(child, root, depth+1) {
					return false
				}
			}
		case "required":
			values, ok := value.([]interface{})
			if !ok {
				return false
			}
			for _, v := range values {
				if _, ok := v.(string); !ok {
					return false
				}
			}
		case "enum":
			values, ok := value.([]interface{})
			if !ok || len(values) == 0 {
				return false
			}
		case "const":
		case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties":
			if _, ok := value.(float64); !ok {
				return false
			}
		case "pattern":
			pattern, ok := value.(string)
			if !ok || len(pattern) > 1024 {
				return false
			}
			if _, err := regexp.Compile(pattern); err != nil {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func resolveSchema(ref string, root map[string]interface{}) map[string]interface{} {
	if !strings.HasPrefix(ref, "#/") {
		return nil
	}
	var value interface{} = root
	for _, part := range strings.Split(strings.TrimPrefix(ref, "#/"), "/") {
		object, ok := value.(map[string]interface{})
		if !ok {
			return nil
		}
		part = strings.ReplaceAll(strings.ReplaceAll(part, "~1", "/"), "~0", "~")
		value = object[part]
	}
	result, _ := value.(map[string]interface{})
	return result
}

func validateSchema(value interface{}, schema, root map[string]interface{}, depth int) bool {
	if schema == nil || depth > 16 {
		return false
	}
	if ref, ok := schema["$ref"].(string); ok && !validateSchema(value, resolveSchema(ref, root), root, depth+1) {
		return false
	}
	if choices, ok := schema["enum"].([]interface{}); ok {
		matched := false
		for _, choice := range choices {
			if jsonText(value) == jsonText(choice) {
				matched = true
				break
			}
		}
		if !matched {
			return false
		}
	}
	if constant, ok := schema["const"]; ok && jsonText(value) != jsonText(constant) {
		return false
	}
	for _, key := range []string{"anyOf", "oneOf", "allOf"} {
		if children, ok := schema[key].([]interface{}); ok {
			matched := 0
			for _, child := range children {
				if validateSchema(value, child.(map[string]interface{}), root, depth+1) {
					matched++
				}
			}
			if (key == "anyOf" && matched == 0) || (key == "oneOf" && matched != 1) || (key == "allOf" && matched != len(children)) {
				return false
			}
		}
	}
	if expected, ok := schema["type"]; ok {
		types := []interface{}{expected}
		if many, ok := expected.([]interface{}); ok {
			types = many
		}
		match := false
		for _, kind := range types {
			switch kind {
			case "null":
				match = match || value == nil
			case "string":
				_, ok := value.(string)
				match = match || ok
			case "boolean":
				_, ok := value.(bool)
				match = match || ok
			case "object":
				_, ok := value.(map[string]interface{})
				match = match || ok
			case "array":
				_, ok := value.([]interface{})
				match = match || ok
			case "number":
				_, ok := value.(float64)
				match = match || ok
			case "integer":
				n, ok := value.(float64)
				match = match || (ok && math.Trunc(n) == n)
			}
		}
		if !match {
			return false
		}
	}
	within := func(n float64, minKey, maxKey string) bool {
		if min, ok := schema[minKey].(float64); ok && n < min {
			return false
		}
		if max, ok := schema[maxKey].(float64); ok && n > max {
			return false
		}
		return true
	}
	switch value := value.(type) {
	case map[string]interface{}:
		if len(value) > 128 || !within(float64(len(value)), "minProperties", "maxProperties") {
			return false
		}
		if required, ok := schema["required"].([]interface{}); ok {
			for _, name := range required {
				if _, ok := value[name.(string)]; !ok {
					return false
				}
			}
		}
		properties, _ := schema["properties"].(map[string]interface{})
		for key, child := range value {
			if property, ok := properties[key].(map[string]interface{}); ok {
				if !validateSchema(child, property, root, depth+1) {
					return false
				}
			} else {
				switch additional := schema["additionalProperties"].(type) {
				case bool:
					if !additional {
						return false
					}
				case map[string]interface{}:
					if !validateSchema(child, additional, root, depth+1) {
						return false
					}
				default:
					// With explicit properties, refuse undocumented parameters unless
					// the server explicitly permits them. Composition-only schemas
					// delegate to their validated branches above.
					if properties != nil {
						return false
					}
				}
			}
		}
	case []interface{}:
		if len(value) > 1024 || !within(float64(len(value)), "minItems", "maxItems") {
			return false
		}
		if items, ok := schema["items"].(map[string]interface{}); ok {
			for _, child := range value {
				if !validateSchema(child, items, root, depth+1) {
					return false
				}
			}
		}
	case string:
		if len(value) > 16000 || !within(float64(utf8.RuneCountInString(value)), "minLength", "maxLength") {
			return false
		}
		if pattern, ok := schema["pattern"].(string); ok {
			matched, _ := regexp.MatchString(pattern, value)
			if !matched {
				return false
			}
		}
	case float64:
		if !within(value, "minimum", "maximum") {
			return false
		}
		if lower, ok := schema["exclusiveMinimum"].(float64); ok && value <= lower {
			return false
		}
		if upper, ok := schema["exclusiveMaximum"].(float64); ok && value >= upper {
			return false
		}
	}
	return true
}
