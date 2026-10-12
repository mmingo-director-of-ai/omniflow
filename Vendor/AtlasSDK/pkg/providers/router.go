package providers

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"
	"time"
)

type ModelCandidate struct {
	ID              string                 `json:"id"`
	Provider        string                 `json:"provider"`
	Model           string                 `json:"model"`
	Capabilities    []string               `json:"capabilities"`
	ContextWindow   int                    `json:"contextWindow"`
	CostPer1KInput  float64                `json:"costPer1kInput,omitempty"`
	CostPer1KOutput float64                `json:"costPer1kOutput,omitempty"`
	LatencyMS       int                    `json:"latencyMs,omitempty"`
	Privacy         string                 `json:"privacy,omitempty"`
	Residency       string                 `json:"residency,omitempty"`
	Health          string                 `json:"health,omitempty"`
	Priority        int                    `json:"priority,omitempty"`
	Metadata        map[string]interface{} `json:"metadata,omitempty"`
}

type RoutingRequest struct {
	RequiredCapabilities []string               `json:"requiredCapabilities,omitempty"`
	InputTokens          int                    `json:"inputTokens"`
	ExpectedOutputTokens int                    `json:"expectedOutputTokens,omitempty"`
	MaxEstimatedCost     *float64               `json:"maxEstimatedCost,omitempty"`
	MaxLatencyMS         int                    `json:"maxLatencyMs,omitempty"`
	MinimumPrivacy       string                 `json:"minimumPrivacy,omitempty"`
	AllowedResidencies   []string               `json:"allowedResidencies,omitempty"`
	AllowedProviders     []string               `json:"allowedProviders,omitempty"`
	DeniedProviders      []string               `json:"deniedProviders,omitempty"`
	PreferredProvider    string                 `json:"preferredProvider,omitempty"`
	PreferredModel       string                 `json:"preferredModel,omitempty"`
	Metadata             map[string]interface{} `json:"metadata,omitempty"`
}

type CandidateRejection struct {
	CandidateID string
	Reasons     []string
}
type RoutingDecision struct {
	Selected      ModelCandidate
	FallbackChain []ModelCandidate
	Reasons       []string
	Rejections    []CandidateRejection
	EstimatedCost float64
}
type RoutingAttempt struct {
	CandidateID string
	Attempt     int
	Success     bool
	Error       string
}

type ModelRouterOptions struct {
	FailureThreshold    int
	CircuitReset        time.Duration
	RetriesPerCandidate int
	Clock               func() time.Time
	Override            func(context.Context, RoutingRequest, []ModelCandidate) (string, *RoutingRequest, error)
}

type circuitState struct {
	Failures  int
	OpenUntil time.Time
}

// ModelCircuitState is the observable failure state for one candidate.
type ModelCircuitState struct {
	Failures  int
	OpenUntil time.Time
}

type ModelRouter struct {
	catalog  []ModelCandidate
	opts     ModelRouterOptions
	mu       sync.Mutex
	circuits map[string]circuitState
}

type RoutingError struct {
	Message  string
	Attempts []RoutingAttempt
}

func (e *RoutingError) Error() string { return e.Message }

func NewModelRouter(catalog []ModelCandidate, opts ModelRouterOptions) (*ModelRouter, error) {
	ids := map[string]bool{}
	copyCatalog := cloneModelCatalog(catalog)
	for _, candidate := range copyCatalog {
		if err := validateModelCandidate(candidate); err != nil {
			return nil, err
		}
		if ids[candidate.ID] {
			return nil, fmt.Errorf("duplicate model candidate id: %s", candidate.ID)
		}
		ids[candidate.ID] = true
	}
	if opts.FailureThreshold == 0 {
		opts.FailureThreshold = 3
	} else if opts.FailureThreshold < 0 {
		return nil, errors.New("failure threshold must be positive")
	}
	if opts.CircuitReset == 0 {
		opts.CircuitReset = 30 * time.Second
	} else if opts.CircuitReset < 0 {
		return nil, errors.New("circuit reset must be positive")
	}
	if opts.RetriesPerCandidate < 0 {
		return nil, errors.New("retries per candidate must be non-negative")
	}
	if opts.Clock == nil {
		opts.Clock = time.Now
	}
	return &ModelRouter{catalog: copyCatalog, opts: opts, circuits: map[string]circuitState{}}, nil
}

