package bootstrap

import (
	"context"
	"regexp"
	"strings"

	"gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go/pkg/agent"
)

// Config controls how a raw model is bootstrapped into a tool user.
type Config struct {
	// Mode: "auto"|"native"|"prompted". "native" passes through to the inner
	// provider. (Constrained decoding is the TS-side M3 feature; the Go port
	// tracks it as a follow-up.)
	Mode string
	// Dialect: "auto"|"json"|"hermes". "auto" resolves via the model profile.
	Dialect string
	// MaxRetries is the number of repair round-trips (default 2).
	MaxRetries int
	// DisableFuzzyMatch turns off fuzzy tool-name correction (on by default).
	DisableFuzzyMatch bool
	// FuzzyThreshold is the similarity required to accept a fuzzy match (default 0.82).
	FuzzyThreshold float64
}

type modelProfile struct {
	match   *regexp.Regexp
	dialect string
}

var profiles = []modelProfile{
	{regexp.MustCompile(`(?i)qwen|hermes|nous`), "hermes"},
	{regexp.MustCompile(`(?i)llama[-_ ]?3|llama3`), "json"},
	{regexp.MustCompile(`(?i)mistral|mixtral`), "json"},
	{regexp.MustCompile(`(?i)command[-_ ]?r`), "json"},
	{regexp.MustCompile(`(?i)phi[-_ ]?\d`), "react"},
}

func profileDialect(model string) string {
	for _, p := range profiles {
		if p.match.MatchString(model) {
			return p.dialect
		}
	}
	return "json"
}

type nativeDialect struct{}

// NativeDialect is a no-op codec for providers with native tool-calling.
var NativeDialect DialectCodec = nativeDialect{}

func (nativeDialect) ID() string                                                { return "native" }
func (nativeDialect) RenderSystemPrompt(_ []agent.ToolSchema, sp string) string { return sp }
func (nativeDialect) RenderTranscript(m []agent.Message) []agent.Message        { return m }
func (nativeDialect) Parse(text string, _ []agent.ToolSchema) ParseResult {
	return ParseResult{Content: text}
}

var codecs = map[string]DialectCodec{
	"json":   JSONDialect,
	"hermes": HermesDialect,
	"react":  ReactDialect,
	"native": NativeDialect,
}

// ConstrainableProvider is implemented by inner providers that support guided/
// structured decoding (e.g. an Ollama adapter using `format`). The constrained
// strategy uses it to pass a tool-call envelope schema so output is guaranteed
// parseable.
type ConstrainableProvider interface {
	GenerateConstrained(ctx context.Context, messages []agent.Message, schema map[string]interface{}) (*agent.GenerateResult, error)
}

func codecFor(id string) DialectCodec {
	if c, ok := codecs[id]; ok {
		return c
	}
	return JSONDialect
}

// BootstrapProvider wraps a raw agent.Provider and presents the same interface,
// injecting tool schemas into the prompt and parsing tool calls from the text.
type BootstrapProvider struct {
	inner  agent.Provider
	model  string
	config Config
}

// Bootstrap wraps inner so a raw model can use tools. model selects the dialect.
func Bootstrap(inner agent.Provider, model string, config Config) *BootstrapProvider {
	if config.MaxRetries == 0 {
		config.MaxRetries = 2
	}
	if config.FuzzyThreshold == 0 {
		config.FuzzyThreshold = 0.82
	}
	if config.Mode == "" {
		config.Mode = "prompted"
	}
	return &BootstrapProvider{inner: inner, model: model, config: config}
}

func (b *BootstrapProvider) dialect() DialectCodec {
	if b.config.Dialect != "" && b.config.Dialect != "auto" {
		return codecFor(b.config.Dialect)
	}
	return codecFor(profileDialect(b.model))
}

func (b *BootstrapProvider) strategy() string {
	switch b.config.Mode {
	case "native":
		return "native"
	case "constrained":
		if _, ok := b.inner.(ConstrainableProvider); ok {
			return "constrained"
		}
		return "prompted"
	default:
		return "prompted"
	}
}

// Generate implements agent.Provider.
func (b *BootstrapProvider) Generate(ctx context.Context, messages []agent.Message, tools []agent.ToolSchema) (*agent.GenerateResult, error) {
	strat := b.strategy()
	if strat == "native" || len(tools) == 0 {
		return b.inner.Generate(ctx, messages, tools)
	}

	constrained := strat == "constrained"
	codec := b.dialect()
	system := extractSystem(messages)
	transcript := codec.RenderTranscript(messages)

	var sys string
	var envelope map[string]interface{}
	if constrained {
		envelope = BuildEnvelopeSchema(tools)
		sys = RenderEnvelopePrompt(tools, system)
	} else {
		sys = codec.RenderSystemPrompt(tools, system)
	}

	var repairHint *agent.Message
	lastContent := ""
	fuzzy := !b.config.DisableFuzzyMatch

	for attempt := 0; attempt <= b.config.MaxRetries; attempt++ {
		callMsgs := append([]agent.Message{{Role: "system", Content: sys}}, transcript...)
		if repairHint != nil {
			callMsgs = append(callMsgs, *repairHint)
		}

		var res *agent.GenerateResult
		var err error
		if constrained {
			res, err = b.inner.(ConstrainableProvider).GenerateConstrained(ctx, callMsgs, envelope)
		} else {
			res, err = b.inner.Generate(ctx, callMsgs, nil)
		}
		if err != nil {
			return nil, err
		}

		var parsed ParseResult
		if constrained {
			parsed = ParseEnvelope(res.Content)
		} else {
			parsed = codec.Parse(res.Content, tools)
		}
		lastContent = parsed.Content

		if len(parsed.ToolCalls) == 0 {
			if len(parsed.Malformed) > 0 && attempt < b.config.MaxRetries {
				repairHint = &agent.Message{Role: "user", Content: "Your previous tool_call block was not valid JSON. Reply with ONLY a single valid tool_call block, or plain text if you are done."}
				continue
			}
			return &agent.GenerateResult{Content: parsed.Content}, nil
		}

		outcome := validateCalls(parsed.ToolCalls, tools, fuzzy, b.config.FuzzyThreshold)
		if outcome.ok {
			return &agent.GenerateResult{Content: parsed.Content, ToolCalls: outcome.calls}, nil
		}
		hint := agent.Message{Role: "user", Content: buildRepairMessage(outcome, tools)}
		repairHint = &hint
	}

	return &agent.GenerateResult{Content: lastContent}, nil
}

func extractSystem(messages []agent.Message) string {
	var parts []string
	for _, m := range messages {
		if m.Role == "system" && m.Content != "" {
			parts = append(parts, m.Content)
		}
	}
	return strings.Join(parts, "\n\n")
}
