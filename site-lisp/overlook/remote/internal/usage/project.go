package usage

import (
	"os"
	"path/filepath"
	"strings"
)

// repositoryRoot follows worktree commondir metadata without spawning git.
func repositoryRoot(root string) string {
	for dir := filepath.Clean(root); dir != filepath.Dir(dir); dir = filepath.Dir(dir) {
		git := filepath.Join(dir, ".git")
		if info, err := os.Stat(git); err == nil {
			if info.IsDir() {
				return dir
			}
			if data, err := os.ReadFile(git); err == nil && strings.HasPrefix(string(data), "gitdir: ") {
				gd := strings.TrimSpace(strings.TrimPrefix(string(data), "gitdir: "))
				if !filepath.IsAbs(gd) {
					gd = filepath.Join(dir, gd)
				}
				if common, err := os.ReadFile(filepath.Join(gd, "commondir")); err == nil {
					cd := strings.TrimSpace(string(common))
					if !filepath.IsAbs(cd) {
						cd = filepath.Join(gd, cd)
					}
					return filepath.Dir(filepath.Clean(cd))
				}
			}
			return dir
		}
	}
	return filepath.Clean(root)
}
func projectFromRoot(root string) string {
	if root == "" {
		return "Unassigned"
	}
	root = repositoryRoot(root)
	for dir := root; dir != filepath.Dir(dir); dir = filepath.Dir(dir) {
		if info, err := os.Stat(filepath.Join(dir, "project.md")); err == nil && !info.IsDir() {
			return filepath.Base(dir)
		}
	}
	return filepath.Base(root)
}

func (l *Ledger) projectResolver() func(string) string {
	projects := map[string]string{}
	return func(root string) string {
		if project, ok := projects[root]; ok {
			return project
		}
		project := ""
		if l.opts.Project != nil {
			project = l.opts.Project(root)
		}
		if project == "" {
			project = projectFromRoot(root)
		}
		projects[root] = project
		return project
	}
}