func (r *ModelRouter) Select(ctx context.Context, request RoutingRequest) (RoutingDecision, error) {
	if err := validateRoutingRequest(request); err != nil {
		return RoutingDecision{}, err
	}
	originalRequest := cloneRoutingRequest(request)
	forcedID := ""
	if r.opts.Override != nil {
		id, replacement, err := r.opts.Override(ctx, cloneRoutingRequest(request), cloneModelCatalog(r.catalog))
		if err != nil {
			return RoutingDecision{}, err
		}
		forcedID = id
		if replacement != nil {
			request = mergeRoutingOverride(originalRequest, *replacement)
		}
	}
	if err := validateRoutingRequest(request); err != nil {
		return RoutingDecision{}, err
	}
	if forcedID != "" {
		found := false
		for _, candidate := range r.catalog {
			if candidate.ID == forcedID {
				found = true
				break
			}
		}
		if !found {
			return RoutingDecision{}, &RoutingError{Message: "host override selected unknown model candidate: " + forcedID}
		}
	}
	type scored struct {
		candidate ModelCandidate
		cost      float64
	}
	eligible := make([]scored, 0)
	rejections := make([]CandidateRejection, 0)
	for _, candidate := range r.catalog {
		reasons := r.rejectionReasons(candidate, request)
		if forcedID != "" && candidate.ID != forcedID {
			reasons = append(reasons, "host override selected "+forcedID)
		}
		if len(reasons) > 0 {
			rejections = append(rejections, CandidateRejection{candidate.ID, reasons})
		} else {
			eligible = append(eligible, scored{candidate, routeCost(candidate, request)})
		}
	}
	if len(eligible) == 0 {
		parts := make([]string, 0, len(rejections))
		for _, rejection := range rejections {
			parts = append(parts, rejection.CandidateID+": "+strings.Join(rejection.Reasons, ", "))
		}
		return RoutingDecision{}, &RoutingError{Message: "no model satisfies the routing policy (" + strings.Join(parts, "; ") + ")"}
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		return compareRoute(eligible[i].candidate, eligible[i].cost, eligible[j].candidate, eligible[j].cost, request) < 0
	})
	selected := eligible[0]
	fallbacks := make([]ModelCandidate, 0, len(eligible)-1)
	for _, item := range eligible[1:] {
		fallbacks = append(fallbacks, cloneModelCandidate(item.candidate))
	}
	reasons := []string{
		fmt.Sprintf("satisfies %d required capabilities", len(request.RequiredCapabilities)),
		fmt.Sprintf("context %d/%d", request.InputTokens+request.ExpectedOutputTokens, selected.candidate.ContextWindow),
		fmt.Sprintf("estimated cost %.6f", selected.cost),
	}
	if forcedID != "" {
		reasons = append([]string{"selected by host override: " + forcedID}, reasons...)
	}
	if request.PreferredProvider == selected.candidate.Provider {
		reasons = append(reasons, "preferred provider "+selected.candidate.Provider)
	}
	if request.PreferredModel == selected.candidate.Model {
		reasons = append(reasons, "preferred model "+selected.candidate.Model)
	}
	return RoutingDecision{Selected: cloneModelCandidate(selected.candidate), FallbackChain: fallbacks, Reasons: reasons, Rejections: rejections, EstimatedCost: selected.cost}, nil
}

