// Package canonicaljson encodes JSON with recursively sorted object keys.
//
// Atlas uses this representation for integrity hashes that must agree with the
// TypeScript SDK regardless of Go struct field order or map iteration order.
package canonicaljson

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
)

// Marshal returns a deterministic JSON encoding of value.
func Marshal(value interface{}) ([]byte, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var decoded interface{}
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}

	var output bytes.Buffer
	if err := encode(&output, decoded); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func encode(output *bytes.Buffer, value interface{}) error {
	switch typed := value.(type) {
	case nil:
		output.WriteString("null")
	case bool:
		if typed {
			output.WriteString("true")
		} else {
			output.WriteString("false")
		}
	case json.Number:
		output.WriteString(typed.String())
	case string:
		encoded, err := encodeString(typed)
		if err != nil {
			return err
		}
		output.Write(encoded)
	case []interface{}:
		output.WriteByte('[')
		for index, item := range typed {
			if index > 0 {
				output.WriteByte(',')
			}
			if err := encode(output, item); err != nil {
				return err
			}
		}
		output.WriteByte(']')
	case map[string]interface{}:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		output.WriteByte('{')
		for index, key := range keys {
			if index > 0 {
				output.WriteByte(',')
			}
			encodedKey, err := encodeString(key)
			if err != nil {
				return err
			}
			output.Write(encodedKey)
			output.WriteByte(':')
			if err := encode(output, typed[key]); err != nil {
				return err
			}
		}
		output.WriteByte('}')
	default:
		return fmt.Errorf("unsupported canonical JSON value %T", value)
	}
	return nil
}

func encodeString(value string) ([]byte, error) {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), nil
}
