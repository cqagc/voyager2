// Package model reads the component assignment produced by the Blender split
// and enforces the three-way contract between the exported glTF, the Godot
// scene tree, and the backend's per-component state.
package model

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/cqagc/voyager2/internal/domain"
)

// excludedNode is the pseudo-component holding geometry that is deliberately
// dropped: the 1x1x1 helper box the glTF carries at the origin. It is never a
// valid home for a real component.
const excludedNode = "_EXCLUDED"

// ComponentStat is the per-component result of the geometric split.
type ComponentStat struct {
	Parts    int `json:"parts"`
	Vertices int `json:"vertices"`
	// ConfidenceNote records how the assignment was justified, in Chinese,
	// so a reviewer can tell a measured identification from a fallback.
	ConfidenceNote string `json:"confidence_note"`
}

// Assignment is assets/generated/assignment.json.
type Assignment struct {
	Source     string                   `json:"source"`
	TotalParts int                      `json:"total_parts"`
	Components map[string]ComponentStat `json:"components"`
	Parents    map[string]string        `json:"parents"`
	// UnresolvedInModel maps a ComponentID the visual model does NOT
	// distinguish to the node that actually carries its geometry.
	//
	// This field exists so the twin never invents a node. NASA's model is a
	// visual asset: several instruments share one connected mesh. The backend
	// still needs every ComponentID addressable, so those IDs alias to their
	// containing node and the UI says so.
	UnresolvedInModel map[string]string `json:"unresolved_in_model"`
}

// Load reads an assignment file.
func Load(path string) (*Assignment, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read assignment: %w", err)
	}
	var a Assignment
	if err := json.Unmarshal(b, &a); err != nil {
		return nil, fmt.Errorf("parse assignment: %w", err)
	}
	return &a, nil
}

// Resolve returns the node name that carries a component's geometry, and
// whether the model distinguishes that component at all.
func (a *Assignment) Resolve(c domain.ComponentID) (node string, distinct bool) {
	if target, ok := a.UnresolvedInModel[string(c)]; ok {
		return target, false
	}
	return string(c), true
}

// Verify checks that every ComponentID in the domain contract is accounted
// for: either it has its own geometry, or it explicitly aliases to a node
// that does. It also rejects names the contract does not know about.
func (a *Assignment) Verify() error {
	known := make(map[string]bool, len(domain.AllComponents))
	for _, c := range domain.AllComponents {
		known[string(c)] = true
	}

	for name := range a.Components {
		if name == excludedNode {
			continue
		}
		if !known[name] {
			return fmt.Errorf("assignment has component %q that is not in domain.AllComponents", name)
		}
	}
	for alias, target := range a.UnresolvedInModel {
		if !known[alias] {
			return fmt.Errorf("unresolved alias %q is not in domain.AllComponents", alias)
		}
		// _EXCLUDED holds geometry that is explicitly NOT part of the
		// spacecraft (the glTF helper bounding box). Aliasing a real component
		// to it would satisfy every other check here -- non-zero parts, non-zero
		// vertices, a confidence note -- while leaving that component with no
		// actual spacecraft geometry at all.
		if target == excludedNode {
			return fmt.Errorf("component %q aliases to %q, which is non-spacecraft helper geometry", alias, target)
		}
		if _, ok := a.Components[target]; !ok {
			return fmt.Errorf("component %q aliases to %q, which has no geometry", alias, target)
		}
	}

	for _, c := range domain.AllComponents {
		node, distinct := a.Resolve(c)
		stat, ok := a.Components[node]
		if !ok {
			return fmt.Errorf("component %q resolves to node %q, which is absent from the assignment", c, node)
		}
		if stat.Parts == 0 || stat.Vertices == 0 {
			return fmt.Errorf("component %q resolves to node %q, which has no geometry (%d parts, %d verts)",
				c, node, stat.Parts, stat.Vertices)
		}
		if !distinct && stat.ConfidenceNote == "" {
			return fmt.Errorf("aliased component %q must carry a confidence note", c)
		}
	}
	return nil
}