func (r *ModelRouter) Execute(ctx context.Context, request RoutingRequest, operation func(context.Context, ModelCandidate, int) (interface{}, error)) (interface{}, ModelCandidate, RoutingDecision, []RoutingAttempt, error) {
	decision, err := r.Select(ctx, request)
	if err != nil {
		return nil, ModelCandidate{}, decision, nil, err
	}
	chain := append([]ModelCandidate{decision.Selected}, decision.FallbackChain...)
	attempts := []RoutingAttempt{}
	for _, candidate := range chain {
		for attempt := 1; attempt <= r.opts.RetriesPerCandidate+1; attempt++ {
			value, runErr := operation(ctx, cloneModelCandidate(candidate), attempt)
			if runErr == nil {
				r.RecordSuccess(candidate.ID)
				attempts = append(attempts, RoutingAttempt{CandidateID: candidate.ID, Attempt: attempt, Success: true})
				return value, cloneModelCandidate(candidate), decision, attempts, nil
			}
			attempts = append(attempts, RoutingAttempt{CandidateID: candidate.ID, Attempt: attempt, Error: runErr.Error()})
			r.RecordFailure(candidate.ID)
		}
	}
	return nil, ModelCandidate{}, decision, attempts, &RoutingError{Message: "all routed model attempts failed", Attempts: attempts}
}

func (r *ModelRouter) RecordFailure(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	state := r.circuits[id]
	now := r.opts.Clock()
	if !state.OpenUntil.IsZero() && !state.OpenUntil.After(now) {
		state = circuitState{}
	}
	state.Failures++
	if state.Failures >= r.opts.FailureThreshold {
		state.OpenUntil = now.Add(r.opts.CircuitReset)
	}
	r.circuits[id] = state
}
func (r *ModelRouter) RecordSuccess(id string) { r.mu.Lock(); delete(r.circuits, id); r.mu.Unlock() }

// GetCircuitState returns a copy of a candidate's current circuit state.
func (r *ModelRouter) GetCircuitState(id string) (ModelCircuitState, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	state, ok := r.circuits[id]
	if !ok {
		return ModelCircuitState{}, false
	}
	if !state.OpenUntil.IsZero() && !state.OpenUntil.After(r.opts.Clock()) {
		delete(r.circuits, id)
		return ModelCircuitState{}, false
	}
	return ModelCircuitState{Failures: state.Failures, OpenUntil: state.OpenUntil}, true
}

func (r *ModelRouter) rejectionReasons(candidate ModelCandidate, request RoutingRequest) []string {
	reasons := []string{}
	requiredTokens := request.InputTokens + request.ExpectedOutputTokens
	if requiredTokens > candidate.ContextWindow {
		reasons = append(reasons, fmt.Sprintf("context limit %d < %d", candidate.ContextWindow, requiredTokens))
	}
	capabilities := stringSet(candidate.Capabilities)
	missing := []string{}
	for _, capability := range request.RequiredCapabilities {
		if !capabilities[capability] {
			missing = append(missing, capability)
		}
	}
	if len(missing) > 0 {
		reasons = append(reasons, "missing capabilities: "+strings.Join(missing, ", "))
	}
	cost := routeCost(candidate, request)
	if request.MaxEstimatedCost != nil && cost > *request.MaxEstimatedCost {
		reasons = append(reasons, fmt.Sprintf("estimated cost %.6f > %.6f", cost, *request.MaxEstimatedCost))
	}
	if request.MaxLatencyMS > 0 && (candidate.LatencyMS == 0 || candidate.LatencyMS > request.MaxLatencyMS) {
		reasons = append(reasons, fmt.Sprintf("latency %d > %d", candidate.LatencyMS, request.MaxLatencyMS))
	}
	if privacyRank(defaultString(candidate.Privacy, "public")) < privacyRank(defaultString(request.MinimumPrivacy, "public")) {
		reasons = append(reasons, "privacy requirement not met")
	}
	if len(request.AllowedResidencies) > 0 && !stringSet(request.AllowedResidencies)[candidate.Residency] {
		reasons = append(reasons, "residency is not allowed")
	}
	if len(request.AllowedProviders) > 0 && !stringSet(request.AllowedProviders)[candidate.Provider] {
		reasons = append(reasons, "provider is not allowed")
	}
	if stringSet(request.DeniedProviders)[candidate.Provider] {
		reasons = append(reasons, "provider is denied")
	}
	if candidate.Health == "unavailable" {
		reasons = append(reasons, "provider health is unavailable")
	}
	if r.circuitOpen(candidate.ID) {
		reasons = append(reasons, "circuit breaker is open")
	}
	return reasons
}

