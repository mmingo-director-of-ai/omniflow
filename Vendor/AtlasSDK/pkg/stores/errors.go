package stores

import "fmt"

// StoreError represents a store operation failure.
type StoreError struct {
	Message   string
	StoreType string
	Operation string
	SessionID string
}

func (e *StoreError) Error() string {
	if e.SessionID != "" {
		return fmt.Sprintf("store error [%s/%s] session=%s: %s", e.StoreType, e.Operation, e.SessionID, e.Message)
	}
	return fmt.Sprintf("store error [%s/%s]: %s", e.StoreType, e.Operation, e.Message)
}

func NewStoreError(message, storeType, operation string) *StoreError {
	return &StoreError{Message: message, StoreType: storeType, Operation: operation}
}

func NewSessionStoreError(message, storeType, operation, sessionID string) *StoreError {
	return &StoreError{Message: message, StoreType: storeType, Operation: operation, SessionID: sessionID}
}
