package providers

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPlatformFoundationCrossLanguageFixture(t *testing.T) {
	data, err := os.ReadFile("../../../../fixtures/platform-foundations.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Routing struct {
			Catalog  []ModelCandidate `json:"catalog"`
			Request  RoutingRequest   `json:"request"`
			Expected string           `json:"expectedCandidateId"`
		} `json:"routing"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	router, err := NewModelRouter(fixture.Routing.Catalog, ModelRouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	decision, err := router.Select(context.Background(), fixture.Routing.Request)
	if err != nil {
		t.Fatal(err)
	}
	if decision.Selected.ID != fixture.Routing.Expected {
		t.Fatalf("expected %s, got %s", fixture.Routing.Expected, decision.Selected.ID)
	}
}

func routerCatalog() []ModelCandidate {
	return []ModelCandidate{
		{ID: "local", Provider: "ollama", Model: "small", Capabilities: []string{"text"}, ContextWindow: 8000, Privacy: "local", Residency: "local", Priority: 20},
		{ID: "fast", Provider: "one", Model: "fast", Capabilities: []string{"text", "tools"}, ContextWindow: 32000, CostPer1KInput: .001, CostPer1KOutput: .002, LatencyMS: 100, Privacy: "managed", Residency: "us", Priority: 10},
		{ID: "large", Provider: "two", Model: "large", Capabilities: []string{"text", "tools", "vision"}, ContextWindow: 200000, CostPer1KInput: .01, CostPer1KOutput: .02, LatencyMS: 500, Privacy: "private", Residency: "eu", Priority: 30},
	}
}

func TestModelRouterPolicyFallbackAndCircuit(t *testing.T) {
	ctx := context.Background()
	maxCost := .1
	router, err := NewModelRouter(routerCatalog(), ModelRouterOptions{RetriesPerCandidate: 1})
	if err != nil {
		t.Fatal(err)
	}
	decision, err := router.Select(ctx, RoutingRequest{RequiredCapabilities: []string{"tools"}, InputTokens: 10000, ExpectedOutputTokens: 1000, MaxEstimatedCost: &maxCost, MaxLatencyMS: 200, AllowedResidencies: []string{"us"}})
	if err != nil || decision.Selected.ID != "fast" {
		t.Fatalf("unexpected decision: %#v %v", decision, err)
	}
	value, candidate, _, attempts, err := router.Execute(ctx, RoutingRequest{InputTokens: 100, PreferredProvider: "one"}, func(_ context.Context, candidate ModelCandidate, _ int) (interface{}, error) {
		if candidate.ID == "fast" {
			return nil, errors.New("rate limited")
		}
		return candidate.ID, nil
	})
	if err != nil || candidate.ID == "fast" || value == nil || len(attempts) < 3 {
		t.Fatalf("fallback failed: %v %#v %#v", err, candidate, attempts)
	}

	now := time.Unix(0, 0)
	circuitRouter, _ := NewModelRouter(routerCatalog(), ModelRouterOptions{FailureThreshold: 1, CircuitReset: time.Second, Clock: func() time.Time { return now }})
	circuitRouter.RecordFailure("fast")
	open, _ := circuitRouter.Select(ctx, RoutingRequest{InputTokens: 100, PreferredProvider: "one"})
	if open.Selected.ID == "fast" {
		t.Fatal("open circuit selected")
	}
	now = now.Add(2 * time.Second)
	closed, _ := circuitRouter.Select(ctx, RoutingRequest{InputTokens: 100, PreferredProvider: "one"})
	if closed.Selected.ID != "fast" {
		t.Fatal("circuit did not reset")
	}
}

func TestModelRouterOverrideCannotUnderreportDemand(t *testing.T) {
	router, err := NewModelRouter(routerCatalog(), ModelRouterOptions{
		Override: func(_ context.Context, _ RoutingRequest, _ []ModelCandidate) (string, *RoutingRequest, error) {
			return "", &RoutingRequest{InputTokens: 0, ExpectedOutputTokens: 0}, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	decision, err := router.Select(context.Background(), RoutingRequest{
		InputTokens:          31500,
		ExpectedOutputTokens: 1000,
		RequiredCapabilities: []string{"tools"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if decision.Selected.ID != "large" {
		t.Fatalf("override changed measured demand: selected %s", decision.Selected.ID)
	}
}

func TestModelRouterRejectsInvalidInputsAndUnknownOverride(t *testing.T) {
	if _, err := NewModelRouter([]ModelCandidate{{ID: "bad", Model: "m", ContextWindow: 1}}, ModelRouterOptions{}); err == nil {
		t.Fatal("expected missing provider validation error")
	}
	if _, err := NewModelRouter(routerCatalog(), ModelRouterOptions{RetriesPerCandidate: -1}); err == nil {
		t.Fatal("expected invalid retry validation error")
	}
	router, err := NewModelRouter(routerCatalog(), ModelRouterOptions{
		Override: func(_ context.Context, _ RoutingRequest, _ []ModelCandidate) (string, *RoutingRequest, error) {
			return "missing", nil, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := router.Select(context.Background(), RoutingRequest{InputTokens: 1}); err == nil || !strings.Contains(err.Error(), "unknown model candidate") {
		t.Fatalf("expected unknown override error, got %v", err)
	}
}

func TestModelRouterExpiredCircuitStartsFreshFailureCount(t *testing.T) {
	now := time.Unix(100, 0)
	router, err := NewModelRouter(routerCatalog(), ModelRouterOptions{
		FailureThreshold: 2,
		CircuitReset:     10 * time.Second,
		Clock:            func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	router.RecordFailure("fast")
	router.RecordFailure("fast")
	now = now.Add(11 * time.Second)
	router.RecordFailure("fast")

	state, ok := router.GetCircuitState("fast")
	if !ok {
		t.Fatal("expected circuit state")
	}
	if state.Failures != 1 || !state.OpenUntil.IsZero() {
		t.Fatalf("expected fresh failure state, got %#v", state)
	}
}

func TestModelRouterOwnsCatalogCopies(t *testing.T) {
	catalog := routerCatalog()
	router, err := NewModelRouter(catalog, ModelRouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	catalog[1].Capabilities[0] = "mutated"
	catalog[1].Provider = "mutated"
	decision, err := router.Select(context.Background(), RoutingRequest{
		InputTokens: 100, RequiredCapabilities: []string{"text"}, PreferredProvider: "one",
	})
	if err != nil {
		t.Fatal(err)
	}
	if decision.Selected.ID != "fast" || decision.Selected.Provider != "one" {
		t.Fatalf("router catalog was mutated: %#v", decision.Selected)
	}
}

func TestModelRouterRanksUnknownLatencyAfterKnownLatency(t *testing.T) {
	router, err := NewModelRouter([]ModelCandidate{
		{ID: "unknown", Provider: "one", Model: "unknown", Capabilities: []string{"text"}, ContextWindow: 1000, Priority: 1},
		{ID: "known", Provider: "two", Model: "known", Capabilities: []string{"text"}, ContextWindow: 1000, Priority: 1, LatencyMS: 100},
	}, ModelRouterOptions{})
	if err != nil {
		t.Fatal(err)
	}
	decision, err := router.Select(context.Background(), RoutingRequest{InputTokens: 1})
	if err != nil {
		t.Fatal(err)
	}
	if decision.Selected.ID != "known" {
		t.Fatalf("unknown latency ranked first: %#v", decision.Selected)
	}
}
