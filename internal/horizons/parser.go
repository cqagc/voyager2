// Package horizons fetches and parses state vectors from JPL Horizons.
package horizons

import (
	"bufio"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/cqagc/voyager2/internal/domain"
)

var (
	// ErrNoEphemeris indicates that Horizons returned no usable ephemeris data.
	ErrNoEphemeris = errors.New("horizons returned no ephemeris data")
	// ErrMalformedResponse indicates that a Horizons response cannot be parsed.
	ErrMalformedResponse = errors.New("malformed Horizons response")
)

// Parse reads a Horizons text response and returns the vectors between $$SOE
// and $$EOE.
func Parse(r io.Reader) ([]domain.StateVector, error) {
	scanner := bufio.NewScanner(r)
	// 单条 CSV 记录远小于此上限，提高上限可避免异常长响应行触发默认限制。
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	var (
		vectors  []domain.StateVector
		inside   bool
		foundSOE bool
		foundEOE bool
	)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if responseErr := horizonsResponseError(line); responseErr != nil {
			return nil, responseErr
		}

		switch line {
		case "$$SOE":
			inside = true
			foundSOE = true
			continue
		case "$$EOE":
			if inside {
				foundEOE = true
			}
			inside = false
			continue
		}
		if !inside || line == "" {
			continue
		}

		vector, err := parseCSVLine(line)
		if err != nil {
			return nil, err
		}
		vectors = append(vectors, vector)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read Horizons response: %w", err)
	}
	if !foundSOE || !foundEOE {
		return nil, fmt.Errorf("missing $$SOE or $$EOE marker: %w", ErrMalformedResponse)
	}
	if len(vectors) == 0 {
		return nil, ErrNoEphemeris
	}
	return vectors, nil
}

func parseCSVLine(line string) (domain.StateVector, error) {
	reader := csv.NewReader(strings.NewReader(line))
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true
	record, err := reader.Read()
	if err != nil {
		return domain.StateVector{}, fmt.Errorf("parse Horizons CSV: %w", err)
	}
	for len(record) > 0 && strings.TrimSpace(record[len(record)-1]) == "" {
		record = record[:len(record)-1]
	}
	if len(record) != 8 {
		return domain.StateVector{}, fmt.Errorf(
			"horizons CSV has %d fields, want 8: %w",
			len(record), ErrMalformedResponse,
		)
	}

	values := [7]float64{}
	indexes := [...]int{0, 2, 3, 4, 5, 6, 7}
	for i, index := range indexes {
		value, err := strconv.ParseFloat(strings.TrimSpace(record[index]), 64)
		if err != nil {
			return domain.StateVector{}, fmt.Errorf(
				"parse Horizons CSV field %d value %q: %w",
				index, record[index], err,
			)
		}
		values[i] = value
	}

	return domain.StateVector{
		JDTDB: values[0],
		Pos: domain.Vec3{
			X: values[1],
			Y: values[2],
			Z: values[3],
		},
		Vel: domain.Vec3{
			X: values[4],
			Y: values[5],
			Z: values[6],
		},
	}, nil
}

func horizonsResponseError(line string) error {
	lower := strings.ToLower(line)
	for _, phrase := range []string{
		"no ephemeris for target",
		"cannot interpret",
		"no matches found",
	} {
		if strings.Contains(lower, phrase) {
			return fmt.Errorf("horizons response %q: %w", line, ErrNoEphemeris)
		}
	}
	return nil
}
