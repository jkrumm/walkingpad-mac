package store

import (
	"context"
	"reflect"
	"strconv"
	"testing"
	"time"
)

// seedDaily stores a closed session that started at startedAt.
func seedDaily(t *testing.T, s *Store, n int, startedAt time.Time, totals SessionTotals) {
	t.Helper()
	ctx := context.Background()
	id, err := s.OpenSession(ctx, "daily-"+strconv.Itoa(n), startedAt)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := s.CloseSession(ctx, id, startedAt.Add(time.Duration(totals.DurationS)*time.Second), totals); err != nil {
		t.Fatalf("close: %v", err)
	}
}

func TestDailyTotals(t *testing.T) {
	berlin := time.FixedZone("CET", 3600)
	day := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }
	walk := func(m float64) SessionTotals {
		return SessionTotals{DurationS: 600, DistanceM: m, Steps: int64(m * 1.5), Kcal: m / 20}
	}

	tests := []struct {
		name     string
		loc      *time.Location
		from, to time.Time
		seed     func(t *testing.T, s *Store)
		want     []DayTotals
	}{
		{
			name: "empty range is zero filled",
			loc:  time.UTC, from: day(2026, 7, 29), to: day(2026, 7, 31),
			want: []DayTotals{{Date: "2026-07-29"}, {Date: "2026-07-30"}, {Date: "2026-07-31"}},
		},
		{
			name: "a day without sessions between two with sessions",
			loc:  time.UTC, from: day(2026, 7, 29), to: day(2026, 7, 31),
			seed: func(t *testing.T, s *Store) {
				seedDaily(t, s, 1, time.Date(2026, 7, 29, 8, 0, 0, 0, time.UTC), walk(1000))
				seedDaily(t, s, 2, time.Date(2026, 7, 29, 18, 0, 0, 0, time.UTC), walk(500))
				seedDaily(t, s, 3, time.Date(2026, 7, 31, 8, 0, 0, 0, time.UTC), walk(2000))
			},
			want: []DayTotals{
				{Date: "2026-07-29", Sessions: 2, DurationS: 1200, DistanceM: 1500, Steps: 2250, Kcal: 75},
				{Date: "2026-07-30"},
				{Date: "2026-07-31", Sessions: 1, DurationS: 600, DistanceM: 2000, Steps: 3000, Kcal: 100},
			},
		},
		{
			name: "a session across midnight counts on the day it started",
			loc:  time.UTC, from: day(2026, 7, 30), to: day(2026, 7, 31),
			seed: func(t *testing.T, s *Store) {
				seedDaily(t, s, 1, time.Date(2026, 7, 30, 23, 55, 0, 0, time.UTC), walk(1200))
			},
			want: []DayTotals{
				{Date: "2026-07-30", Sessions: 1, DurationS: 600, DistanceM: 1200, Steps: 1800, Kcal: 60},
				{Date: "2026-07-31"},
			},
		},
		{
			name: "the day is local: 23:30 UTC is already tomorrow in CET",
			loc:  berlin, from: day(2026, 7, 30), to: day(2026, 7, 31),
			seed: func(t *testing.T, s *Store) {
				seedDaily(t, s, 1, time.Date(2026, 7, 30, 23, 30, 0, 0, time.UTC), walk(800))
			},
			want: []DayTotals{
				{Date: "2026-07-30"},
				{Date: "2026-07-31", Sessions: 1, DurationS: 600, DistanceM: 800, Steps: 1200, Kcal: 40},
			},
		},
		{
			name: "sessions outside the range and open sessions are left out",
			loc:  time.UTC, from: day(2026, 7, 30), to: day(2026, 7, 30),
			seed: func(t *testing.T, s *Store) {
				seedDaily(t, s, 1, time.Date(2026, 7, 29, 23, 59, 59, 0, time.UTC), walk(900))
				seedDaily(t, s, 2, time.Date(2026, 7, 31, 0, 0, 0, 0, time.UTC), walk(900))
				if _, err := s.OpenSession(context.Background(), "open", time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)); err != nil {
					t.Fatalf("open: %v", err)
				}
			},
			want: []DayTotals{{Date: "2026-07-30"}},
		},
		{
			name: "a spring-forward day is still one day",
			loc:  mustLoadLocation(t, "Europe/Berlin"), from: day(2026, 3, 28), to: day(2026, 3, 30),
			seed: func(t *testing.T, s *Store) {
				// 2026-03-29 is 23 hours long in Berlin; 00:30 local is 23:30 UTC the day before.
				seedDaily(t, s, 1, time.Date(2026, 3, 28, 23, 30, 0, 0, time.UTC), walk(700))
			},
			want: []DayTotals{
				{Date: "2026-03-28"},
				{Date: "2026-03-29", Sessions: 1, DurationS: 600, DistanceM: 700, Steps: 1050, Kcal: 35},
				{Date: "2026-03-30"},
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := openTest(t)
			if tc.seed != nil {
				tc.seed(t, s)
			}
			got, err := s.DailyTotals(context.Background(), tc.from, tc.to, tc.loc)
			if err != nil {
				t.Fatalf("DailyTotals: %v", err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("got  %+v\nwant %+v", got, tc.want)
			}
		})
	}
}

func TestDailyTotals_RejectsReversedRange(t *testing.T) {
	s := openTest(t)
	from := time.Date(2026, 7, 31, 0, 0, 0, 0, time.UTC)
	if _, err := s.DailyTotals(context.Background(), from, from.AddDate(0, 0, -1), time.UTC); err == nil {
		t.Fatal("want an error for to before from")
	}
}

func mustLoadLocation(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Skipf("no tzdata for %s: %v", name, err)
	}
	return loc
}
