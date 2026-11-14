//go:build !darwin

package launchd

import "errors"

func activate(string) ([]int32, error) {
	return nil, errors.New("launchd sockets exist only on macOS")
}
