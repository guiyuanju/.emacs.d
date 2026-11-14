// Package web holds the page sources served by overlook-remoted.
package web

import "embed"

// FS is this directory; assets.Served filters out Go files and tests.
//
//go:embed *
var FS embed.FS
