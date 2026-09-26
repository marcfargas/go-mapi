package service

import "time"

const suiteGraceDuration = 30 * time.Second
const suiteForceDuration = 5 * time.Second

// suiteDrainBounds converts the durable wall deadline into one monotonic bound
// for this attempt. An expired or implausibly future durable deadline never
// creates a fresh force interval.
func suiteDrainBounds(now, deadline time.Time) (time.Time, time.Time) {
	graceLeft := deadline.Sub(now)
	if graceLeft < 0 {
		graceLeft = 0
	} else if graceLeft > suiteGraceDuration {
		graceLeft = 0
	}
	forceLeft := deadline.Add(suiteForceDuration).Sub(now)
	if forceLeft < 0 {
		forceLeft = 0
	} else if forceLeft > suiteGraceDuration+suiteForceDuration {
		forceLeft = 0
	}
	return now.Add(graceLeft), now.Add(forceLeft)
}
