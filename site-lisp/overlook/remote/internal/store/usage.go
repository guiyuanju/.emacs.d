package store

import (
	"path/filepath"
	"strings"
)

// UsageProject finds the most specific live project root without exposing it to the browser.
func (s *Store) UsageProject(root string) string {
	if root == "" {
		return ""
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	root = filepath.Clean(root)
	best, project := "", ""
	for _, cv := range s.convs {
		if cv.state == nil || cv.state.Project == "" || cv.state.Root == "" {
			continue
		}
		base := filepath.Clean(cv.state.Root)
		if (root == base || strings.HasPrefix(root, base+string(filepath.Separator))) && len(base) > len(best) {
			best = base
			project = cv.state.Project
		}
	}
	return project
}
