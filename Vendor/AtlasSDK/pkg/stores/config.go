package stores

// StoreConfig configures a store backend.
type StoreConfig struct {
	Type    string                 `json:"type" yaml:"type"` // sqlite, redis, postgres, local-file
	URL     string                 `json:"url,omitempty" yaml:"url,omitempty"`
	Options map[string]interface{} `json:"options,omitempty" yaml:"options,omitempty"`
}
