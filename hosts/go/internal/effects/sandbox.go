package effects

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

// policy is the sandbox policy every request carries. The core has checked
// the request against it already; enforce is the host's independent check
// (docs/reference/host-effects.md, Sandbox).
type policy struct {
	Read     *[]string `json:"read"`
	Write    *[]string `json:"write"`
	Programs *[]string `json:"programs"`
	Network  *bool     `json:"network"`
	Listen   *bool     `json:"listen"`
	// The guard's anchors (see guard). They only add refusals, so they may
	// be absent.
	Protected []string `json:"protected"`
	Cwd       *string  `json:"cwd"`
	Projects  []string `json:"projects"`
}

// valid reports whether every field is present with its JSON type. A field
// of the wrong type already fails to decode.
func (p *policy) valid() bool {
	return p != nil && p.Read != nil && p.Write != nil && p.Programs != nil && p.Network != nil && p.Listen != nil
}

// resolution says how much of a touched path is resolved through symbolic
// links: all of it, or only its directory for effects that act on a final
// link itself (stat without following, remove and the atomic write, which
// renames over the path).
type resolution int

const (
	whole resolution = iota
	parent
)

type touch struct {
	write      bool
	resolution resolution
	path       *string
}

// touched lists the paths a request touches with the access it needs.
func touched(r *request) []touch {
	switch r.Op {
	case "read", "list", "realpath":
		return []touch{{false, whole, r.Path}}
	case "stat":
		if r.Follow {
			return []touch{{false, whole, r.Path}}
		}
		return []touch{{false, parent, r.Path}}
	case "write", "remove":
		return []touch{{true, parent, r.Path}}
	case "rename":
		return []touch{{true, parent, r.From}, {true, parent, r.To}}
	case "mkdirs":
		return []touch{{true, whole, r.Path}}
	case "spawn":
		return []touch{{false, whole, r.Cwd}}
	}
	return nil
}

func segments(file string) []string {
	return strings.FieldsFunc(path.Clean(file), func(c rune) bool { return c == '/' })
}

// within reports whether a path is the root itself or below it, after
// lexical normalisation.
func within(root, file string) bool {
	top, parts := segments(root), segments(file)
	return len(top) <= len(parts) && slices.Equal(top, parts[:len(top)])
}

// realPath resolves symbolic links as realpath(3) does, keeping missing
// trailing components.
func realPath(file string) (string, error) {
	var missing []string
	current := file
	for {
		real, err := filepath.EvalSymlinks(current)
		if err == nil {
			slices.Reverse(missing)
			return path.Join(append([]string{real}, missing...)...), nil
		}
		up := path.Dir(current)
		if !(errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ENOTDIR)) || up == current {
			return "", err
		}
		missing = append(missing, path.Base(current))
		current = up
	}
}

func resolved(how resolution, file string) (string, error) {
	normal := path.Clean(file)
	if how == whole || normal == "/" {
		return realPath(normal)
	}
	directory, err := realPath(path.Dir(normal))
	if err != nil {
		return "", err
	}
	return path.Join(directory, path.Base(normal)), nil
}

