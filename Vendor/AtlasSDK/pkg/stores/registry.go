package stores

import (
	"context"
	"fmt"
)

// ContextStoreFactory creates a ContextStore from config.
type ContextStoreFactory func(config StoreConfig) (ContextStore, error)

// MemoryStoreFactory creates a MemoryStore from config.
type MemoryStoreFactory func(config StoreConfig) (MemoryStore, error)

// Registry manages store factory registration and creation.
type Registry struct {
	contextFactories map[string]ContextStoreFactory
	memoryFactories  map[string]MemoryStoreFactory
}

// NewRegistry creates an empty StoreRegistry.
func NewRegistry() *Registry {
	return &Registry{
		contextFactories: make(map[string]ContextStoreFactory),
		memoryFactories:  make(map[string]MemoryStoreFactory),
	}
}

func (r *Registry) RegisterContextStore(name string, factory ContextStoreFactory) {
	r.contextFactories[name] = factory
}

func (r *Registry) RegisterMemoryStore(name string, factory MemoryStoreFactory) {
	r.memoryFactories[name] = factory
}

func (r *Registry) CreateContextStore(ctx context.Context, name string, config StoreConfig) (ContextStore, error) {
	factory, ok := r.contextFactories[name]
	if !ok {
		return nil, &StoreError{Message: fmt.Sprintf("unknown context store: %s", name), StoreType: config.Type, Operation: "create"}
	}
	store, err := factory(config)
	if err != nil {
		return nil, err
	}
	if err := store.Init(ctx); err != nil {
		return nil, err
	}
	return store, nil
}

func (r *Registry) CreateMemoryStore(ctx context.Context, name string, config StoreConfig) (MemoryStore, error) {
	factory, ok := r.memoryFactories[name]
	if !ok {
		return nil, &StoreError{Message: fmt.Sprintf("unknown memory store: %s", name), StoreType: config.Type, Operation: "create"}
	}
	store, err := factory(config)
	if err != nil {
		return nil, err
	}
	if err := store.Init(ctx); err != nil {
		return nil, err
	}
	return store, nil
}
