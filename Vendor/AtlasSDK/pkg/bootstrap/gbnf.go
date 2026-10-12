package bootstrap

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// GBNFUnsupportedError is returned for schema shapes the converter doesn't handle.
type GBNFUnsupportedError struct{ Msg string }

func (e *GBNFUnsupportedError) Error() string { return e.Msg }

// JSONSchemaToGBNF converts a JSON Schema (subset) to a GBNF grammar string for
// llama.cpp constrained decoding. Mirrors the TS converter. Object keys are
// sorted for determinism (the TS version preserves insertion order; both are
// functionally equivalent grammars).
func JSONSchemaToGBNF(schema map[string]interface{}) (string, error) {
	g := &gbnfBuilder{ensured: map[string]bool{}}
	top, err := g.emit(schema)
	if err != nil {
		return "", err
	}
	root := "root ::= " + g.ws() + " " + top + " " + g.ws()
	return strings.Join(append([]string{root}, g.rules...), "\n"), nil
}

type gbnfBuilder struct {
	rules   []string
	ensured map[string]bool
	counter int
}

func (g *gbnfBuilder) ensure(name, body string) string {
	if !g.ensured[name] {
		g.ensured[name] = true
		g.rules = append(g.rules, name+" ::= "+body)
	}
	return name
}

func (g *gbnfBuilder) ws() string      { return g.ensure("ws", `[ \t\n\r]*`) }
func (g *gbnfBuilder) stringR() string { return g.ensure("string", `"\"" ( [^"\\] | "\\" . )* "\""`) }
func (g *gbnfBuilder) numberR() string {
	return g.ensure("number", `"-"? ( [0-9] | [1-9] [0-9]* ) ( "." [0-9]+ )? ( [eE] [-+]? [0-9]+ )?`)
}
func (g *gbnfBuilder) boolR() string { return g.ensure("boolean", `"true" | "false"`) }
func (g *gbnfBuilder) nullR() string { return g.ensure("null", `"null"`) }

func (g *gbnfBuilder) emit(s map[string]interface{}) (string, error) {
	if s == nil {
		return "", &GBNFUnsupportedError{"nil schema node"}
	}
	if c, ok := s["const"]; ok {
		return constExpr(c), nil
	}
	if e, ok := s["enum"].([]interface{}); ok {
		parts := make([]string, len(e))
		for i, v := range e {
			parts[i] = constExpr(v)
		}
		return "( " + strings.Join(parts, " | ") + " )", nil
	}
	if oo, ok := s["oneOf"].([]interface{}); ok {
		return g.union(oo)
	}
	if ao, ok := s["anyOf"].([]interface{}); ok {
		return g.union(ao)
	}
	typ, _ := s["type"].(string)
	switch typ {
	case "string":
		return g.stringR(), nil
	case "number", "integer":
		return g.numberR(), nil
	case "boolean":
		return g.boolR(), nil
	case "null":
		return g.nullR(), nil
	case "array":
		return g.emitArray(s)
	case "object":
		return g.emitObject(s)
	default:
		return "", &GBNFUnsupportedError{fmt.Sprintf("unsupported schema type: %q", typ)}
	}
}

func (g *gbnfBuilder) union(branches []interface{}) (string, error) {
	parts := make([]string, 0, len(branches))
	for _, b := range branches {
		m, ok := b.(map[string]interface{})
		if !ok {
			return "", &GBNFUnsupportedError{"non-object branch in oneOf/anyOf"}
		}
		e, err := g.emit(m)
		if err != nil {
			return "", err
		}
		parts = append(parts, e)
	}
	return "( " + strings.Join(parts, " | ") + " )", nil
}

func (g *gbnfBuilder) emitArray(s map[string]interface{}) (string, error) {
	var item string
	if it, ok := s["items"].(map[string]interface{}); ok {
		var err error
		if item, err = g.emit(it); err != nil {
			return "", err
		}
	} else {
		item = g.stringR()
	}
	w := g.ws()
	name := fmt.Sprintf("array-%d", g.counter)
	g.counter++
	return g.ensure(name, `"[" `+w+` ( `+item+` ( `+w+` "," `+w+` `+item+` )* )? `+w+` "]"`), nil
}

func (g *gbnfBuilder) emitObject(s map[string]interface{}) (string, error) {
	props, _ := s["properties"].(map[string]interface{})
	w := g.ws()
	name := fmt.Sprintf("object-%d", g.counter)
	g.counter++
	if len(props) == 0 {
		return g.ensure(name, `"{" `+w+` "}"`), nil
	}
	required := map[string]bool{}
	if rr, ok := s["required"].([]interface{}); ok {
		for _, r := range rr {
			if k, ok := r.(string); ok {
				required[k] = true
			}
		}
	}
	keys := make([]string, 0, len(props))
	for k := range props {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	member := func(k string) (string, error) {
		pm, ok := props[k].(map[string]interface{})
		if !ok {
			return "", &GBNFUnsupportedError{"non-object property schema"}
		}
		v, err := g.emit(pm)
		if err != nil {
			return "", err
		}
		return gbnfLiteral(jsonString(k)) + " " + w + ` ":" ` + w + ` ` + v, nil
	}

	var reqKeys, optKeys []string
	for _, k := range keys {
		if required[k] {
			reqKeys = append(reqKeys, k)
		} else {
			optKeys = append(optKeys, k)
		}
	}

	if len(reqKeys) > 0 {
		parts := make([]string, 0, len(reqKeys))
		for _, k := range reqKeys {
			mm, err := member(k)
			if err != nil {
				return "", err
			}
			parts = append(parts, mm)
		}
		reqSeq := strings.Join(parts, ` "," `+w+` `)
		optSeq := ""
		for _, k := range optKeys {
			mm, err := member(k)
			if err != nil {
				return "", err
			}
			optSeq += ` ( "," ` + w + ` ` + mm + ` )?`
		}
		return g.ensure(name, `"{" `+w+` `+reqSeq+optSeq+` `+w+` "}"`), nil
	}

	parts := make([]string, 0, len(optKeys))
	for _, k := range optKeys {
		mm, err := member(k)
		if err != nil {
			return "", err
		}
		parts = append(parts, mm)
	}
	union := "( " + strings.Join(parts, " | ") + " )"
	return g.ensure(name, `"{" `+w+` ( `+union+` ( `+w+` "," `+w+` `+union+` )* )? `+w+` "}"`), nil
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func gbnfLiteral(text string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(text, `\`, `\\`), `"`, `\"`) + `"`
}

func constExpr(v interface{}) string {
	b, _ := json.Marshal(v)
	return gbnfLiteral(string(b))
}
