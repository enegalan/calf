package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParseImageHistoryLinesReversesOrder(t *testing.T) {
	output := []byte(`{"CreatedSince":"1 day ago","CreatedBy":"CMD [\"test\"]","Size":"0 B"}
{"CreatedSince":"2 days ago","CreatedBy":"RUN apt-get update","Size":"10 MiB"}
`)

	layers, err := runtime.ParseImageHistoryLines(output)
	if err != nil {
		t.Fatalf("ParseImageHistoryLines() error: %v", err)
	}

	if len(layers) != 2 {
		t.Fatalf("expected 2 layers, got %d", len(layers))
	}

	if layers[0].Index != 0 || layers[0].CreatedBy != "RUN apt-get update" {
		t.Fatalf("unexpected first layer: %+v", layers[0])
	}

	if layers[1].Index != 1 || layers[1].CreatedBy != "CMD [\"test\"]" {
		t.Fatalf("unexpected second layer: %+v", layers[1])
	}
}