// systemProtected are the paths the guard protects on every host, whatever
// the policy says: the root and the system temporary roots.
var systemProtected = []string{"/", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"}

// ownProtected are this process's home and temporary directories, which
// the guard protects besides those the policy names.
func ownProtected() []string {
	var own []string
	for _, file := range []string{os.Getenv("HOME"), os.Getenv("TMPDIR"), os.TempDir()} {
		if path.IsAbs(file) {
			own = append(own, file)
		}
	}
	if home, err := os.UserHomeDir(); err == nil && path.IsAbs(home) {
		own = append(own, home)
	}
	return own
}

// aliases gives a path under both of its macOS names: /tmp, /var and /etc
// are links to the same names under /private.
func aliases(file string) []string {
	normal := path.Clean(file)
	parts := segments(normal)
	linked := func(name string) bool { return name == "tmp" || name == "var" || name == "etc" }
	switch {
	case len(parts) >= 2 && parts[0] == "private" && linked(parts[1]):
		return []string{normal, "/" + strings.Join(parts[1:], "/")}
	case len(parts) >= 1 && linked(parts[0]):
		return []string{normal, "/private/" + strings.Join(parts, "/")}
	}
	return []string{normal}
}

// protects reports whether a path is an anchor or an ancestor of one, or
// macOS's per-user temporary directory (/var/folders/xx/yyy/T) or an
// ancestor of it.
func protects(anchors []string, file string) bool {
	for _, anchor := range anchors {
		for _, name := range aliases(anchor) {
			if within(file, name) {
				return true
			}
		}
	}
	parts := segments(file)
	if len(parts) > 0 && parts[0] == "private" {
		parts = parts[1:]
	}
	if len(parts) < 2 || parts[0] != "var" || parts[1] != "folders" {
		return false
	}
	rest := parts[2:]
	return len(rest) < 3 || (len(rest) == 3 && rest[2] == "T")
}

// shownPath is a path as a message names it and in the form compared.
type shownPath struct{ shown, compared string }

// guardTarget is the path a write, remove or mkdirs targets.
type guardTarget struct {
	operation  string
	resolution resolution
	shownPath
}

// guardedTargets lists the paths a guarded request targets: both of a
// rename's.
func guardedTargets(r *request) []*guardTarget {
	target := func(file *string, how resolution) *guardTarget {
		return &guardTarget{r.Op, how, shownPath{*file, path.Clean(*file)}}
	}
	switch r.Op {
	case "write", "remove":
		return []*guardTarget{target(r.Path, parent)}
	case "rename":
		return []*guardTarget{target(r.From, parent), target(r.To, parent)}
	case "mkdirs":
		return []*guardTarget{target(r.Path, whole)}
	}
	return nil
}

// guarding applies the guard's rules over paths in one form, lexical or
// resolved: anchors no write root may be or contain (hard), anchors only a
// project root may be or contain (soft), the project roots, the write
// roots and the targets.
func guarding(hard, soft, projects []string, roots []shownPath, targets []*guardTarget) error {
	same := func(left, right string) bool { return path.Clean(left) == path.Clean(right) }
	for _, root := range roots {
		project := slices.ContainsFunc(projects, func(p string) bool { return same(p, root.compared) })
		if protects(hard, root.compared) || (protects(soft, root.compared) && !project) {
			return newError(kindDenied, "a write root is a protected path or contains one: %s", root.shown)
		}
	}
	for _, target := range targets {
		if protects(append(slices.Clone(hard), soft...), target.compared) {
			return newError(kindDenied, "%s of a protected path, or of an ancestor of one, is refused: %s", target.operation, target.shown)
		}
		if target.operation == "remove" || target.operation == "rename" {
			isRoot := slices.ContainsFunc(roots, func(root shownPath) bool { return same(root.compared, target.compared) })
			inside := slices.ContainsFunc(roots, func(root shownPath) bool { return within(root.compared, target.compared) })
			if isRoot || !inside {
				return newError(kindDenied, "%s is allowed only strictly inside a write root, never of one: %s", target.operation, target.shown)
			}
		}
	}
	return nil
}

// guard refuses, whatever the policy grants, a write, remove, rename or
// mkdirs that targets a protected path (the root, the system temporary
// roots, the home and temporary directories, the working directory, the
// project roots) or an ancestor of one; a remove or rename of a write root
// or not strictly inside one;
// and every path effect while a write root is a protected path or contains
// one (a project root may be a write root itself). The resolver is nil for
// the lexical check, or resolves every path through symbolic links.
func guard(p *policy, r *request, resolve func(resolution, string) (string, error)) error {
	hard := append(slices.Clone(systemProtected), p.Protected...)
	hard = append(hard, ownProtected()...)
	var soft []string
	if p.Cwd != nil {
		soft = append(soft, *p.Cwd)
	}
	soft = append(soft, p.Projects...)
	projects := slices.Clone(p.Projects)
	targets := guardedTargets(r)
	var roots []shownPath
	for _, root := range *p.Write {
		roots = append(roots, shownPath{root, path.Clean(root)})
	}
	if resolve != nil {
		resolveAll := func(files []string) ([]string, error) {
			var out []string
			for _, file := range files {
				real, err := resolve(whole, file)
				if err != nil {
					return nil, err
				}
				out = append(out, real)
			}
			return out, nil
		}
		for _, list := range []*[]string{&hard, &soft, &projects} {
			real, err := resolveAll(*list)
			if err != nil {
				return err
			}
			*list = append(*list, real...)
		}
		for i, root := range roots {
			real, err := resolve(whole, root.compared)
			if err != nil {
				return err
			}
			roots[i].compared = real
		}
		for _, target := range targets {
			real, err := resolve(target.resolution, target.compared)
			if err != nil {
				return err
			}
			target.compared = real
		}
	}
	return guarding(hard, soft, projects, roots, targets)
}

// enforce refuses, with denied, a request the policy does not allow, in the
// core's order: a malformed request is left to the operation, which answers
// invalid; then the core's lexical rules, the guard first; then the touched
// paths and the roots with their symbolic links resolved, which must still
// nest, and the guard over the resolved paths.
func enforce(p *policy, r *request) error {
	paths := touched(r)
	for _, t := range paths {
		if t.path == nil || !path.IsAbs(*t.path) {
			return nil
		}
	}
	if r.Op == "spawn" && len(r.Argv) == 0 {
		return nil
	}
	if len(paths) > 0 {
		if err := guard(p, r, nil); err != nil {
			return err
		}
	}
	roots := func(write bool) []string {
		if write {
			return *p.Write
		}
		return append(slices.Clone(*p.Read), *p.Write...)
	}
	switch r.Op {
	case "spawn":
		if !slices.Contains(*p.Programs, r.Argv[0]) {
			return newError(kindDenied, "program not allowed: %s", r.Argv[0])
		}
	case "fetch":
		if !*p.Network {
			return newError(kindDenied, "network access is not allowed")
		}
		if !strings.HasPrefix(r.URL, "https://") {
			return newError(kindDenied, "only https URLs may be fetched: %s", r.URL)
		}
	case "serve":
		if !*p.Listen {
			return newError(kindDenied, "listening is not allowed")
		}
	}
	for _, t := range paths {
		if !slices.ContainsFunc(roots(t.write), func(root string) bool { return within(root, *t.path) }) {
			return newError(kindDenied, "path is outside the sandbox: %s", *t.path)
		}
	}
	for _, t := range paths {
		real, err := resolved(t.resolution, *t.path)
		if err != nil {
			return err
		}
		allowed := false
		for _, root := range roots(t.write) {
			resolvedRoot, err := resolved(whole, root)
			if err != nil {
				return err
			}
			// Every root is resolved, as the Node host does, so a root that
			// cannot be resolved fails the request.
			allowed = allowed || within(resolvedRoot, real)
		}
		if !allowed {
			return newError(kindDenied, "path leaves the sandbox through a symbolic link: %s", *t.path)
		}
	}
	if len(paths) > 0 {
		return guard(p, r, resolved)
	}
	return nil
}