func (r *ModelRouter) circuitOpen(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	state, ok := r.circuits[id]
	if !ok {
		return false
	}
	if state.OpenUntil.After(r.opts.Clock()) {
		return true
	}
	if !state.OpenUntil.IsZero() {
		delete(r.circuits, id)
	}
	return false
}

func routeCost(candidate ModelCandidate, request RoutingRequest) float64 {
	return float64(request.InputTokens)/1000*candidate.CostPer1KInput + float64(request.ExpectedOutputTokens)/1000*candidate.CostPer1KOutput
}
func compareRoute(a ModelCandidate, aCost float64, b ModelCandidate, bCost float64, request RoutingRequest) int {
	aPreference := preference(a, request)
	bPreference := preference(b, request)
	if aPreference != bPreference {
		return aPreference - bPreference
	}
	aPriority := a.Priority
	if aPriority == 0 {
		aPriority = 100
	}
	bPriority := b.Priority
	if bPriority == 0 {
		bPriority = 100
	}
	if aPriority != bPriority {
		return aPriority - bPriority
	}
	if aHealth, bHealth := healthRank(defaultString(a.Health, "healthy")), healthRank(defaultString(b.Health, "healthy")); aHealth != bHealth {
		return aHealth - bHealth
	}
	if aCost < bCost {
		return -1
	}
	if aCost > bCost {
		return 1
	}
	if aLatency, bLatency := routeLatency(a), routeLatency(b); aLatency != bLatency {
		return aLatency - bLatency
	}
	if a.Provider != b.Provider {
		return strings.Compare(a.Provider, b.Provider)
	}
	if a.Model != b.Model {
		return strings.Compare(a.Model, b.Model)
	}
	return strings.Compare(a.ID, b.ID)
}
func preference(candidate ModelCandidate, request RoutingRequest) int {
	value := 0
	if candidate.Provider == request.PreferredProvider {
		value -= 2
	}
	if candidate.Model == request.PreferredModel {
		value--
	}
	return value
}
func privacyRank(value string) int {
	return map[string]int{"public": 0, "managed": 1, "private": 2, "local": 3}[value]
}
func healthRank(value string) int {
	return map[string]int{"healthy": 0, "degraded": 1, "unavailable": 2}[value]
}
func stringSet(values []string) map[string]bool {
	result := map[string]bool{}
	for _, value := range values {
		result[value] = true
	}
	return result
}
func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func validateModelCandidate(candidate ModelCandidate) error {
	if candidate.ID == "" {
		return errors.New("model candidate id is required")
	}
	if candidate.Provider == "" {
		return fmt.Errorf("model candidate provider is required for %s", candidate.ID)
	}
	if candidate.Model == "" {
		return fmt.Errorf("model candidate model is required for %s", candidate.ID)
	}
	if candidate.ContextWindow <= 0 {
		return fmt.Errorf("invalid context window for %s", candidate.ID)
	}
	for _, field := range []struct {
		name  string
		value float64
	}{
		{name: "costPer1kInput", value: candidate.CostPer1KInput},
		{name: "costPer1kOutput", value: candidate.CostPer1KOutput},
	} {
		name, value := field.name, field.value
		if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
			return fmt.Errorf("%s must be non-negative for %s", name, candidate.ID)
		}
	}
	if candidate.LatencyMS < 0 {
		return fmt.Errorf("latencyMs must be non-negative for %s", candidate.ID)
	}
	if candidate.Privacy != "" && !validPrivacy(candidate.Privacy) {
		return fmt.Errorf("invalid privacy for %s: %s", candidate.ID, candidate.Privacy)
	}
	if candidate.Health != "" && !stringSet([]string{"healthy", "degraded", "unavailable"})[candidate.Health] {
		return fmt.Errorf("invalid health for %s: %s", candidate.ID, candidate.Health)
	}
	for _, capability := range candidate.Capabilities {
		if capability == "" {
			return fmt.Errorf("capabilities must be non-empty for %s", candidate.ID)
		}
	}
	return nil
}

func validateRoutingRequest(request RoutingRequest) error {
	if request.InputTokens < 0 || request.ExpectedOutputTokens < 0 {
		return errors.New("token counts must be non-negative")
	}
	if request.MaxEstimatedCost != nil &&
		(math.IsNaN(*request.MaxEstimatedCost) || math.IsInf(*request.MaxEstimatedCost, 0) || *request.MaxEstimatedCost < 0) {
		return errors.New("max estimated cost must be non-negative")
	}
	if request.MaxLatencyMS < 0 {
		return errors.New("max latency must be non-negative")
	}
	if request.MinimumPrivacy != "" && !validPrivacy(request.MinimumPrivacy) {
		return fmt.Errorf("invalid minimum privacy: %s", request.MinimumPrivacy)
	}
	return nil
}

func mergeRoutingOverride(original, override RoutingRequest) RoutingRequest {
	result := cloneRoutingRequest(override)
	result.InputTokens = original.InputTokens
	result.ExpectedOutputTokens = original.ExpectedOutputTokens
	result.RequiredCapabilities = uniqueStrings(append(
		append([]string(nil), original.RequiredCapabilities...),
		override.RequiredCapabilities...,
	))
	return result
}

func cloneRoutingRequest(request RoutingRequest) RoutingRequest {
	result := request
	result.RequiredCapabilities = append([]string(nil), request.RequiredCapabilities...)
	result.AllowedResidencies = append([]string(nil), request.AllowedResidencies...)
	result.AllowedProviders = append([]string(nil), request.AllowedProviders...)
	result.DeniedProviders = append([]string(nil), request.DeniedProviders...)
	result.Metadata = cloneMetadata(request.Metadata)
	if request.MaxEstimatedCost != nil {
		value := *request.MaxEstimatedCost
		result.MaxEstimatedCost = &value
	}
	return result
}

func cloneModelCatalog(catalog []ModelCandidate) []ModelCandidate {
	result := make([]ModelCandidate, len(catalog))
	for index, candidate := range catalog {
		result[index] = cloneModelCandidate(candidate)
	}
	return result
}

func cloneModelCandidate(candidate ModelCandidate) ModelCandidate {
	result := candidate
	result.Capabilities = append([]string(nil), candidate.Capabilities...)
	result.Metadata = cloneMetadata(candidate.Metadata)
	return result
}

func cloneMetadata(metadata map[string]interface{}) map[string]interface{} {
	if metadata == nil {
		return nil
	}
	result := make(map[string]interface{}, len(metadata))
	for key, value := range metadata {
		result[key] = cloneMetadataValue(value)
	}
	return result
}

func cloneMetadataValue(value interface{}) interface{} {
	switch typed := value.(type) {
	case map[string]interface{}:
		return cloneMetadata(typed)
	case []interface{}:
		result := make([]interface{}, len(typed))
		for index, item := range typed {
			result[index] = cloneMetadataValue(item)
		}
		return result
	case []string:
		return append([]string(nil), typed...)
	case map[string]string:
		result := make(map[string]string, len(typed))
		for key, item := range typed {
			result[key] = item
		}
		return result
	default:
		return value
	}
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	return result
}

func validPrivacy(value string) bool {
	return stringSet([]string{"public", "managed", "private", "local"})[value]
}

func routeLatency(candidate ModelCandidate) int {
	if candidate.LatencyMS == 0 {
		return int(^uint(0) >> 1)
	}
	return candidate.LatencyMS
}
